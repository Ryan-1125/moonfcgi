///|
fn start_stream(
  role~ : Int32 = 1,
  roles~ : Array[@moonfcgi.Role] = [@moonfcgi.Responder],
) -> (@moonfcgi.StreamSession, @moonfcgi.RequestHead) raise {
  let session = @moonfcgi.StreamSession::new(roles~)
  ignore(
    session.accept({
      kind: 1,
      id: 1,
      content: Bytes::makei(8, i => {
        if i == 1 {
          role.to_byte()
        } else if i == 2 {
          b'\x01'
        } else {
          b'\x00'
        }
      }),
    }),
  )
  let events = session.accept({ kind: 4, id: 1, content: b"", })
  guard events[0] is Start(head) else { fail("expected streaming start") }
  (session, head)
}

///|
test "stream handler starts at PARAMS EOF and STDIN is not buffered" {
  let (session, head) = start_stream()
  assert_true(session.can_output(head))
  for _ in 0..<100 {
    let events = session.accept({ kind: 5, id: 1, content: b"\x00\xff", })
    assert_true(events[0] is Input(_, 5, b"\x00\xff"))
  }
  assert_true(
    session.accept({ kind: 5, id: 1, content: b"", })[0] is InputEnd(_, 5),
  )
  let done = session.complete(head)
  guard done[0] is Send(records) else { fail("expected completion") }
  assert_eq(
    @moonfcgi.encode_record(records[0]),
    b"\x01\x06\x00\x01\x00\x00\x00\x00",
  )
  assert_eq(
    @moonfcgi.encode_record(records[1]),
    b"\x01\x07\x00\x01\x00\x00\x00\x00",
  )
  assert_eq(
    @moonfcgi.encode_record(records[2]),
    b"\x01\x03\x00\x01\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
  )
  assert_eq(session.complete(head).length(), 0)
  session.finish()
}

///|
test "early streaming response drains before request ID reuse" {
  let (session, head) = start_stream()
  ignore(session.complete(head))
  assert_true(!session.is_active(head))
  ignore(session.accept({ kind: 5, id: 1, content: b"discard", }))
  ignore(session.accept({ kind: 5, id: 1, content: b"", }))
  session.finish()
}

///|
test "stream stale completion is session and generation bound" {
  let (session, head) = start_stream()
  let (other, _) = start_stream()
  assert_eq(other.complete(head).length(), 0)
  let events = session.accept({ kind: 2, id: 1, content: b"", })
  assert_true(events[0] is Aborted(_))
  assert_eq(session.complete(head).length(), 0)
}

///|
test "Filter waits for stdin then streams DATA" {
  let (session, head) = start_stream(role=3, roles=[@moonfcgi.Filter])
  assert_true(!session.can_output(head))
  ignore(session.accept({ kind: 5, id: 1, content: b"", }))
  assert_true(session.can_output(head))
  assert_true(
    session.accept({ kind: 8, id: 1, content: b"file", })[0]
    is Input(_, 8, b"file"),
  )
  ignore(session.accept({ kind: 8, id: 1, content: b"", }))
  ignore(session.complete(head))
  session.finish()
}

///|
test "Authorizer is ready without stdin terminator" {
  let (session, head) = start_stream(role=2, roles=[@moonfcgi.Authorizer])
  assert_true(head.role == @moonfcgi.Authorizer)
  ignore(session.complete(head))
  session.finish()
}

///|
test "stream declared lengths and input sequence are enforced" {
  let (session, _) = start_stream(role=3, roles=[@moonfcgi.Filter])
  let rejected = rejects(() => {
    ignore(session.accept({ kind: 8, id: 1, content: b"early", }))
  })
  assert_true(rejected)
  let (other, _) = start_stream()
  assert_true(
    rejects(() => ignore(other.accept({ kind: 4, id: 1, content: b"", }))),
  )
}

///|
test "unknown stream role is rejected and default only enables Responder" {
  let session = @moonfcgi.StreamSession::new()
  let events = session.accept({
    kind: 1,
    id: 1,
    content: b"\x00\x02\x00\x00\x00\x00\x00\x00",
  })
  guard events[0] is Send(records) else { fail("expected reject") }
  assert_eq(records[0].content, b"\x00\x00\x00\x00\x03\x00\x00\x00")
  assert_true(events[1] is Close)
}

///|
test "CGI streaming headers omit unknown length and preserve duplicate headers" {
  let response = @moonfcgi.Response::new(b"", status=201, headers=[
    ("Set-Cookie", "a=1"),
    ("Set-Cookie", "b=2"),
  ])
  assert_eq(
    response.cgi_headers(),
    b"Status: 201 Created\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nContent-Type: application/octet-stream\r\n\r\n",
  )
  assert_true(rejects(() => ignore(response.cgi_headers(content_length=-1))))
}
