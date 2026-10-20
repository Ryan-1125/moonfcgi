///|
/// Reusable asynchronous handler. Requests and responses are buffered.
pub type Handler = async (@fcgi.Request) -> @fcgi.Response

///|
/// Immutable configuration. Milliseconds; cycle deadline includes idle/request input.
pub struct Config {
  limits : @fcgi.Limits
  cycle_timeout_ms : Int
  write_timeout_ms : Int
  handler_timeout_ms : Int
}

///|
pub fn Config::new(
  limits? : @fcgi.Limits,
  cycle_timeout_ms? : Int = 30000,
  write_timeout_ms? : Int = 10000,
  handler_timeout_ms? : Int = 10000,
) -> Config raise {
  let limits = match limits {
    Some(value) => value
    None => @fcgi.Limits::new()
  }
  if cycle_timeout_ms <= 0 || write_timeout_ms <= 0 || handler_timeout_ms <= 0 {
    fail("timeouts must be positive")
  }
  { limits, cycle_timeout_ms, write_timeout_ms, handler_timeout_ms, }
}

///|
async fn send(
  conn : @socket.Tcp,
  records : Array[@fcgi.Record],
  config : Config,
) -> Unit {
  // One total deadline per response batch, rather than per fragment.
  @async.with_timeout(config.write_timeout_ms, () => {
    for record in records {
      conn.write(@fcgi.encode_record(record))
    }
  })
}

///| Run one connection. This function owns and always closes the socket.

///|
/// Handler cancellation is cooperative; CPU-bound handlers must yield periodically.
pub async fn serve_connection(
  conn : @socket.Tcp,
  handler : async (@fcgi.Request) -> @fcgi.Response,
  config? : Config,
) -> Unit {
  let config = match config {
    Some(value) => value
    None => Config::new()
  }
  defer conn.close()
  let session = @fcgi.Session::new(limits=config.limits)
  defer session.close()
  let decoder = @fcgi.Decoder::new()
  @async.with_task_group <| group => {
    let mutex = @async.Mutex()
    let timer = @async.Timer(config.cycle_timeout_ms)
    group.spawn_bg(no_wait=true) <| () => {
      timer.wait()
      fail("FastCGI idle/request cycle deadline exceeded")
    }
    let mut pending : (Int64, @async.Task[Unit])? = None
    while true {
      guard conn.read_some(max_len=8192) is Some(bytes) else {
        decoder.finish()
        session.finish()
        group.return_immediately(())
        break
      }
      for record in decoder.feed(bytes) {
        mutex.acquire()
        defer mutex.release()
        for event in session.accept(record) {
          match event {
            Send(records) => send(conn, records, config)
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
              let task = group.spawn(no_wait=true) <| () => {
                let response = @async.with_timeout(config.handler_timeout_ms, () => {
                  handler(request)
                }) catch {
                  error => {
                    if @async.is_cancellation_error(error) {
                      raise error
                    }
                    @fcgi.Response::new(b"Internal Server Error", status=500)
                  }
                }
                mutex.acquire()
                defer mutex.release()
                let events = session.complete(request, response) catch {
                  _ =>
                    session.complete(
                      request,
                      @fcgi.Response::new(b"", status=500),
                    )
                }
                for event in events {
                  match event {
                    Send(records) => send(conn, records, config)
                    Close => {
                      group.return_immediately(())
                      return
                    }
                    _ => ()
                  }
                }
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
    while true {
      slots.acquire()
      let (conn, _) = listener.accept()
      group.spawn_bg(allow_failure=true) <| () => {
        defer slots.release()
        serve_connection(conn, handler, config~)
      }
    }
  }
}
