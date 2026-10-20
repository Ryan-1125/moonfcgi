///|
test "manual vector with padding and arbitrary split" {
  let wire = b"\x01\x06\x01\x2c\x00\x03\x05\x00abc\x00\x00\x00\x00\x00"
  let expected : @moonfcgi.Record = { kind: 6, id: 300, content: b"abc", }
  assert_eq(@moonfcgi.encode_record(expected), wire)
  for cut in 0..<=wire.length() {
    let d = @moonfcgi.Decoder::new()
    let records = d.feed(wire[:cut].to_owned())
    for r in d.feed(wire[cut:].to_owned()) {
      records.push(r)
    }
    d.finish()
    assert_eq(records, [expected])
  }
}

///|
test "EOF, bad version, and large output splitting" {
  let d = @moonfcgi.Decoder::new()
  ignore(d.feed(b"\x01\x01"))
  assert_true(
    try {
      d.finish()
      false
    } catch {
      _ => true
    },
  )
  let d = @moonfcgi.Decoder::new()
  assert_true(
    try {
      ignore(d.feed(b"\x02\x01\x00\x01\x00\x00\x00\x00"))
      false
    } catch {
      _ => true
    },
  )
  let rs = @moonfcgi.stream_records(6, 1, Bytes::make(66000, b'x'))
  assert_eq(rs.length(), 3)
  assert_eq(rs[0].content.length(), 65535)
  assert_eq(rs[1].content.length(), 465)
  assert_eq(rs[2].content, b"")
  assert_eq(
    @moonfcgi.end_record(1).content,
    b"\x00\x00\x00\x00\x00\x00\x00\x00",
  )
}
