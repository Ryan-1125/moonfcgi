///|
async fn main {
  let args = @env.args()
  let endpoint = if args.length() > 1 { args[1] } else { "127.0.0.1:9000" }
  let testing = args.length() > 2 && args[2] == "test"
  let config = @server.Config::new(
    limits=@fcgi.Limits::new(body_bytes=67108864, response_bytes=67108864),
    cycle_timeout_ms=if testing { 3000 } else { 10000 },
    handler_timeout_ms=if testing { 2000 } else { 8000 },
    write_timeout_ms=1000,
  )
  let handler : @server.StreamHandler = (request, response) => {
    if request.head.role == @fcgi.Authorizer {
      if request.head.param("HTTP_AUTHORIZATION") == Some(b"Bearer demo-token") {
        response.start(headers=[("Variable-REMOTE_USER", "demo")])
      } else {
        response.start(status=403)
        response.write(b"Forbidden")
      }
    } else if request.head.role == @fcgi.Filter {
      while request.body.read() is Some(_) {
        ()
      }
      response.start()
      while request.data.read() is Some(bytes) {
        response.write(bytes)
      }
    } else {
      let path = request.head.text_param("DOCUMENT_URI").unwrap_or("/echo")
      if path == "/download" {
        response.start(headers=[("Content-Type", "application/octet-stream")])
        for _ in 0..<64 {
          response.write(Bytes::make(65536, b'x'))
          @async.sleep(10)
        }
      } else if path == "/early" {
        response.start(status=202)
        response.write(b"accepted")
      } else if path == "/failure" {
        fail("handler failure before headers")
      } else if path == "/partial-failure" {
        response.write(b"partial")
        fail("handler failure after headers")
      } else if path == "/slow" {
        @async.sleep(9000)
      } else {
        response.start()
        while request.body.read() is Some(bytes) {
          response.write(bytes)
        }
      }
    }
  }
  let roles = [@fcgi.Responder, @fcgi.Authorizer, @fcgi.Filter]
  if endpoint.has_prefix("unix:") {
    @server.serve_unix(endpoint[5:].to_owned(), handler, config~, roles~)
  } else if endpoint == "fd:0" {
    @server.serve_inherited(handler, config~, roles~)
  } else {
    @server.serve_stream(endpoint, handler, config~, roles~)
  }
}
