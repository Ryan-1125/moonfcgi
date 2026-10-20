///|
/// Configuration is immutable after validation.
pub struct Limits {
  body_bytes : Int
  params_bytes : Int
  param_count : Int
  response_bytes : Int
  connections : Int
}

///|
pub fn Limits::new(
  body_bytes? : Int = 8388608,
  params_bytes? : Int = 262144,
  param_count? : Int = 1024,
  response_bytes? : Int = 8388608,
  connections? : Int = 64,
) -> Limits raise ProtocolError {
  if body_bytes < 0 ||
    params_bytes < 0 ||
    param_count < 0 ||
    response_bytes < 0 ||
    connections <= 0 {
    raise Invalid("invalid resource limits")
  }
  { body_bytes, params_bytes, param_count, response_bytes, connections, }
}

///|
priv struct Pending {
  id : Int
  token : Int64
  keep : Bool
  params_decoder : ParamsDecoder
  body : @buf.Buffer
  mut params : Array[(Bytes, Bytes)]?
  mut ready : Bool
}

///|
/// Events are consumed in order by a transport adapter.
pub(all) enum Event {
  Send(Array[Record])
  Ready(Request)
  Aborted(Int64)
  Close
}

///|
pub struct Session {
  priv limits : Limits
  priv mut active : Pending?
  priv mut serial : Int64
  priv mut closed : Bool
}

///|
pub fn Session::new(limits? : Limits) -> Session raise ProtocolError {
  let limits = match limits {
    Some(value) => value
    None => Limits::new()
  }
  { limits, active: None, serial: 0L, closed: false, }
}

///|
/// A malformed record poisons this session. The adapter must close the transport.
pub fn Session::accept(
  self : Session,
  record : Record,
) -> Array[Event] raise ProtocolError {
  if self.closed {
    raise Invalid("session is closed")
  }
  errdefer {
    self.closed = true
    self.active = None
  }
  self.accept_inner(record)
}

