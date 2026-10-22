///|
pub(all) enum Stage {
  Idle
  Input
  Handler
  Write
  Cycle
  Shutdown
} derive(Eq, Debug)

///|
pub extend Stage with Eq::{equal, not_equal}

///|
pub extend Stage with @debug.Debug::{to_repr}

///|
pub suberror ServerError {
  Protocol(String)
  Transport(String)
  Handler(String)
  Deadline(Stage)
} derive(Debug)

///|
pub extend ServerError with @debug.Debug::{to_repr}

///|
pub(all) enum Outcome {
  Completed
  Failed
  Aborted
  Cancelled
} derive(Eq, Debug)

///|
pub extend Outcome with Eq::{equal, not_equal}

///|
pub extend Outcome with @debug.Debug::{to_repr}

///|
pub(all) struct RequestReport {
  connection_id : Int64
  request_id : Int32
  outcome : Outcome
  elapsed_ms : Int64
  input_content_bytes : Int64
  output_content_bytes : Int64
} derive(Debug)

///|
pub extend RequestReport with @debug.Debug::{to_repr}

///|
pub(all) enum ServerEvent {
  ConnectionOpened(Int64)
  RequestStarted(Int64, Int32)
  RequestFinished(RequestReport)
  ConnectionError(Int64, ServerError)
  ConnectionClosed(Int64)
} derive(Debug)

///|
pub extend ServerEvent with @debug.Debug::{to_repr}

///|
pub(all) struct Snapshot {
  connections : Int64
  active_connections : Int64
  requests : Int64
  active_requests : Int64
  completed : Int64
  failed : Int64
  aborted : Int64
  cancelled : Int64
  bytes_read : Int64
  bytes_written : Int64
  protocol_errors : Int64
  transport_errors : Int64
  handler_errors : Int64
  timeouts : Int64
  observer_errors : Int64
} derive(Debug)

///|
pub extend Snapshot with @debug.Debug::{to_repr}

///|
/// Shared counters for one cooperative async event loop; not thread-safe.
pub struct Stats {
  priv mut value : Snapshot
}

///|
pub fn Stats::new() -> Stats {
  {
    value: {
      connections: 0L,
      active_connections: 0L,
      requests: 0L,
      active_requests: 0L,
      completed: 0L,
      failed: 0L,
      aborted: 0L,
      cancelled: 0L,
      bytes_read: 0L,
      bytes_written: 0L,
      protocol_errors: 0L,
      transport_errors: 0L,
      handler_errors: 0L,
      timeouts: 0L,
      observer_errors: 0L,
    },
  }
}

///|
/// A value copy: callers cannot mutate the live counters.
pub fn Stats::snapshot(self : Stats) -> Snapshot {
  self.value
}

///|
/// One-shot stop token. Create a fresh token/configuration to restart.
pub struct Control {
  priv mut stopping : Bool
  priv changed : @cond.Cond
}

///|
pub fn Control::new() -> Control {
  { stopping: false, changed: @cond.Cond(), }
}

///|
pub fn Control::shutdown(self : Control) -> Unit {
  if !self.stopping {
    self.stopping = true
    self.changed.broadcast()
  }
}

///|
pub fn Control::is_stopping(self : Control) -> Bool {
  self.stopping
}

///|
async fn Control::wait(self : Control) -> Unit {
  while !self.stopping {
    self.changed.wait()
  }
}

///|
fn clock_ms() -> Int64 {
  @env.now().reinterpret_as_int64()
}

///|
fn Config::emit(self : Config, event : ServerEvent) -> Unit {
  (self.on_event)(event) catch {
    _ => {
      let s = self.stats.value
      self.stats.value = { ..s, observer_errors: s.observer_errors + 1L, }
    }
  }
}

///|
priv struct ConnectionState {
  config : Config
  id : Int64
  changed : @cond.Cond
  mut active : Bool
  mut request_id : Int32
  mut started : Int64
  mut input : Int64
  mut output : Int64
  mut idle_since : Int64?
  mut input_since : Int64?
}

///|
fn ConnectionState::new(config : Config) -> ConnectionState {
  let s = config.stats.value
  let id = s.connections + 1L
  config.stats.value = {
    ..s,
    connections: id,
    active_connections: s.active_connections + 1L,
  }
  let state = {
    config,
    id,
    changed: @cond.Cond(),
    active: false,
    request_id: 0,
    started: 0L,
    input: 0L,
    output: 0L,
    idle_since: Some(clock_ms()),
    input_since: None,
  }
  config.emit(ConnectionOpened(id))
  state
}

///|
fn ConnectionState::begin_input(self : ConnectionState) -> Unit {
  if self.idle_since is Some(_) {
    self.idle_since = None
    self.input_since = Some(clock_ms())
    self.changed.broadcast()
  }
}

///|
fn ConnectionState::start(self : ConnectionState, id : Int32) -> Unit {
  if self.active {
    return
  }
  self.active = true
  self.request_id = id
  self.started = clock_ms()
  self.input = 0L
  self.output = 0L
  self.begin_input()
  let s = self.config.stats.value
  self.config.stats.value = {
    ..s,
    requests: s.requests + 1L,
    active_requests: s.active_requests + 1L,
  }
  self.config.emit(RequestStarted(self.id, id))
}

///|
fn ConnectionState::input_end(self : ConnectionState) -> Unit {
  self.input_since = None
  self.changed.broadcast()
}

///|
fn ConnectionState::idle(self : ConnectionState) -> Unit {
  self.input_since = None
  self.idle_since = Some(clock_ms())
  self.changed.broadcast()
}

