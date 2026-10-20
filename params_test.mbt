///|
test "manual parameter vectors and every split" {
  let name = Bytes::make(128, b'x')
  let wire = b"\x80\x00\x00\x80\x01" + name + b"y"
  assert_eq(@moonfcgi.encode_params([(name, b"y")]), wire)
  for cut in 0..<=wire.length() {
    let p = @moonfcgi.ParamsDecoder::new()
    p.feed(wire[:cut].to_owned())
    p.feed(wire[cut:].to_owned())
    assert_eq(p.finish(), [(name, b"y")])
  }
  assert_eq(@moonfcgi.encode_params([(b"a", b"")]), b"\x01\x00a")
}

///|
test "params bounded truncation and byte preservation" {
  let p = @moonfcgi.ParamsDecoder::new()
  let rejected = try {
    p.feed(b"\xff\xff\xff\xff\x00")
    ignore(p.finish())
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  let p = @moonfcgi.ParamsDecoder::new(limit=2)
  let rejected = try {
    p.feed(b"123")
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  let pairs = [(b"\xe4\xb8\xad", b"\x00\xff"), (b"a", b"1"), (b"a", b"2")]
  let p = @moonfcgi.ParamsDecoder::new()
  p.feed(@moonfcgi.encode_params(pairs))
  assert_eq(p.finish(), pairs)
}
