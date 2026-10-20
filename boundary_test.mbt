///|
fn rejects(f : () -> Unit raise) -> Bool {
  try {
    f()
    false
  } catch {
    _ => true
  }
}

///|
test "coalesced records, one-byte fragments, maximum padding and snapshot ownership" {
  let wire = b"\x01\x05\x00\x01\x00\x01\xff\x00z" +
    Bytes::make(255, b'\xff') +
    b"\x01\x05\x00\x01\x00\x00\x00\x00"
  for width in [1, 2, 3, 7, 8, 31, 264, 1000] {
    let d = @moonfcgi.Decoder::new()
    let records = []
    let mut pos = 0
    while pos < wire.length() {
      let end = Int::min(pos + width, wire.length())
      for r in d.feed(wire[pos:end].to_owned()) {
        records.push(r)
      }
      pos = end
    }
    d.finish()
    assert_eq(records, [
      { kind: 5, id: 1, content: b"z", },
      { kind: 5, id: 1, content: b"", },
    ])
  }
  for n in [1, 7, 8, 9, 263] {
    let d = @moonfcgi.Decoder::new()
    ignore(d.feed(wire[:n].to_owned()))
    assert_true(rejects(() => d.finish()))
  }
}

///|
test "PARAMS empty fields, both wide lengths, partial prefixes and pair count" {
  let name = Bytes::make(128, b'n')
  let value = Bytes::make(129, b'v')
  let wire = b"\x00\x00\x00\x01x\x01\x00y\x80\x00\x00\x80\x80\x00\x00\x81" +
    name +
    value
  for cut in 0..<=wire.length() {
    let p = @moonfcgi.ParamsDecoder::new()
    p.feed(wire[:cut].to_owned())
    p.feed(wire[cut:].to_owned())
    assert_eq(p.finish(), [(b"", b""), (b"", b"x"), (b"y", b""), (name, value)])
    assert_true(rejects(() => p.feed(b"")))
  }
  for bytes in [b"\x80", b"\x80\x00", b"\x80\x00\x00", b"\x01", b"\x01\x01n"] {
    let p = @moonfcgi.ParamsDecoder::new()
    p.feed(bytes)
    assert_true(rejects(() => ignore(p.finish())))
  }
  let p = @moonfcgi.ParamsDecoder::new(max_pairs=1)
  assert_true(rejects(() => p.feed(b"\x00\x00\x00\x00")))
  assert_true(rejects(() => ignore(p.finish())))
}

///|
test "CONTENT_LENGTH validation and EOF request truncation" {
  for value in [b"2", b"-1", b"1x", b"999999999999999999999999"] {
    let s = @moonfcgi.Session::new()
    ignore(
      s.accept({ kind: 1, id: 1, content: b"\x00\x01\x01\x00\x00\x00\x00\x00", }),
    )
    ignore(
      s.accept({
        kind: 4,
        id: 1,
        content: @moonfcgi.encode_params([(b"CONTENT_LENGTH", value)]),
      }),
    )
    ignore(s.accept({ kind: 4, id: 1, content: b"", }))
    ignore(s.accept({ kind: 5, id: 1, content: b"a", }))
    assert_true(
      rejects(() => ignore(s.accept({ kind: 5, id: 1, content: b"", }))),
    )
    assert_true(
      rejects(() => ignore(s.accept({ kind: 9, id: 0, content: b"", }))),
    )
  }
  let s = @moonfcgi.Session::new()
  ignore(
    s.accept({ kind: 1, id: 2, content: b"\x00\x01\x01\x00\x00\x00\x00\x00", }),
  )
  assert_true(rejects(() => s.finish()))
}

///|
test "HEAD, 204, 304, mutated headers and output bounds" {
  assert_eq(
    @moonfcgi.Response::new(b"body").cgi_bytes(head=true),
    b"Status: 200\r\nContent-Type: application/octet-stream\r\nContent-Length: 4\r\n\r\n",
  )
  for status in [204, 304] {
    let bytes = @moonfcgi.Response::new(b"ignored", status~).cgi_bytes()
    assert_true(!bytes.to_unchecked_string().contains("ignored"))
  }
  let r = @moonfcgi.Response::new(b"", headers=[("X", "safe")])
  r.headers[0] = ("X", "unsafe\n")
  assert_true(rejects(() => ignore(r.cgi_bytes())))
  assert_true(
    rejects(() => {
      ignore(@moonfcgi.Response::new(b"", headers=[("X", "x".repeat(16385))]))
    }),
  )
  let s = @moonfcgi.Session::new(limits=@moonfcgi.Limits::new(response_bytes=1))
  let r = ready(s, 1)
  assert_true(
    rejects(() => ignore(s.complete(r, @moonfcgi.Response::new(b"xx")))),
  )
  assert_true(
    !s.complete(r, @moonfcgi.Response::new(b"", status=500)).is_empty(),
  )
}

///|
test "duplicate begin, malformed abort and invalid management ID fail closed" {
  let records : Array[@moonfcgi.Record] = [
    { kind: 1, id: 1, content: b"\x00\x01\x01\x00\x00\x00\x00\x00", },
    { kind: 2, id: 1, content: b"x", },
    { kind: 4, id: 0, content: b"", },
    { kind: 6, id: 1, content: b"", },
  ]
  for record in records {
    let s = @moonfcgi.Session::new()
    ignore(ready(s, 1))
    assert_true(rejects(() => ignore(s.accept(record))))
  }
}
