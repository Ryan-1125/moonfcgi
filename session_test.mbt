///|
fn ready(
  s : @moonfcgi.Session,
  id : Int,
  body? : Bytes = b"",
) -> @moonfcgi.Request raise {
  ignore(
    s.accept({ kind: 1, id, content: b"\x00\x01\x01\x00\x00\x00\x00\x00", }),
  )
  ignore(s.accept({ kind: 4, id, content: b"", }))
  if !body.is_empty() {
    ignore(s.accept({ kind: 5, id, content: body, }))
  }
  let events = s.accept({ kind: 5, id, content: b"", })
  guard events is [@moonfcgi.Ready(request)] else { fail("expected request") }
  request
}

///|
test "sequential reuse is isolated and stale completion cannot affect next request" {
  let s = @moonfcgi.Session::new()
  let first = ready(s, 7, body=b"\x00abc")
  assert_eq(first.body, b"\x00abc")
  assert_true(!s.complete(first, @moonfcgi.Response::new(b"ok")).is_empty())
  let second = ready(s, 7)
  assert_eq(second.body, b"")
  assert_true(first.token != second.token)
  assert_true(s.complete(first, @moonfcgi.Response::new(b"stale")).is_empty())
  assert_true(!s.complete(second, @moonfcgi.Response::new(b"next")).is_empty())
  s.finish()
}

///|
test "completion from another session cannot finish a matching local ID and token" {
  let a = @moonfcgi.Session::new()
  let b = @moonfcgi.Session::new()
  let ra = ready(a, 1, body=b"a")
  let rb = ready(b, 1, body=b"b")
  assert_eq(ra.token, rb.token)
  assert_true(
    b.complete(ra, @moonfcgi.Response::new(b"wrong session")).is_empty(),
  )
  assert_true(!a.complete(ra, @moonfcgi.Response::new(b"a")).is_empty())
  assert_true(!b.complete(rb, @moonfcgi.Response::new(b"b")).is_empty())
}

///|
test "management, multiplex rejection, abort and unknown role" {
  let s = @moonfcgi.Session::new()
  let query = @moonfcgi.encode_params([
    (b"FCGI_MPXS_CONNS", b""),
    (b"OTHER", b""),
  ])
  guard s.accept({ kind: 9, id: 0, content: query, })
    is [@moonfcgi.Send([record])] else {
    fail("query")
  }
  assert_eq(record.content, b"\x0f\x01FCGI_MPXS_CONNS0")
  let request = ready(s, 1)
  guard s.accept({
      kind: 1,
      id: 2,
      content: b"\x00\x01\x01\x00\x00\x00\x00\x00",
    })
    is [@moonfcgi.Send([end])] else {
    fail("reject multiplex")
  }
  assert_eq(end.content[4], b'\x01')
  guard s.accept({ kind: 2, id: 1, content: b"", })
    is [@moonfcgi.Aborted(token), @moonfcgi.Send([_])] else {
    fail("abort")
  }
  assert_eq(token, request.token)
  assert_true(s.complete(request, @moonfcgi.Response::new(b"late")).is_empty())
  guard s.accept({
      kind: 1,
      id: 3,
      content: b"\x00\x02\x00\x00\x00\x00\x00\x00",
    })
    is [@moonfcgi.Send([end]), @moonfcgi.Close] else {
    fail("role")
  }
  assert_eq(end.content[4], b'\x03')
}

///|
test "CGI header validation and byte body" {
  let r = @moonfcgi.Response::new(b"\x00\xff", status=404, headers=[
    ("Set-Cookie", "a=1"),
    ("Set-Cookie", "b=2"),
  ])
  assert_eq(
    r.cgi_bytes(),
    b"Status: 404 Not Found\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nContent-Type: application/octet-stream\r\nContent-Length: 2\r\n\r\n\x00\xff",
  )
  assert_true(
    try {
      ignore(@moonfcgi.Response::new(b"", headers=[("X", "a\r\nb")]))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(@moonfcgi.Response::new(b"", headers=[("Content-Length", "0")]))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "invalid sequence and limits fail closed" {
  let s = @moonfcgi.Session::new(limits=@moonfcgi.Limits::new(body_bytes=1))
  ignore(
    s.accept({ kind: 1, id: 1, content: b"\x00\x01\x01\x00\x00\x00\x00\x00", }),
  )
  assert_true(
    try {
      ignore(s.accept({ kind: 5, id: 1, content: b"", }))
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      ignore(ready(s, 2))
      false
    } catch {
      _ => true
    },
  )
  let s = @moonfcgi.Session::new(limits=@moonfcgi.Limits::new(body_bytes=1))
  assert_true(
    try {
      ignore(ready(s, 1, body=b"ab"))
      false
    } catch {
      _ => true
    },
  )
}
