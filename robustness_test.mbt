///|
// A bounded 16-bit LCG: multiplication stays within signed Int32.
struct ProtocolRng {
  mut state : Int32
}

///|
fn ProtocolRng::next(self : ProtocolRng, bound : Int32) -> Int32 {
  self.state = (self.state * 25173 + 13849) % 65536
  self.state % bound
}

///|
fn protocol_rejected(f : () -> Unit raise) -> Bool raise {
  try {
    f()
    false
  } catch {
    @moonfcgi.ProtocolError::Invalid(_) => true
    @moonfcgi.ProtocolError::Limit(_) => true
    @moonfcgi.ProtocolError::Truncated(_) => true
    error => raise error
  }
}

///|
test "seeded streaming state transitions reject wrong order and isolate reuse" {
  for seed in [29, 128, 2026] {
    let rng = { state: seed, }
    for case in 0..<100 {
      if case % 3 == 0 {
        let (session, _) = start_stream(role=3, roles=[@moonfcgi.Filter])
        let data = Bytes::makei(1 + rng.next(128), _ => rng.next(256).to_byte())
        assert_true(
          protocol_rejected(() => {
            ignore(session.accept({ kind: 8, id: 1, content: data, }))
          }),
        )
      } else {
        let (session, head) = start_stream()
        let bytes = Bytes::makei(rng.next(256), _ => rng.next(256).to_byte())
        if !bytes.is_empty() {
          guard session.accept({ kind: 5, id: 1, content: bytes, })
            is [@moonfcgi.Input(_, 5, received)] else {
            fail("expected input")
          }
          assert_eq(received, bytes)
        }
        ignore(session.accept({ kind: 2, id: 1, content: b"", }))
        assert_true(session.is_idle())
        ignore(
          session.accept({
            kind: 1,
            id: 1,
            content: b"\x00\x01\x01\x00\x00\x00\x00\x00",
          }),
        )
        guard session.accept({ kind: 4, id: 1, content: b"", })
          is [@moonfcgi.Start(next)] else {
          fail("expected reused request")
        }
        assert_eq(session.complete(head).length(), 0)
        assert_true(session.is_active(next))
        ignore(session.accept({ kind: 5, id: 1, content: b"", }))
        ignore(session.complete(next))
        assert_true(session.is_idle())
        session.finish()
      }
    }
  }
}

///|
// Independent wire construction, including nonzero padding and reserved bytes.
fn manual_record(kind : Int32, id : Int32, body : Bytes, pad : Int32) -> Bytes {
  Bytes::makei(8, i => {
    [
      1,
      kind,
      id / 256,
      id % 256,
      body.length() / 256,
      body.length() % 256,
      pad,
      173,
    ][i].to_byte()
  }) +
  body +
  Bytes::make(pad, b'\xff')
}

///|
fn manual_length(n : Int32) -> Bytes {
  if n < 128 {
    Bytes::make(1, n.to_byte())
  } else {
    Bytes::makei(4, i => [128, 0, n / 256, n % 256][i].to_byte())
  }
}

///|
test "seeded record corpus preserves bytes across random transport splits" {
  for seed in [1, 7, 2026, 65535] {
    let rng = { state: seed, }
    let decoder = @moonfcgi.Decoder::new()
    let expected : Array[@moonfcgi.Record] = []
    let actual : Array[@moonfcgi.Record] = []
    let mut wire = b""
    for case in 0..<100 {
      let n = [0, 1, 7, 127, 128, 255, 256, 1024][case % 8]
      let body = Bytes::makei(n, _ => rng.next(256).to_byte())
      let kind = rng.next(256)
      let id = rng.next(65536)
      expected.push({ kind, id, content: body, })
      wire = wire + manual_record(kind, id, body, rng.next(256))
    }
    let mut offset = 0
    while offset < wire.length() {
      let end = (offset + 1 + rng.next(4096)).min(wire.length())
      for record in decoder.feed(wire[offset:end].to_owned()) {
        actual.push(record)
      }
      offset = end
      assert_eq(decoder.feed(b"").length(), 0)
    }
    decoder.finish()
    assert_eq(actual, expected)
  }
}

