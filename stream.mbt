///|
pub(all) enum Role {
  Responder
  Authorizer
  Filter
} derive(Eq)

///|
pub struct RequestHead {
  priv owner : StreamSession
  id : Int32
  token : Int64
  role : Role
  params : Array[(Bytes, Bytes)]
}

///|
pub fn RequestHead::param(self : RequestHead, name : String) -> Bytes? {
  let key = @utf8.encode(name)
  for i = self.params.length() - 1; i >= 0; i = i - 1 {
    if self.params[i].0 == key {
      return Some(self.params[i].1)
    }
  }
  None
}

///|
pub fn RequestHead::text_param(
  self : RequestHead,
  name : String,
) -> String? raise {
  self.param(name).map(value => @utf8.decode(value))
}

///|
priv struct StreamPending {
  id : Int32
  token : Int64
  role : Role
  keep : Bool
  decoder : ParamsDecoder
  mut params_done : Bool
  mut stdin_done : Bool
  mut data_done : Bool
  mut input_count : Int32
  mut data_count : Int32
  mut expected : Int32?
  mut expected_data : Int32?
  mut completed : Bool
}

///|
pub(all) enum StreamEvent {
  Send(Array[Record])
  Start(RequestHead)
  Input(Int64, Int32, Bytes)
  InputEnd(Int64, Int32)
  Aborted(Int64)
  Close
}

///|
/// Socket-independent streaming state machine. One request per connection.
pub struct StreamSession {
  priv limits : Limits
  priv roles : Array[Role]
  priv mut pending : StreamPending?
  priv mut serial : Int64
  priv mut closed : Bool
}

///|
pub fn StreamSession::new(
  limits? : Limits,
  roles~ : Array[Role] = [Responder],
) -> StreamSession raise {
  let limits = match limits {
    Some(v) => v
    None => Limits::new()
  }
  { limits, roles: roles.copy(), pending: None, serial: 0L, closed: false, }
}

///|
pub fn StreamSession::close(self : StreamSession) -> Unit {
  self.closed = true
  self.pending = None
}

///|
/// True only after both input streams and the response have completed.
pub fn StreamSession::is_idle(self : StreamSession) -> Bool {
  !self.closed && self.pending is None
}

///|
pub fn StreamSession::finish(self : StreamSession) -> Unit raise ProtocolError {
  let incomplete = self.pending is Some(_)
  self.close()
  if incomplete {
    raise Truncated("streaming request at EOF")
  }
}

///|
fn StreamSession::retire(
  self : StreamSession,
  p : StreamPending,
) -> Array[StreamEvent] {
  if p.completed && p.stdin_done && p.data_done {
    self.pending = None
    if !p.keep {
      self.closed = true
      return [Close]
    }
  }
  []
}

///|
pub fn StreamSession::is_active(
  self : StreamSession,
  head : RequestHead,
) -> Bool {
  !self.closed &&
  physical_equal(self, head.owner) &&
  self.pending is Some(p) &&
  p.token == head.token &&
  !p.completed
}

///|
pub fn StreamSession::can_output(
  self : StreamSession,
  head : RequestHead,
) -> Bool {
  self.is_active(head) &&
  self.pending is Some(p) &&
  (p.role != Filter || p.stdin_done)
}

///|
pub fn StreamSession::complete(
  self : StreamSession,
  head : RequestHead,
  app_status~ : UInt32 = 0U,
) -> Array[StreamEvent] {
  if !self.can_output(head) {
    return []
  }
  guard self.pending is Some(p) else { return [] }
  p.completed = true
  let events : Array[StreamEvent] = [
    Send([
      { kind: 6, id: p.id, content: b"", },
      { kind: 7, id: p.id, content: b"", },
      end_record(p.id, app_status~),
    ]),
  ]
  for event in self.retire(p) {
    events.push(event)
  }
  events
}

///|
pub fn StreamSession::accept(
  self : StreamSession,
  record : Record,
) -> Array[StreamEvent] raise ProtocolError {
  if self.closed {
    raise Invalid("stream session closed")
  }
  errdefer self.close()
  self.accept_inner(record)
}

