///|
async fn main {
  let args = @env.args()
  let address = if args.length() > 1 { args[1] } else { "127.0.0.1:9000" }
  let mode = if args.length() > 2 { args[2] } else { "stream" }
  let control = @server.Control::new()
  let stats = @server.Stats::new()
  let config = @server.Config::new(
    control~,
    stats~,
    limits=@fcgi.Limits::new(response_bytes=67108864),
    idle_timeout_ms=if mode == "cycle" { 5000 } else { 120 },
    input_timeout_ms=if mode == "cycle" { 5000 } else { 250 },
    handler_timeout_ms=if mode == "cycle" { 5000 } else { 500 },
    write_timeout_ms=150,
    cycle_timeout_ms=if mode == "cycle" { 150 } else { 2500 },
    shutdown_timeout_ms=350,
    input_queue_records=1,
    on_event=event => {
      println("EVENT \{@debug.to_string(event)}")
      if mode == "observer" {
        fail("deliberate observer failure")
      }
    },
  )
  if mode == "buffered" {
    @server.serve(
      address,
      request => {
        let path = request.text_param("DOCUMENT_URI").unwrap_or("/")
        if path == "/shutdown" {
          control.shutdown()
        }
        if path == "/slow" {
          @async.sleep(200)
        }
        if path == "/hang" {
          @async.sleep(5000)
        }
        if path == "/fail" {
          fail("application failure")
        }
        @fcgi.Response::new(if path == "/slow" { b"done" } else { b"ok" })
      },
      config~,
    )
  } else {
    let handler : @server.StreamHandler = (request, response) => {
      let path = request.head.text_param("DOCUMENT_URI").unwrap_or("/")
      if path == "/shutdown" {
        control.shutdown()
      }
      if path == "/slow" {
        @async.sleep(200)
      }
      if path == "/hang" {
        @async.sleep(5000)
      }
      if path == "/fail" {
        fail("application failure")
      }
      if path == "/backpressure" {
        response.start()
        for _ in 0..<64 {
          response.write(Bytes::make(1048576, b'x'))
        }
      } else if path == "/echo" {
        response.start()
        while request.body.read() is Some(bytes) {
          response.write(bytes)
        }
      } else {
        response.write(if path == "/slow" { b"done" } else { b"ok" })
      }
    }
    if address.has_prefix("unix:") {
      @server.serve_unix(address[5:].to_owned(), handler, config~)
    } else if address == "fd:0" {
      @server.serve_inherited(handler, config~)
    } else {
      @server.serve_stream(address, handler, config~)
    }
  }
  println("STATS \{@debug.to_string(stats.snapshot())}")
}
