///|
#borrow(path)
extern "C" fn unix_open(path : Bytes, mode : Int32) -> Int32 = "moonfcgi_unix_open"

///|
extern "C" fn listener_dup(fd : Int32) -> Int32 = "moonfcgi_listener_dup"

///|
#cfg(not(platform="windows"))
extern "C" fn listener_accept(fd : Int32) -> Int32 = "moonfcgi_listener_accept"

///|
#borrow(path)
extern "C" fn path_ino(path : Bytes) -> Int64 = "moonfcgi_path_ino"

///|
#borrow(path)
extern "C" fn path_dev(path : Bytes) -> Int64 = "moonfcgi_path_dev"

///|
#borrow(path)
extern "C" fn unix_remove(path : Bytes, ino : Int64, dev : Int64) -> Unit = "moonfcgi_unix_remove"

///|
#cfg(not(platform="windows"))
async fn serve_listener_fd(
  fd : Int32,
  handler : StreamHandler,
  config : Config,
  roles : Array[@fcgi.Role],
) -> Unit {
  let listener = @raw_fd.RawFd(fd)
  defer listener.close()
  @async.with_task_group <| group => {
    let slots = @async.Semaphore(config.limits.connections)
    run_accepting(
      group,
      config,
      () => {
        while true {
          slots.acquire()
          let mut accepted = listener_accept(fd)
          // async 0.20 has no public readiness wait for a listener fd.
          // Only accept is polled; connection I/O uses official async readiness.
          while accepted == -2 {
            @async.sleep(5)
            accepted = listener_accept(fd)
          }
          if accepted < 0 {
            fail("POSIX accept failed")
          }
          let conn = @raw_fd.RawFdStream(accepted)
          if config.control.is_stopping() {
            conn.close()
            return
          }
          group.spawn_bg(allow_failure=true) <| () => {
            defer slots.release()
            serve_raw_connection(conn, handler, config~, roles~)
          }
        }
      },
      () => listener.close(),
    )
  }
}

///|
/// Own a connected official RawFdStream and close it on every exit path.
/// The caller must obey RawFdStream's platform-specific descriptor requirements.
pub async fn serve_raw_connection(
  conn : @raw_fd.RawFdStream,
  handler : StreamHandler,
  config? : Config,
  roles~ : Array[@fcgi.Role] = [@fcgi.Responder],
) -> Unit {
  defer conn.close()
  serve_stream_io(conn, conn, handler, config?, roles~)
}

///|
#cfg(platform="windows")
async fn serve_listener_fd(
  _fd : Int32,
  _handler : StreamHandler,
  _config : Config,
  _roles : Array[@fcgi.Role],
) -> Unit {
  // Keep cancellation behavior consistent even on an unsupported platform.
  @async.pause()
  fail("POSIX listeners require a POSIX system")
}

///|
/// Filesystem Unix socket, restrictive mode by default. Never unlinks a pre-existing path.
pub async fn serve_unix(
  path : String,
  handler : StreamHandler,
  config? : Config,
  roles~ : Array[@fcgi.Role] = [@fcgi.Responder],
  mode~ : Int32 = 384,
) -> Unit {
  let config = match config {
    Some(v) => v
    None => Config::new()
  }
  if mode < 0 || mode > 511 {
    fail("socket mode must be 0000..0777")
  }
  let path = @utf8.encode(path)
  let fd = unix_open(path, mode)
  if fd < 0 {
    fail(
      "cannot bind Unix socket: unsupported platform, invalid path, permissions, or path already exists",
    )
  }
  let ino = path_ino(path)
  let dev = path_dev(path)
  defer unix_remove(path, ino, dev)
  serve_listener_fd(fd, handler, config, roles)
}

///|
/// Duplicate a pre-existing POSIX stream listener (fd0 by default).
/// The original fd remains caller-owned; O_NONBLOCK affects its shared open file description.
pub async fn serve_inherited(
  handler : StreamHandler,
  fd~ : Int32 = 0,
  config? : Config,
  roles~ : Array[@fcgi.Role] = [@fcgi.Responder],
) -> Unit {
  let config = match config {
    Some(v) => v
    None => Config::new()
  }
  let owned = listener_dup(fd)
  if owned < 0 {
    fail("inherited fd must be a listening POSIX TCP or Unix stream socket")
  }
  serve_listener_fd(owned, handler, config, roles)
}