///|
fn StreamSession::accept_inner(
  self : StreamSession,
  record : Record,
) -> Array[StreamEvent] raise ProtocolError {
  // Validate constructed records too, not just Decoder output.
  ignore(encode_record(record))
  if record.id == 0 {
    let management = Session::new(limits=self.limits)
    let out = []
    for event in management.accept(record) {
      if event is Send(records) {
        out.push(StreamEvent::Send(records))
      }
    }
    return out
  }
  let bytes = record.content
  if record.kind == 1 {
    if bytes.length() != 8 {
      raise Invalid("BEGIN length")
    }
    if self.pending is Some(p) {
      if p.id == record.id {
        raise Invalid("duplicate active request id")
      }
      return [Send([end_record(record.id, protocol_status=1)])]
    }
    let keep = (bytes[2].to_int() & 1) != 0
    let role = if bytes[0] != b'\x00' {
      None
    } else {
      match bytes[1].to_int() {
        1 => Some(Responder)
        2 => Some(Authorizer)
        3 => Some(Filter)
        _ => None
      }
    }
    guard role is Some(role) && self.roles.contains(role) else {
      let events = [
        StreamEvent::Send([end_record(record.id, protocol_status=3)]),
      ]
      if !keep {
        self.closed = true
        events.push(Close)
      }
      return events
    }
    self.serial += 1L
    self.pending = Some({
      id: record.id,
      token: self.serial,
      role,
      keep,
      decoder: ParamsDecoder::new(
        limit=self.limits.params_bytes,
        max_pairs=self.limits.param_count,
      ),
      params_done: false,
      stdin_done: role == Authorizer,
      data_done: role != Filter,
      input_count: 0,
      data_count: 0,
      expected: None,
      expected_data: None,
      completed: false,
    })
    return []
  }
  guard self.pending is Some(p) && p.id == record.id else { return [] }
  if record.kind == 2 {
    if !bytes.is_empty() {
      raise Invalid("ABORT content")
    }
    self.pending = None
    let events = [StreamEvent::Aborted(p.token)]
    if !p.completed {
      events.push(Send([end_record(p.id)]))
    }
    if !p.keep {
      self.closed = true
      events.push(Close)
    }
    return events
  }
  if record.kind == 4 {
    if p.params_done {
      raise Invalid("PARAMS after EOF")
    }
    if !bytes.is_empty() {
      p.decoder.feed(bytes)
      return []
    }
    let params = p.decoder.finish()
    p.expected = declared_length(params, self.limits.body_bytes)
    let data_params = []
    for (name, value) in params {
      if name == b"FCGI_DATA_LENGTH" {
        data_params.push((b"CONTENT_LENGTH", value))
      }
    }
    p.expected_data = declared_length(data_params, self.limits.body_bytes)
    p.params_done = true
    return [
      Start({ owner: self, id: p.id, token: p.token, role: p.role, params, }),
    ]
  }
  if !p.params_done {
    raise Invalid("input before PARAMS EOF")
  }
  if record.kind == 5 {
    if p.stdin_done {
      raise Invalid("STDIN after EOF or for Authorizer")
    }
    if bytes.length() > self.limits.body_bytes - p.input_count {
      raise Limit("stream STDIN")
    }
    if p.expected is Some(n) && bytes.length() > n - p.input_count {
      raise Invalid("STDIN exceeds length")
    }
    p.input_count += bytes.length()
    if !bytes.is_empty() {
      return [Input(p.token, 5, bytes)]
    }
    if p.expected is Some(n) && n != p.input_count {
      raise Invalid("STDIN length mismatch")
    }
    p.stdin_done = true
    let events = [StreamEvent::InputEnd(p.token, 5)]
    for event in self.retire(p) {
      events.push(event)
    }
    return events
  }
  if record.kind == 8 {
    if p.role != Filter || !p.stdin_done || p.data_done {
      raise Invalid("DATA sequence")
    }
    if bytes.length() > self.limits.body_bytes - p.data_count {
      raise Limit("stream DATA")
    }
    if p.expected_data is Some(n) && bytes.length() > n - p.data_count {
      raise Invalid("DATA exceeds length")
    }
    p.data_count += bytes.length()
    if !bytes.is_empty() {
      return [Input(p.token, 8, bytes)]
    }
    if p.expected_data is Some(n) && n != p.data_count {
      raise Invalid("DATA length mismatch")
    }
    p.data_done = true
    let events = [StreamEvent::InputEnd(p.token, 8)]
    for event in self.retire(p) {
      events.push(event)
    }
    return events
  }
  raise Invalid("unexpected stream record")
}

///|
pub extend Role with Eq::{equal, not_equal}
