///|
/// Byte pairs deliberately preserve duplicate keys and non-UTF8 values.
pub fn encode_params(pairs : Array[(Bytes, Bytes)]) -> Bytes {
  let out = @buf.Buffer()
  fn length(n : Int, out : @buf.Buffer) {
    if n < 128 {
      out.write_byte(n.to_byte())
    } else {
      out.write_uint_be(n.reinterpret_as_uint() | 0x80000000U)
    }
  }
  for pair in pairs {
    let (name, value) = pair
    length(name.length(), out)
    length(value.length(), out)
    out.write_bytes(name)
    out.write_bytes(value)
  }
  out.to_bytes()
}

///|
/// Bounded accumulation across records. Decode only when the PARAMS stream ends.
pub struct ParamsDecoder {
  buffer : @buf.Buffer
  limit : Int
  max_pairs : Int
  mut ended : Bool
}

///|
pub fn ParamsDecoder::new(
  limit? : Int = 262144,
  max_pairs? : Int = 1024,
) -> ParamsDecoder raise ProtocolError {
  if limit < 0 || max_pairs < 0 {
    raise Invalid("negative params limit")
  }
  { buffer: @buf.Buffer(), limit, max_pairs, ended: false, }
}

///|
pub fn ParamsDecoder::feed(
  self : ParamsDecoder,
  data : Bytes,
) -> Unit raise ProtocolError {
  if self.ended {
    raise Invalid("PARAMS already ended")
  }
  if data.length() > self.limit - self.buffer.length() {
    self.ended = true
    raise Limit("PARAMS bytes")
  }
  self.buffer.write_bytes(data)
}

///|
pub fn ParamsDecoder::finish(
  self : ParamsDecoder,
) -> Array[(Bytes, Bytes)] raise ProtocolError {
  if self.ended {
    raise Invalid("PARAMS already ended")
  }
  self.ended = true
  let bytes = self.buffer.to_bytes()
  self.buffer.reset()
  let mut offset = 0
  fn read_length(
    bytes : Bytes,
    offset : Int,
  ) -> (Int, Int) raise ProtocolError {
    if offset >= bytes.length() {
      raise Truncated("parameter length")
    }
    let first = bytes[offset].to_int()
    if first < 128 {
      (first, offset + 1)
    } else {
      if bytes.length() - offset < 4 {
        raise Truncated("four-byte parameter length")
      }
      (
        (first - 128) * 16777216 +
        bytes[offset + 1].to_int() * 65536 +
        bytes[offset + 2].to_int() * 256 +
        bytes[offset + 3].to_int(),
        offset + 4,
      )
    }
  }
  let pairs = []
  while offset < bytes.length() {
    if pairs.length() >= self.max_pairs {
      raise Limit("parameter count")
    }
    let (nl, pos) = read_length(bytes, offset)
    let (vl, pos) = read_length(bytes, pos)
    // Subtraction avoids overflow for adversarial 31-bit length fields.
    if nl > bytes.length() - pos || vl > bytes.length() - pos - nl {
      raise Truncated("parameter value")
    }
    pairs.push(
      (bytes[pos:pos + nl].to_owned(), bytes[pos + nl:pos + nl + vl].to_owned()),
    )
    offset = pos + nl + vl
  }
  pairs
}
