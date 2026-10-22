///|
pub struct BodyStream {
  priv queue : @aqueue.Queue[Bytes?]
  priv mut ended : Bool
}

///|
fn BodyStream::new() -> BodyStream {
  { queue: @aqueue.Queue(kind=Blocking(4)), ended: false, }
}

///|
/// One record-sized chunk, or None at the explicit FastCGI stream terminator.
/// Only one consumer may read a stream at a time.
pub async fn BodyStream::read(self : BodyStream) -> Bytes? {
  if self.ended {
    return None
  }
  let next = self.queue.get()
  if next is None {
    self.ended = true
  }
  next
}

///|
pub struct StreamRequest {
  head : @fcgi.RequestHead
  body : BodyStream
  data : BodyStream
}

///|
pub struct ResponseWriter {
  priv head : @fcgi.RequestHead
  priv session : @fcgi.StreamSession
  priv output : async (Bytes) -> Unit
  priv mutex : @async.Mutex
  priv limit : Int32
  priv mut started : Bool
  priv mut finished : Bool
  priv mut suppress : Bool
  priv mut expected : Int32?
  priv mut count : Int32
  priv mut errors : Int32
}

///|
pub type StreamHandler = async (StreamRequest, ResponseWriter) -> Unit

///|
async fn ResponseWriter::record(
  self : ResponseWriter,
  kind : Int32,
  bytes : Bytes,
) -> Unit {
  let mut offset = 0
  while offset < bytes.length() {
    let size = Int32::min(65535, bytes.length() - offset)
    (self.output)(
      @fcgi.encode_record({
        kind,
        id: self.head.id,
        content: bytes[offset:offset + size].to_owned(),
      }),
    )
    offset += size
  }
}

///|
/// Commit CGI headers once. Unknown length produces no Content-Length header.
pub async fn ResponseWriter::start(
  self : ResponseWriter,
  status~ : Int32 = 200,
  headers~ : Array[(String, String)] = [],
  content_length? : Int32,
) -> Unit {
  let response = @fcgi.Response::new(b"", status~, headers~)
  let bytes = response.cgi_headers(content_length?)
  self.mutex.acquire()
  defer self.mutex.release()
  if self.started || self.finished || !self.session.can_output(self.head) {
    fail("response cannot start in this state")
  }
  self.started = true
  self.expected = content_length
  self.suppress = status == 204 ||
    status == 304 ||
    self.head.param("REQUEST_METHOD") == Some(b"HEAD")
  self.record(6, bytes)
}

///|
/// Awaiting write applies socket backpressure; chunks are never accumulated as a full response.
pub async fn ResponseWriter::write(
  self : ResponseWriter,
  bytes : Bytes,
) -> Unit {
  if !self.started {
    self.start()
  }
  self.mutex.acquire()
  defer self.mutex.release()
  if self.finished || !self.session.is_active(self.head) {
    fail("response is no longer active")
  }
  if bytes.length() > self.limit - self.count {
    fail("stream response limit")
  }
  if self.expected is Some(n) && bytes.length() > n - self.count {
    fail("response exceeds declared length")
  }
  self.count += bytes.length()
  if !self.suppress {
    self.record(6, bytes)
  }
}

///|
pub async fn ResponseWriter::write_stderr(
  self : ResponseWriter,
  bytes : Bytes,
) -> Unit {
  self.mutex.acquire()
  defer self.mutex.release()
  if self.finished || !self.session.can_output(self.head) {
    fail("stderr is no longer writable")
  }
  if bytes.length() > self.limit - self.errors {
    fail("stream stderr limit")
  }
  self.errors += bytes.length()
  self.record(7, bytes)
}

///|
async fn ResponseWriter::finish(
  self : ResponseWriter,
  app_status~ : UInt32 = 0U,
) -> Bool {
  if !self.started {
    self.start()
  }
  self.mutex.acquire()
  defer self.mutex.release()
  if self.finished || !self.session.is_active(self.head) {
    return false
  }
  if app_status == 0U &&
    !self.suppress &&
    self.expected is Some(n) &&
    self.count != n {
    fail("response shorter than declared length")
  }
  self.finished = true
  let mut close = false
  for event in self.session.complete(self.head, app_status~) {
    match event {
      Send(records) =>
        for record in records {
          (self.output)(@fcgi.encode_record(record))
        }
      Close => close = true
      _ => ()
    }
  }
  close
}

