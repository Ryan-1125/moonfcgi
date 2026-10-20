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
/// Incremental byte-state decoder. No allocation uses a declared remote length.
pub struct ParamsDecoder {
  priv limit : Int
  priv max_pairs : Int
  priv pairs : Array[(Bytes, Bytes)]
  priv name : @buf.Buffer
  priv value : @buf.Buffer
  priv mut total : Int
  priv mut stage : Int // 0 name length, 1 value length, 2 name, 3 value
  priv mut prefix_left : Int
  priv mut prefix : Int
  priv mut name_length : Int
  priv mut value_length : Int
  priv mut ended : Bool
}

///|
pub fn ParamsDecoder::new(
  limit? : Int = 262144,
  max_pairs? : Int = 1024,
) -> ParamsDecoder raise ProtocolError {
  if limit < 0 || max_pairs < 0 {
    raise Invalid("negative params limit")
  }
  {
    limit,
    max_pairs,
    pairs: [],
    name: @buf.Buffer(),
    value: @buf.Buffer(),
    total: 0,
    stage: 0,
    prefix_left: 0,
    prefix: 0,
    name_length: 0,
    value_length: 0,
    ended: false,
  }
}

///|
fn ParamsDecoder::emit(self : ParamsDecoder) -> Unit raise ProtocolError {
  if self.pairs.length() >= self.max_pairs {
    raise Limit("parameter count")
  }
  self.pairs.push((self.name.to_bytes(), self.value.to_bytes()))
  self.name.reset()
  self.value.reset()
  self.stage = 0
}

///|
fn ParamsDecoder::length_ready(
  self : ParamsDecoder,
  n : Int,
) -> Unit raise ProtocolError {
  if n > self.limit {
    raise Limit("declared parameter length")
  }
  if self.stage == 0 {
    self.name_length = n
    self.stage = 1
  } else {
    self.value_length = n
    if n > self.limit - self.name_length {
      raise Limit("declared parameter pair length")
    }
    self.stage = if self.name_length == 0 { 3 } else { 2 }
    if self.name_length == 0 && n == 0 {
      self.emit()
    }
  }
}

///|
/// Accept any boundary, including inside the four-byte length prefix.
pub fn ParamsDecoder::feed(
  self : ParamsDecoder,
  data : Bytes,
) -> Unit raise ProtocolError {
  if self.ended {
    raise Invalid("PARAMS already ended or failed")
  }
  errdefer {
    self.ended = true
  }
  if data.length() > self.limit - self.total {
    raise Limit("PARAMS bytes")
  }
  self.total += data.length()
  for byte in data {
    if self.stage <= 1 {
      if self.prefix_left > 0 {
        self.prefix = self.prefix * 256 + byte.to_int()
        self.prefix_left -= 1
        if self.prefix_left == 0 {
          self.length_ready(self.prefix)
        }
      } else if byte.to_int() >= 128 {
        self.prefix = byte.to_int() - 128
        self.prefix_left = 3
      } else {
        self.length_ready(byte.to_int())
      }
    } else if self.stage == 2 {
      self.name.write_byte(byte)
      if self.name.length() == self.name_length {
        self.stage = 3
        if self.value_length == 0 {
          self.emit()
        }
      }
    } else {
      self.value.write_byte(byte)
      if self.value.length() == self.value_length {
        self.emit()
      }
    }
  }
}

///|
/// Explicit stream terminator. EOF or an empty feed is not a terminator.
pub fn ParamsDecoder::finish(
  self : ParamsDecoder,
) -> Array[(Bytes, Bytes)] raise ProtocolError {
  if self.ended {
    raise Invalid("PARAMS already ended or failed")
  }
  self.ended = true
  if self.stage != 0 || self.prefix_left != 0 {
    raise Truncated("parameter at stream end")
  }
  self.pairs.copy()
}
