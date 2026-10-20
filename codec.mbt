///|
pub suberror ProtocolError {
  Invalid(String)
  Limit(String)
  Truncated(String)
} derive(Debug)

///|
pub extend ProtocolError with @debug.Debug::{to_repr}

///|
/// A protocol record; content is immutable and independent of decoder storage.
pub(all) struct Record {
  kind : Int
  id : Int
  content : Bytes
} derive(Eq, Debug)

///|
pub extend Record with Eq::{equal, not_equal}

///|
pub extend Record with @debug.Debug::{to_repr}

///|
/// Incremental decoder. A failure poisons the decoder; create a new one.
pub struct Decoder {
  storage : FixedArray[Byte]
  mut used : Int
  mut expected : Int
  mut failed : Bool
}

///|
pub fn Decoder::new() -> Decoder {
  {
    storage: FixedArray::make(65798, b'\x00'),
    used: 0,
    expected: 8,
    failed: false,
  }
}

///|
/// Accept at most 64 KiB per call. Partial records remain buffered.
pub fn Decoder::feed(
  self : Decoder,
  bytes : Bytes,
) -> Array[Record] raise ProtocolError {
  if self.failed {
    raise Invalid("decoder already failed")
  }
  if bytes.length() > 65536 {
    self.failed = true
    raise Limit("feed chunk exceeds 65536 bytes")
  }
  let records = []
  for byte in bytes {
    self.storage[self.used] = byte
    self.used += 1
    if self.used == 8 {
      if self.storage[0] != b'\x01' {
        self.failed = true
        raise Invalid("unsupported FastCGI version")
      }
      self.expected = 8 +
        self.storage[4].to_int() * 256 +
        self.storage[5].to_int() +
        self.storage[6].to_int()
    }
    if self.used == self.expected {
      let n = self.storage[4].to_int() * 256 + self.storage[5].to_int()
      records.push({
        kind: self.storage[1].to_int(),
        id: self.storage[2].to_int() * 256 + self.storage[3].to_int(),
        content: Bytes::makei(n, i => self.storage[8 + i]),
      })
      self.used = 0
      self.expected = 8
    }
  }
  records
}

///|
/// Call only at transport EOF. EOF cannot terminate a partial record.
pub fn Decoder::finish(self : Decoder) -> Unit raise ProtocolError {
  if self.failed {
    raise Invalid("decoder already failed")
  }
  if self.used != 0 {
    self.failed = true
    raise Truncated("record at EOF")
  }
}

///|
/// Encode one record with 8-byte alignment padding.
pub fn encode_record(record : Record) -> Bytes raise ProtocolError {
  if record.kind < 0 || record.kind > 255 || record.id < 0 || record.id > 65535 {
    raise Invalid("record kind or request id out of range")
  }
  let n = record.content.length()
  if n > 65535 {
    raise Limit("record content exceeds 65535 bytes")
  }
  let padding = (8 - n % 8) % 8
  let out = @buf.Buffer()
  for
    value in [
      1,
      record.kind,
      record.id / 256,
      record.id % 256,
      n / 256,
      n % 256,
      padding,
      0,
    ] {
    out.write_byte(value.to_byte())
  }
  out.write_bytes(record.content)
  for _ in 0..<padding {
    out.write_byte(b'\x00')
  }
  out.to_bytes()
}

///|
/// Split bytes into stream records, followed by exactly one empty terminator.
pub fn stream_records(kind : Int, id : Int, content : Bytes) -> Array[Record] {
  let out = []
  let mut offset = 0
  while offset < content.length() {
    let n = Int::min(65535, content.length() - offset)
    out.push({ kind, id, content: content[offset:offset + n].to_owned(), })
    offset += n
  }
  out.push({ kind, id, content: b"", })
  out
}

///|
pub fn end_record(
  id : Int,
  app_status? : UInt = 0U,
  protocol_status? : Int = 0,
) -> Record {
  let out = @buf.Buffer()
  out.write_uint_be(app_status)
  out.write_byte(protocol_status.to_byte())
  for _ in 0..<3 {
    out.write_byte(b'\x00')
  }
  { kind: 3, id, content: out.to_bytes(), }
}
