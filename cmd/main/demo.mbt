///|
async fn main {
  let args = @env.args()
  let address = if args.length() > 1 { args[1] } else { "127.0.0.1:9000" }
  let config = if args.length() > 2 && args[2] == "test" {
    @server.Config::new(
      limits=@fcgi.Limits::new(body_bytes=1048576, connections=8),
      cycle_timeout_ms=1500,
      handler_timeout_ms=500,
      write_timeout_ms=500,
    )
  } else {
    @server.Config::new()
  }
  println("MoonFCGI listening on \{address}")
  @server.serve(
    address,
    request => {
      let path = request
        .text_param("DOCUMENT_URI")
        .unwrap_or(request.text_param("PATH_INFO").unwrap_or("/"))
      if path == "/api/echo" {
        @fcgi.Response::new(request.body)
      } else if path == "/api/hello" {
        let query = request.text_param("QUERY_STRING").unwrap_or("")
        let json : Json = { "message": "hello", "query": query }
        @fcgi.Response::new(@utf8.encode(json.stringify()), headers=[
          ("Content-Type", "application/json"),
        ])
      } else if path == "/api/error" {
        fail("deliberate handler failure")
      } else if path == "/api/slow" {
        @async.sleep(2000)
        @fcgi.Response::new(b"slow")
      } else if path == "/api/cookies" {
        @fcgi.Response::new(b"cookies", headers=[
          ("Set-Cookie", "a=1"),
          ("Set-Cookie", "b=2"),
        ])
      } else if path == "/api/large" {
        @fcgi.Response::new(Bytes::make(200000, b'x'))
      } else if path == "/api/huge" {
        @fcgi.Response::new(Bytes::make(8388608, b'x'))
      } else if path == "/api/oversized" {
        @fcgi.Response::new(Bytes::make(8388609, b'x'))
      } else if path == "/api/stderr" {
        @fcgi.Response::new(b"ok", stderr=b"\x00\xffdiagnostic")
      } else if path == "/api/no-content" {
        @fcgi.Response::new(b"must not reach client", status=204)
      } else if path == "/api/not-modified" {
        @fcgi.Response::new(b"must not reach client", status=304)
      } else {
        @fcgi.Response::new(b"Not Found", status=404)
      }
    },
    config~,
  )
}