///|
/// Run the streaming protocol over caller-owned I/O. The transport adapter owns closure.
pub async fn serve_stream_io(
  reader : &@io.Reader,
  writer : &@io.Writer,
  handler : StreamHandler,
  config? : Config,
  roles~ : Array[@fcgi.Role] = [@fcgi.Responder],
) -> Unit {
  let config = match config {
    Some(v) => v
    None => Config::new()
  }
  let session = @fcgi.StreamSession::new(limits=config.limits, roles~)
  defer session.close()
  let decoder = @fcgi.Decoder::new()
  let mutex = @async.Mutex()
  let output : async (Bytes) -> Unit = bytes => {
    @async.with_timeout(config.write_timeout_ms, () => writer.write(bytes))
  }
  @async.with_task_group <| group => {
    let timer = @async.Timer(config.cycle_timeout_ms)
    group.spawn_bg(no_wait=true) <| () => {
      timer.wait()
      fail("stream cycle timeout")
    }
    let mut current : (StreamRequest, ResponseWriter, @async.Task[Unit])? = None
    defer (if current is Some((request, _, _)) {
      request.body.queue.close(clear=true)
      request.data.queue.close(clear=true)
    })
    while true {
      guard reader.read_some(max_len=8192) is Some(bytes) else {
        decoder.finish()
        session.finish()
        group.return_immediately(())
        return
      }
      for record in decoder.feed(bytes) {
        // Serialize protocol state transitions with response completion and writes.
        let events = {
          mutex.acquire()
          defer mutex.release()
          let events = session.accept(record)
          for event in events {
            if event is Send(records) {
              for record in records {
                output(@fcgi.encode_record(record))
              }
            }
          }
          events
        }
        for event in events {
          match event {
            Start(head) => {
              let request = {
                head,
                body: BodyStream::new(),
                data: BodyStream::new(),
              }
              if head.role == @fcgi.Authorizer {
                request.body.ended = true
              }
              if head.role != @fcgi.Filter {
                request.data.ended = true
              }
              let response = {
                head,
                session,
                output,
                mutex,
                limit: config.limits.response_bytes,
                started: false,
                finished: false,
                suppress: false,
                expected: None,
                count: 0,
                errors: 0,
              }
              let task = group.spawn(no_wait=true) <| () => {
                let mut failed = false
                @async.with_timeout(config.handler_timeout_ms, () => {
                  handler(request, response)
                }) catch {
                  error => {
                    if @async.is_cancellation_error(error) {
                      raise error
                    }
                    failed = true
                    if !response.started && session.can_output(head) {
                      response.start(status=500)
                    }
                  }
                }
                let close = response.finish(
                  app_status=if failed { 1U } else { 0U },
                )
                // Once the application returns, drain remaining input without buffering.
                request.body.queue.close(clear=true)
                request.data.queue.close(clear=true)
                timer.refresh()
                if close {
                  group.return_immediately(())
                }
              }
              current = Some((request, response, task))
            }
            Input(token, kind, chunk) =>
              if current is Some((request, response, _)) &&
                request.head.token == token &&
                !response.finished {
                try {
                  if kind == 5 {
                    request.body.queue.put(Some(chunk))
                  } else {
                    request.data.queue.put(Some(chunk))
                  }
                } catch {
                  error => if !response.finished { raise error }
                }
              }
            InputEnd(token, kind) =>
              if current is Some((request, response, _)) &&
                request.head.token == token &&
                !response.finished {
                try {
                  if kind == 5 {
                    request.body.queue.put(None)
                  } else {
                    request.data.queue.put(None)
                  }
                } catch {
                  error => if !response.finished { raise error }
                }
              }
            Aborted(token) => {
              if current is Some((request, _, task)) &&
                request.head.token == token {
                request.body.queue.close(clear=true)
                request.data.queue.close(clear=true)
                task.cancel()
                current = None
              }
              timer.refresh()
            }
            Close => {
              group.return_immediately(())
              return
            }
            Send(_) => ()
          }
        }
      }
    }
  }
}

///|
pub async fn serve_stream_connection(
  conn : @socket.Tcp,
  handler : StreamHandler,
  config? : Config,
  roles~ : Array[@fcgi.Role] = [@fcgi.Responder],
) -> Unit {
  defer conn.close()
  serve_stream_io(conn, conn, handler, config?, roles~)
}

///|
pub async fn serve_stream(
  address : String,
  handler : StreamHandler,
  config? : Config,
  roles~ : Array[@fcgi.Role] = [@fcgi.Responder],
) -> Unit {
  let config = match config {
    Some(v) => v
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
        serve_stream_connection(conn, handler, config~, roles~)
      }
    }
  }
}
