///|
test "configuration validates all stage limits and queue capacity" {
  let config = @server.Config::new(cycle_timeout_ms=600, input_queue_records=1)
  assert_eq(config.idle_timeout_ms, 600)
  assert_eq(config.input_timeout_ms, 600)
  assert_eq(config.input_queue_records, 1)
  for capacity in [0, -1, 1025] {
    let rejected = try {
      ignore(@server.Config::new(input_queue_records=capacity))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  let invalid = [
    () => ignore(@server.Config::new(idle_timeout_ms=0)),
    () => ignore(@server.Config::new(input_timeout_ms=0)),
    () => ignore(@server.Config::new(shutdown_timeout_ms=0)),
  ]
  for f in invalid {
    assert_true(
      try {
        f()
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "shutdown is explicit one-shot and statistics snapshots are immutable values" {
  let control = @server.Control::new()
  let stats = @server.Stats::new()
  let snapshot = stats.snapshot()
  let config = @server.Config::new(control~, stats~)
  assert_true(!control.is_stopping())
  control.shutdown()
  control.shutdown()
  assert_true(config.control.is_stopping())
  assert_true(!@server.Control::new().is_stopping())
  assert_eq(snapshot.requests, 0L)
  assert_eq(snapshot.active_connections, 0L)
  assert_eq(config.stats.snapshot().bytes_read, 0L)
}
