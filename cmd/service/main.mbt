///|
// A minimal binary echo service for the packaged Linux deployment recipe.
async fn main {
  let handler : @server.StreamHandler = (request, response) => {
    response.start(headers=[("Content-Type", "application/octet-stream")])
    while request.body.read() is Some(bytes) {
      response.write(bytes)
    }
  }
  @server.serve_unix("/run/moonfcgi/app.sock", handler, mode=0o660)
}
