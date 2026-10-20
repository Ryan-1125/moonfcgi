///|
/// A fully buffered, bounded request; token prevents stale completion after reuse.
pub struct Request {
  id : Int
  token : Int64
  params : Array[(Bytes, Bytes)]
  body : Bytes
}

///|
/// Return the last parameter value (duplicates remain available via params).
pub fn Request::param(self : Request, name : String) -> Bytes? {
  let key = @utf8.encode(name)
  for i = self.params.length() - 1; i >= 0; i = i - 1 {
    if self.params[i].0 == key {
      return Some(self.params[i].1)
    }
  }
  None
}

///|
/// Strict UTF-8 conversion only on explicit application request.
pub fn Request::text_param(self : Request, name : String) -> String? raise {
  self.param(name).map(value => @utf8.decode(value))
}

///|
/// Response headers are ordered; duplicate Set-Cookie headers are preserved.
pub struct Response {
  status : Int
  headers : Array[(String, String)]
  body : Bytes
  stderr : Bytes
}

///|
/// Construct a response. Validation also runs at serialization to guard mutation.
pub fn Response::new(
  body : Bytes,
  status? : Int = 200,
  headers? : Array[(String, String)] = [],
  stderr? : Bytes = b"",
) -> Response raise ProtocolError {
  let response = { status, headers: headers.copy(), body, stderr, }
  validate_response(response)
  response
}

///|
fn validate_response(response : Response) -> Unit raise ProtocolError {
  if response.status < 200 || response.status > 599 {
    raise Invalid("response status must be 200..599")
  }
  if response.headers.length() > 128 {
    raise Limit("response header count")
  }
  let mut header_bytes = 0
  for header in response.headers {
    let (name, value) = header
    if name.length() > 1024 || value.length() > 16384 {
      raise Limit("response header size")
    }
    header_bytes += @utf8.encode(name).length() +
      @utf8.encode(value).length() +
      4
    if header_bytes > 32768 {
      raise Limit("response headers exceed 32 KiB")
    }
    if name.is_empty() {
      raise Invalid("empty response header")
    }
    for c in name {
      if !((c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') ||
        "!#$%&'*+-.^_`|~".contains(c.to_string())) {
        raise Invalid("invalid response header name")
      }
    }
    if name.to_lower() == "status" ||
      name.to_lower() == "content-length" ||
      name.to_lower() == "transfer-encoding" ||
      name.to_lower() == "connection" {
      raise Invalid("reserved response header")
    }
    for c in value {
      if c == '\r' ||
        c == '\n' ||
        c == '\u0000' ||
        c == '\u007f' ||
        (c < ' ' && c != '\t') {
        raise Invalid("invalid response header value")
      }
    }
  }
}

///|
/// Encode CGI headers, followed by the binary body (not an HTTP status line).
pub fn Response::cgi_bytes(
  self : Response,
  head? : Bool = false,
) -> Bytes raise ProtocolError {
  validate_response(self)
  let out = @buf.Buffer()
  out.write_string_utf8("Status: \{self.status}\r\n")
  let mut content_type = false
  for header in self.headers {
    if header.0.to_lower() == "content-type" {
      content_type = true
    }
    out.write_string_utf8("\{header.0}: \{header.1}\r\n")
  }
  if !content_type {
    out.write_string_utf8("Content-Type: application/octet-stream\r\n")
  }
  let no_body = self.status == 204 || self.status == 304
  if !no_body {
    out.write_string_utf8("Content-Length: \{self.body.length()}\r\n")
  }
  out.write_bytes(b"\r\n")
  if !head && !no_body {
    out.write_bytes(self.body)
  }
  out.to_bytes()
}