///|
test "seeded maximum record and every truncated EOF remain bounded" {
  let rng = { state: 391, }
  let wire = manual_record(
    6,
    65535,
    Bytes::makei(65535, _ => rng.next(256).to_byte()),
    255,
  )
  let decoder = @moonfcgi.Decoder::new()
  assert_eq(decoder.feed(wire[:65536].to_owned()).length(), 0)
  let records = decoder.feed(wire[65536:].to_owned())
  assert_eq(records.length(), 1)
  assert_eq(records[0].content.length(), 65535)
  decoder.finish()
  let small = manual_record(5, 1, b"\x00\xffbinary", 19)
  for cut in 1..<small.length() {
    let d = @moonfcgi.Decoder::new()
    ignore(d.feed(small[:cut].to_owned()))
    assert_true(protocol_rejected(() => d.finish()))
    assert_true(protocol_rejected(() => ignore(d.feed(b""))))
  }
  for version in 0..<256 {
    if version == 1 {
      continue
    }
    let d = @moonfcgi.Decoder::new()
    let invalid = Bytes::make(1, version.to_byte()) + small[1:].to_owned()
    assert_true(protocol_rejected(() => ignore(d.feed(invalid))))
    assert_true(protocol_rejected(() => d.finish()))
  }
  let d = @moonfcgi.Decoder::new()
  assert_true(
    protocol_rejected(() => ignore(d.feed(Bytes::make(65537, b'\x00')))),
  )
}

///|
test "seeded PARAMS independent vectors cover empty duplicate and four byte lengths" {
  for seed in [17, 128, 2026, 65535] {
    let rng = { state: seed, }
    for _ in 0..<64 {
      let pairs : Array[(Bytes, Bytes)] = []
      let mut wire = b""
      for pair in 0..<6 {
        let n = [0, 1, 127, 128, 255, 256][pair]
        let name = Bytes::makei(n, _ => rng.next(256).to_byte())
        let value = Bytes::makei(rng.next(300), _ => rng.next(256).to_byte())
        pairs.push((name, value))
        wire = wire +
          manual_length(n) +
          manual_length(value.length()) +
          name +
          value
      }
      // Duplicate names and zero-length values remain distinct pairs.
      pairs.push((b"k", b""))
      pairs.push((b"k", b"\x00\xff"))
      wire = wire + b"\x01\x00k\x01\x02k\x00\xff"
      let p = @moonfcgi.ParamsDecoder::new(limit=wire.length(), max_pairs=8)
      let mut offset = 0
      while offset < wire.length() {
        let end = (offset + 1 + rng.next(37)).min(wire.length())
        p.feed(wire[offset:end].to_owned())
        p.feed(b"")
        offset = end
      }
      assert_eq(p.finish(), pairs)
      assert_true(protocol_rejected(() => p.feed(b"")))
    }
  }
}

///|
test "seeded malicious PARAMS prefixes and exact resource boundaries" {
  let rng = { state: 412, }
  for _ in 0..<256 {
    let prefix = b"\xff" + Bytes::makei(3, _ => rng.next(256).to_byte())
    let p = @moonfcgi.ParamsDecoder::new(limit=1024)
    assert_true(
      protocol_rejected(() => {
        for byte in prefix {
          p.feed(Bytes::make(1, byte))
        }
      }),
    )
    assert_true(protocol_rejected(() => ignore(p.finish())))
  }
  let wire = b"\x80\x00\x00\x80\x03" + Bytes::make(128, b'x') + b"abc"
  for cut in 1..<wire.length() {
    let p = @moonfcgi.ParamsDecoder::new()
    p.feed(wire[:cut].to_owned())
    assert_true(protocol_rejected(() => ignore(p.finish())))
  }
  let p = @moonfcgi.ParamsDecoder::new(limit=3)
  p.feed(b"\x01\x00k")
  assert_eq(p.finish(), [(b"k", b"")])
  let p = @moonfcgi.ParamsDecoder::new(limit=2)
  assert_true(protocol_rejected(() => p.feed(b"\x01\x00k")))
  let p = @moonfcgi.ParamsDecoder::new(max_pairs=1)
  assert_true(protocol_rejected(() => p.feed(b"\x00\x00\x00\x00")))
}

///|
test "seeded reuse abort and stale completion follow a request model" {
  for seed in [3, 2026, 65535] {
    let rng = { state: seed, }
    let session = @moonfcgi.Session::new()
    let other = @moonfcgi.Session::new()
    for _ in 0..<100 {
      let id = 1 + rng.next(7)
      let body = Bytes::makei(rng.next(300), _ => rng.next(256).to_byte())
      let request = ready(session, id, body~)
      let foreign = ready(other, id)
      assert_eq(request.body, body)
      assert_eq(
        session.complete(foreign, @moonfcgi.Response::new(b"wrong")).length(),
        0,
      )
      if rng.next(3) == 0 {
        ignore(session.accept({ kind: 2, id, content: b"", }))
      } else {
        assert_true(
          !session.complete(request, @moonfcgi.Response::new(body)).is_empty(),
        )
      }
      assert_eq(
        session.complete(request, @moonfcgi.Response::new(b"stale")).length(),
        0,
      )
      ignore(other.complete(foreign, @moonfcgi.Response::new(b"ok")))
    }
    session.finish()
    other.finish()
  }
}
