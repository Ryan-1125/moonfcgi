///|
fn headers_pending(
  pairs : Array[(Bytes, Bytes)],
  limit~ : Int32 = 8,
) -> @moonfcgi.Session raise {
  let s = @moonfcgi.Session::new(limits=@moonfcgi.Limits::new(body_bytes=limit))
  ignore(
    s.accept({ kind: 1, id: 1, content: b"\x00\x01\x01\x00\x00\x00\x00\x00", }),
  )
  ignore(s.accept({ kind: 4, id: 1, content: @moonfcgi.encode_params(pairs), }))
  s
}

///|
test "reject invalid declared lengths before receiving any STDIN" {
  let cases : Array[Array[(Bytes, Bytes)]] = [
    [(b"CONTENT_LENGTH", b"9")],
    [(b"CONTENT_LENGTH", b"-1")],
    [(b"CONTENT_LENGTH", b"+1")],
    [(b"CONTENT_LENGTH", b"1x")],
    [(b"CONTENT_LENGTH", b"\xff")],
    [(b"CONTENT_LENGTH", b"999999999999999999999999")],
    [(b"CONTENT_LENGTH", b"1"), (b"CONTENT_LENGTH", b"2")],
  ]
  for pairs in cases {
    let s = headers_pending(pairs)
    assert_true(
      rejects(() => ignore(s.accept({ kind: 4, id: 1, content: b"", }))),
    )
    assert_true(
      rejects(() => ignore(s.accept({ kind: 9, id: 0, content: b"", }))),
    )
  }
}

///|
test "declared body overrun is rejected on the offending record" {
  let s = headers_pending([(b"CONTENT_LENGTH", b"2")])
  ignore(s.accept({ kind: 4, id: 1, content: b"", }))
  ignore(s.accept({ kind: 5, id: 1, content: b"a", }))
  assert_true(
    rejects(() => ignore(s.accept({ kind: 5, id: 1, content: b"bc", }))),
  )
}

///|
test "equal duplicate lengths, zero body and integer boundary" {
  let s = headers_pending([
    (b"CONTENT_LENGTH", b"03"),
    (b"CONTENT_LENGTH", b"3"),
  ])
  ignore(s.accept({ kind: 4, id: 1, content: b"", }))
  ignore(s.accept({ kind: 5, id: 1, content: b"\x00\xffx", }))
  guard s.accept({ kind: 5, id: 1, content: b"", })
    is [@moonfcgi.Ready(request)] else {
    fail("request")
  }
  assert_eq(request.body, b"\x00\xffx")
  let empty = headers_pending([(b"CONTENT_LENGTH", b"0")], limit=0)
  ignore(empty.accept({ kind: 4, id: 1, content: b"", }))
  guard empty.accept({ kind: 5, id: 1, content: b"", })
    is [@moonfcgi.Ready(request)] else {
    fail("zero request")
  }
  assert_eq(request.body, b"")
  let s = headers_pending(
    [(b"CONTENT_LENGTH", b"2147483648")],
    limit=2147483647,
  )
  assert_true(
    rejects(() => ignore(s.accept({ kind: 4, id: 1, content: b"", }))),
  )
}
