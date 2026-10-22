# Changelog

## 0.2.0

### Service lifecycle and diagnostics

- Add explicit one-shot Control.shutdown: stop accepting, drain active responses,
  and cancel remaining requests after a configurable shutdown deadline. Apply it
  to buffered/streaming TCP and POSIX listeners without changing signal handlers.
- Add typed ServerError/ServerEvent, request completion reports, isolated observer
  callbacks and shared statistics snapshots with connection/request/error/byte counts.
- Add configurable idle/input deadlines and 1..1024-record input queues while
  retaining handler/write deadlines and the independent total-cycle limit.
- Preserve cancellation errors inside write timeouts so slow readers are reported
  as Deadline(Write), rather than being misclassified as transport failures.

### Streaming and deployment expansion

- Add socket-independent StreamSession, RequestHead and explicit Responder,
  Authorizer and Filter roles; preserve the original buffered API.
- Start handlers at PARAMS EOF; provide bounded asynchronous STDIN/DATA queues,
  incremental STDOUT/STDERR writes, unknown-length CGI headers and socket backpressure.
- Add cancellation, early-response draining, generation-bound completion and
  role-specific stream ordering/length validation to the streaming path.
- Add POSIX filesystem Unix listeners and inherited TCP/Unix listening descriptors,
  with restrictive permissions, descriptor ownership checks and conditional path cleanup.
- Add a native streaming example, unbuffered Nginx configuration, independent wire
  tests and Linux CI coverage for Unix/fd0 plus external libfcgi comparison.
- Verify Windows streaming/TCP/Nginx locally and POSIX transports/three-role libfcgi
  interoperability in Linux CI 39717428442 (26 core tests, 13 existing and 16 new
  integration groups, plus the independent 0.2.0 archive consumer).
- Keep the original input deadline after an early response until input draining completes.

- Validate CONTENT_LENGTH as soon as PARAMS terminates. Reject invalid decimal
  values, conflicting duplicates and configured body-limit violations before
  collecting STDIN. Reject a body overrun on the offending record; retain
  end-of-stream validation for short bodies. Empty lengths remain unspecified,
  and numerically equal duplicate values are accepted. Public API signatures
  are unchanged.
- Add fixed boundary cases and real TCP coverage for early rejection and
  continued service on independent connections.
- Open VS Code with the user's normal profile and existing window by default.
  A separate profile is now explicitly requested with `-Isolated`; an existing
  editor language server is not silently claimed to use a new SDK.
