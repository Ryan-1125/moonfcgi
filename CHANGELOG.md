# Changelog

## Unreleased

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
