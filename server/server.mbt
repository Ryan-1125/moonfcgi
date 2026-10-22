///|
/// Reusable asynchronous handler. Requests and responses are buffered.
pub type Handler = async (@fcgi.Request) -> @fcgi.Response

///|
/// Immutable configuration. Milliseconds; cycle deadline includes idle/request input.
pub struct Config {
  limits : @fcgi.Limits
  cycle_timeout_ms : Int32
  write_timeout_ms : Int32
  handler_timeout_ms : Int32
  idle_timeout_ms : Int32
  input_timeout_ms : Int32
  shutdown_timeout_ms : Int32
  input_queue_records : Int32
  control : Control
  stats : Stats
  priv on_event : (ServerEvent) -> Unit raise
}

///|
pub fn Config::new(
  limits? : @fcgi.Limits,
  cycle_timeout_ms~ : Int32 = 30000,
  write_timeout_ms~ : Int32 = 10000,
  handler_timeout_ms~ : Int32 = 10000,
  idle_timeout_ms? : Int32,
  input_timeout_ms? : Int32,
  shutdown_timeout_ms~ : Int32 = 10000,
  input_queue_records~ : Int32 = 4,
  control? : Control,
  stats? : Stats,
  on_event~ : (ServerEvent) -> Unit raise = _ => (),
) -> Config raise {
  let limits = match limits {
    Some(value) => value
    None => @fcgi.Limits::new()
  }
  let idle_timeout_ms = idle_timeout_ms.unwrap_or(cycle_timeout_ms)
  let input_timeout_ms = input_timeout_ms.unwrap_or(cycle_timeout_ms)
  if cycle_timeout_ms <= 0 ||
    write_timeout_ms <= 0 ||
    handler_timeout_ms <= 0 ||
    idle_timeout_ms <= 0 ||
    input_timeout_ms <= 0 ||
    shutdown_timeout_ms <= 0 {
    fail("timeouts must be positive")
  }
  if input_queue_records < 1 || input_queue_records > 1024 {
    fail("input queue capacity must be 1..1024 records")
  }
  {
    limits,
    cycle_timeout_ms,
    write_timeout_ms,
    handler_timeout_ms,
    idle_timeout_ms,
    input_timeout_ms,
    shutdown_timeout_ms,
    input_queue_records,
    control: control.unwrap_or_else(() => Control::new()),
    stats: stats.unwrap_or_else(() => Stats::new()),
    on_event,
  }
}

///|
async fn send(
  conn : @socket.Tcp,
  records : Array[@fcgi.Record],
  config : Config,
  state : ConnectionState,
) -> Unit {
  // One total deadline per response batch, rather than per fragment.
  @async.with_timeout(
    config.write_timeout_ms,
    () => {
      for record in records {
        let bytes = @fcgi.encode_record(record)
        conn.write(bytes) catch {
          error => {
            if @async.is_cancellation_error(error) {
              raise error
            }
            raise ServerError::Transport(error.to_string())
          }
        }
        state.sent(bytes)
      }
    },
    error=ServerError::Deadline(Stage::Write),
  )
}

///| Run one connection. This function owns and always closes the socket.

///|
/// Handler cancellation is cooperative; CPU-bound handlers must yield periodically.
pub async fn serve_connection(
  conn : @socket.Tcp,
  handler : Handler,
  config? : Config,
) -> Unit {
  let config = match config {
    Some(v) => v
    None => Config::new()
  }
  defer conn.close()
  if config.control.is_stopping() {
    return
  }
  observed(config, state => buffered_io(conn, handler, config, state))
}

///|
async fn buffered_io(
  conn : @socket.Tcp,
  handler : Handler,
  config : Config,
  state : ConnectionState,
) -> Unit {
  let session = @fcgi.Session::new(limits=config.limits)
  defer session.close()
  let decoder = @fcgi.Decoder::new()
  @async.with_task_group <| group => {
    let mutex = @async.Mutex()
    let timer = @async.Timer(config.cycle_timeout_ms)
    group.spawn_bg(no_wait=true) <| () => {
      timer.wait()
      raise ServerError::Deadline(Stage::Cycle)
    }
    group.spawn_bg(no_wait=true, () => state.watch_deadlines())
    group.spawn_bg(no_wait=true) <| () => {
      state.wait_shutdown()
      group.return_immediately(())
    }
    let mut pending : (Int64, @async.Task[Unit])? = None
    while true {
      guard conn.read_some(max_len=8192) is Some(bytes) else {
        decoder.finish()
        session.finish()
        group.return_immediately(())
        break
      }
      state.received(bytes)
      for record in decoder.feed(bytes) {
        if record.kind == 1 && !state.active {
          if config.control.is_stopping() {
            group.return_immediately(())
            return
          }
          state.start(record.id)
        }
        state.input_record(record)
        mutex.acquire()
        defer mutex.release()
        for event in session.accept(record) {
          match event {
            Send(records) => {
              send(conn, records, config, state)
              if record.kind == 2 {
                state.finish(Aborted)
                state.idle()
              }
            }
            Close => {
              group.return_immediately(())
              return
            }
            Aborted(token) => {
              if pending is Some((current, task)) && current == token {
                task.cancel()
                pending = None
              }
              timer.refresh()
            }
            Ready(request) => {
              state.input_end()
              let task = group.spawn(no_wait=true) <| () => {
                let mut outcome = Outcome::Completed
                let response = @async.with_timeout(
                  config.handler_timeout_ms,
                  () => handler(request),
                  error=ServerError::Deadline(Stage::Handler),
                ) catch {
                  error => {
                    if @async.is_cancellation_error(error) {
                      raise error
                    }
                    match error {
                      ServerError::Deadline(Stage::Write)
                      | ServerError::Transport(_) => raise error
                      ServerError::Deadline(Stage::Handler) =>
                        state.error(classify(error))
                      _ => state.error(ServerError::Handler(error.to_string()))
                    }
                    outcome = Failed
                    @fcgi.Response::new(b"Internal Server Error", status=500)
                  }
                }
                mutex.acquire()
                defer mutex.release()
                let events = session.complete(request, response) catch {
                  error => {
                    state.error(classify(error))
                    outcome = Failed
                    session.complete(
                      request,
                      @fcgi.Response::new(b"", status=500),
                    )
                  }
                }
                for event in events {
                  match event {
                    Send(records) => send(conn, records, config, state)
                    Close => {
                      state.finish(outcome)
                      group.return_immediately(())
                      return
                    }
                    _ => ()
                  }
                }
                state.finish(outcome)
                state.idle()
                if pending is Some((token, _)) && token == request.token {
                  pending = None
                }
                timer.refresh()
              }
              pending = Some((request.token, task))
            }
          }
        }
      }
    }
  }
}

///| Serve many independent connections, bounded by the configured concurrency.

///|
/// Connection failures are contained; listener cancellation closes children.
pub async fn serve(
  address : String,
  handler : async (@fcgi.Request) -> @fcgi.Response,
  config? : Config,
) -> Unit {
  let config = match config {
    Some(value) => value
    None => Config::new()
  }
  let listener = @socket.TcpServer(@socket.Addr::parse(address))
  defer listener.close()
  @async.with_task_group <| group => {
    let slots = @async.Semaphore(config.limits.connections)
    run_accepting(
      group,
      config,
      () => {
        while true {
          slots.acquire()
          let (conn, _) = listener.accept()
          if config.control.is_stopping() {
            conn.close()
            return
          }
          group.spawn_bg(allow_failure=true) <| () => {
            defer slots.release()
            serve_connection(conn, handler, config~)
          }
        }
      },
      () => listener.close(),
    )
  }
}