///|
fn Session::accept_inner(
  self : Session,
  record : Record,
) -> Array[Event] raise ProtocolError {
  if record.id < 0 ||
    record.id > 65535 ||
    record.kind < 0 ||
    record.kind > 255 ||
    record.content.length() > 65535 {
    raise Invalid("invalid record")
  }
  let data = record.content
  if record.id == 0 {
    if record.kind == 9 {
      let params = ParamsDecoder::new(
        limit=self.limits.params_bytes,
        max_pairs=self.limits.param_count,
      )
      params.feed(data)
      let names = params.finish()
      let result = []
      for pair in names {
        let value = if pair.0 == b"FCGI_MPXS_CONNS" {
          Some(b"0")
        } else if pair.0 == b"FCGI_MAX_CONNS" || pair.0 == b"FCGI_MAX_REQS" {
          Some(@utf8.encode(self.limits.connections.to_string()))
        } else {
          None
        }
        if value is Some(v) {
          result.push((pair.0, v))
        }
      }
      let content = encode_params(result)
      if content.length() > 65535 {
        raise Limit("GET_VALUES_RESULT content")
      }
      return [Send([{ kind: 10, id: 0, content, }])]
    }
    if record.kind >= 1 && record.kind <= 11 {
      raise Invalid("application or response record with id zero")
    }
    return [
      Send([
        {
          kind: 11,
          id: 0,
          content: Bytes::makei(8, i => {
            if i == 0 {
              record.kind.to_byte()
            } else {
              b'\x00'
            }
          }),
        },
      ]),
    ]
  }
  if record.kind == 1 {
    if data.length() != 8 {
      raise Invalid("BEGIN_REQUEST must have 8 content bytes")
    }
    if self.active is Some(pending) {
      if pending.id == record.id {
        raise Invalid("request id already active")
      }
      return [Send([end_record(record.id, protocol_status=1)])]
    }
    let keep = (data[2].to_int() & 1) != 0
    if data[0] != b'\x00' || data[1] != b'\x01' {
      let events = [Send([end_record(record.id, protocol_status=3)])]
      if !keep {
        self.closed = true
        events.push(Close)
      }
      return events
    }
    self.serial += 1L
    self.active = Some({
      id: record.id,
      token: self.serial,
      keep,
      params_decoder: ParamsDecoder::new(
        limit=self.limits.params_bytes,
        max_pairs=self.limits.param_count,
      ),
      body: @buf.Buffer(),
      params: None,
      ready: false,
    })
    return []
  }
  guard self.active is Some(pending) && pending.id == record.id else {
    return []
  }
  if record.kind == 2 {
    if !data.is_empty() {
      raise Invalid("ABORT_REQUEST content must be empty")
    }
    self.active = None
    let events = [Aborted(pending.token), Send([end_record(pending.id)])]
    if !pending.keep {
      self.closed = true
      events.push(Close)
    }
    return events
  }
  if record.kind == 4 {
    if pending.params is Some(_) {
      raise Invalid("PARAMS after stream termination")
    }
    if data.is_empty() {
      pending.params = Some(pending.params_decoder.finish())
    } else {
      pending.params_decoder.feed(data)
    }
    return []
  }
  if record.kind == 5 {
    guard pending.params is Some(params) else {
      raise Invalid("STDIN before PARAMS termination")
    }
    if pending.ready {
      raise Invalid("STDIN after stream termination")
    }
    if data.length() > self.limits.body_bytes - pending.body.length() {
      raise Limit("request body")
    }
    if !data.is_empty() {
      pending.body.write_bytes(data)
      return []
    }
    let body = pending.body.to_bytes()
    // CGI CONTENT_LENGTH, if present, must agree with the supplied byte stream.
    for pair in params {
      if pair.0 == b"CONTENT_LENGTH" && !pair.1.is_empty() {
        let mut size = 0
        for b in pair.1 {
          let digit = b.to_int() - 48
          if digit < 0 || digit > 9 {
            raise Invalid("CONTENT_LENGTH is not decimal")
          }
          if size > (self.limits.body_bytes - digit) / 10 {
            raise Limit("CONTENT_LENGTH")
          }
          size = size * 10 + digit
          if size > self.limits.body_bytes {
            raise Limit("CONTENT_LENGTH")
          }
        }
        if size != body.length() {
          raise Invalid("CONTENT_LENGTH mismatch")
        }
      }
    }
    pending.ready = true
    pending.body.reset()
    return [Ready({ id: pending.id, token: pending.token, params, body, })]
  }
  raise Invalid("unexpected record direction or type for active request")
}

///|
/// Finish only the current generation; aborted or stale completions are ignored.
pub fn Session::complete(
  self : Session,
  request : Request,
  response : Response,
) -> Array[Event] raise ProtocolError {
  guard !self.closed &&
    self.active is Some(pending) &&
    pending.ready &&
    pending.token == request.token &&
    pending.id == request.id else {
    return []
  }
  if response.body.length() > self.limits.response_bytes ||
    response.stderr.length() > self.limits.response_bytes {
    raise Limit("response bytes")
  }
  let bytes = response.cgi_bytes(
    head=request.param("REQUEST_METHOD") == Some(b"HEAD"),
  )
  let records = stream_records(6, request.id, bytes)
  for record in stream_records(7, request.id, response.stderr) {
    records.push(record)
  }
  records.push(end_record(request.id))
  self.active = None
  let events = [Send(records)]
  if !pending.keep {
    self.closed = true
    events.push(Close)
  }
  events
}

///|
/// Connection cleanup; no protocol writes are possible after this call.
pub fn Session::close(self : Session) -> Unit {
  self.closed = true
  self.active = None
}

///|
pub fn Session::finish(self : Session) -> Unit raise ProtocolError {
  if self.active is Some(_) {
    self.close()
    raise Truncated("request at EOF")
  }
  self.close()
}