///|
fn ConnectionState::finish(self : ConnectionState, outcome : Outcome) -> Unit {
  if !self.active {
    return
  }
  self.active = false
  let s = self.config.stats.value
  self.config.stats.value = {
    ..s,
    active_requests: s.active_requests - 1L,
    completed: s.completed + (if outcome == Completed { 1L } else { 0L }),
    failed: s.failed + (if outcome == Failed { 1L } else { 0L }),
    aborted: s.aborted + (if outcome == Aborted { 1L } else { 0L }),
    cancelled: s.cancelled + (if outcome == Cancelled { 1L } else { 0L }),
  }
  self.changed.broadcast()
  self.config.emit(
    RequestFinished({
      connection_id: self.id,
      request_id: self.request_id,
      outcome,
      elapsed_ms: clock_ms() - self.started,
      input_content_bytes: self.input,
      output_content_bytes: self.output,
    }),
  )
}

///|
fn ConnectionState::error(self : ConnectionState, error : ServerError) -> Unit {
  let s = self.config.stats.value
  self.config.stats.value = match error {
    Protocol(_) => { ..s, protocol_errors: s.protocol_errors + 1L, }
    Transport(_) => { ..s, transport_errors: s.transport_errors + 1L, }
    Handler(_) => { ..s, handler_errors: s.handler_errors + 1L, }
    Deadline(_) => { ..s, timeouts: s.timeouts + 1L, }
  }
  self.config.emit(ConnectionError(self.id, error))
}

///|
fn ConnectionState::close(self : ConnectionState) -> Unit {
  self.finish(Cancelled)
  let s = self.config.stats.value
  self.config.stats.value = {
    ..s,
    active_connections: s.active_connections - 1L,
  }
  self.config.emit(ConnectionClosed(self.id))
}

///|
fn ConnectionState::received(self : ConnectionState, bytes : Bytes) -> Unit {
  let s = self.config.stats.value
  self.config.stats.value = {
    ..s,
    bytes_read: s.bytes_read + bytes.length().to_int64(),
  }
  self.begin_input()
}

///|
fn ConnectionState::input_record(
  self : ConnectionState,
  record : @fcgi.Record,
) -> Unit {
  if self.active && record.id == self.request_id {
    self.input += record.content.length().to_int64()
  }
}

///|
fn ConnectionState::sent(self : ConnectionState, bytes : Bytes) -> Unit {
  let s = self.config.stats.value
  self.config.stats.value = {
    ..s,
    bytes_written: s.bytes_written + bytes.length().to_int64(),
  }
  if self.active &&
    bytes.length() >= 8 &&
    bytes[2].to_int() * 256 + bytes[3].to_int() == self.request_id {
    self.output += (bytes[4].to_int() * 256 + bytes[5].to_int()).to_int64()
    if bytes[1] == b'\x03' && bytes.length() >= 16 && bytes[12] != b'\x00' {
      self.finish(Failed)
      self.idle()
    }
  }
}

///|
fn classify(error : Error) -> ServerError {
  match error {
    ServerError::Protocol(_) as e => e
    ServerError::Transport(_) as e => e
    ServerError::Handler(_) as e => e
    ServerError::Deadline(_) as e => e
    @fcgi.Invalid(s) | @fcgi.Limit(s) | @fcgi.Truncated(s) =>
      ServerError::Protocol(s)
    _ => ServerError::Transport(error.to_string())
  }
}

///|
async fn observed(
  config : Config,
  run : async (ConnectionState) -> Unit,
) -> Unit {
  let state = ConnectionState::new(config)
  defer state.close()
  let failure = try {
    run(state)
    None
  } catch {
    error => Some(error)
  }
  if failure is Some(error) {
    if @async.is_cancellation_error(error) {
      state.finish(Cancelled)
      raise error
    }
    let error = classify(error)
    state.error(error)
    state.finish(Failed)
    raise error
  }
}

///|
async fn ConnectionState::watch_deadlines(self : ConnectionState) -> Unit {
  while true {
    let (since, duration, stage) = if self.input_since is Some(t) {
      (Some(t), self.config.input_timeout_ms, Stage::Input)
    } else {
      (self.idle_since, self.config.idle_timeout_ms, Stage::Idle)
    }
    if since is Some(t) {
      let remaining = duration.to_int64() - (clock_ms() - t)
      if remaining <= 0L {
        raise ServerError::Deadline(stage)
      }
      ignore(
        @async.with_timeout_opt(remaining.to_int(), () => self.changed.wait()),
      )
    } else {
      self.changed.wait()
    }
  }
}

///|
async fn ConnectionState::wait_shutdown(self : ConnectionState) -> Unit {
  self.config.control.wait()
  @async.with_timeout(
    self.config.shutdown_timeout_ms,
    () => {
      while self.active {
        self.changed.wait()
      }
    },
    error=ServerError::Deadline(Stage::Shutdown),
  )
}

///|
async fn run_accepting(
  group : @async.TaskGroup[Unit],
  config : Config,
  accept_loop : async () -> Unit,
  close_listener : () -> Unit,
) -> Unit {
  if config.control.is_stopping() {
    return
  }
  let accept = group.spawn(no_wait=true, allow_failure=true, accept_loop)
  group.spawn_bg(no_wait=true) <| () => {
    config.control.wait()
    accept.cancel()
    close_listener()
  }
  accept.wait() catch {
    error =>
      if !config.control.is_stopping() {
        if @async.is_cancellation_error(error) {
          raise error
        }
        raise classify(error)
      }
  }
  // Connection tasks are waiting children; the group drains them before returning.
}
