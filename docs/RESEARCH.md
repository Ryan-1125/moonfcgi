# Sources and initial environment

2026-10-20: moon 0.1.20260920 (914d7da), moonc 0.10.14+7d59c7ec9.
Initial empty template check/build/test passed (zero template tests).
Local module initialized as Ryan-1125/moonfcgi; no remote or registry publication.

Protocol: FastCGI 1.0, Open Market 1996-04-29, sections 3–6:
https://fastcgi-archives.github.io/FastCGI_Specification.html
Reference code inspected: Go go1.23.2, src/net/http/fcgi/{child.go,fcgi.go,fcgi_test.go}.
Sources obtained from raw.githubusercontent.com/golang/go/go1.23.2. Their BSD-3-Clause license must accompany any adapted code/tests.

The Mooncakes registry index was freshly downloaded by `moon add` on this date.
Case-insensitive search across all index metadata for fastcgi, fcgi, fast-cgi, responder found no matches.
This metadata search complements the previous website search; it cannot exclude unpublished code or unrelated names.
Related async/socket supplies transport only, async/http speaks HTTP rather than FastCGI.
No direct complete duplicate identified; this is not an absolute novelty guarantee.

Runtime API inspected locally in moonbitlang/async 0.20.0 source and generated interfaces:
socket.TcpServer, socket.Tcp, io.Reader/Writer, with_task_group, Task.cancel/wait,
with_timeout and Timer. Native compilation and network tests succeeded.

## Registry search scope

Reproducible local metadata queries (fresh registry index, 2026-10-20):

```powershell
rg -i -l 'fastcgi|\bfcgi\b|fast-cgi|responder' "$env:USERPROFILE/.moon/registry/index/user"
rg --files "$env:USERPROFILE/.moon/registry/index/user" | Select-String 'fcgi|cgi|http|web|socket'
```

First query: no matching metadata files; the name search did not identify a FastCGI module. No complete direct duplicate was found within this index. Web UI search was not reliable in this environment, so this is an index metadata finding, not a claim that every package source was audited.

| Candidate inspected | Classification | Reason |
|---|---|---|
| moonbitlang/async 0.20.0 | Partial reuse, actually depended on | TCP, tasks, synchronization, timer, cancellation; does not supply FastCGI |
| moonbitlang/async/http | Related, not a duplicate | HTTP server/client protocol differs from FastCGI transport |
| f4ah6o/http11 0.1.2 | Related, not reused | Registry describes Sans I/O HTTP/1.1 parser and encoder |
| fantix/mmhttp 0.3.0 | Related, not reused | HTTP parser utility module, not advertised as FastCGI |
| fangyinc/socket 0.1.2-rc2 | Possible transport alternative, not reused | Socket binding, not FastCGI lifecycle |
| webidl/webgpu/webapi name matches | Unrelated | Browser interface/binding names, not Responder protocol |

Registry latest async was 0.22.5. This project pins 0.20.0 because that exact source/API was inspected and compiled with the installed toolchain; latest compatibility is not claimed.

## Actual async contracts

- `socket.Addr.parse(String)` may raise; `TcpServer(Addr)` and `accept() -> (Tcp, Addr)` are async; `Tcp.close()` is synchronous.
- `Tcp.read_some(max_len=8192) -> Bytes?` may return arbitrary transport fragments; None is EOF. `Tcp.write(bytes)` may block cooperatively.
- `with_task_group` scopes child tasks. `spawn` returns Task; `spawn_bg` creates a scoped child; failures propagate unless allow_failure is explicitly enabled. Connection failures are contained at the outer server group.
- `Task.cancel()` requests cooperative cancellation; `with_timeout` cancels the scoped work on expiration; cancellation errors must be rethrown. Handler exceptions produce 500, cancellation is not converted into a response.
- `Timer(ms).wait()` plus `refresh()` implements a total cycle deadline. Mutex serializes session transitions and network output; Semaphore limits accepted active connections.
- The upstream `TcpServer.run_forever` callback auto-closes its socket and explicitly forbids callback-side close. MoonFCGI therefore uses its own accept/group loop so `serve_connection` has sole close ownership.

Source locations within fetched async 0.20.0: `src/socket/tcp.mbt`, `src/io/reader.mbt`, `src/io/writer.mbt`, `src/task.mbt`, timer/timeout and synchronization implementations (search via `rg 'pub.*(with_timeout|cancel|refresh|Mutex|Semaphore)' .mooncakes/moonbitlang/async/src`).

## Reference and differences

Go reference is pinned **go1.23.2**, not whatever Go version is newest. Inspected full child.go/fcgi.go and relevant fixed vectors in fcgi_test.go. Go common supported cases are exercised by tools/reference/main.go plus external Node byte driver: binary POST, JSON, duplicate cookies, multi-record output and 404. Assertions compare application status/body; Go Date header, reason phrases and output segmentation are intentionally not byte-identical requirements. MoonFCGI explicitly rejects multiplexing; it does not promise Go's full behavior set.

Nginx module documentation: https://nginx.org/en/docs/http/ngx_http_fastcgi_module.html . Both upstream keepalive cache and `fastcgi_keep_conn on` are needed for the integration example. Tested Nginx is the official Windows 1.28.0 binary downloaded from https://nginx.org/download/nginx-1.28.0.zip . Go binary from https://go.dev/dl/go1.23.2.windows-amd64.zip . Tool binaries remain outside the project/package.

Moon manifests were generated by installed `moon new`, dependency added by `moon add moonbitlang/async@0.20.0`, executable uses actual `pkgtype(kind: "executable")` syntax. Package/dependency documentation: https://docs.moonbitlang.com/en/latest/toolchain/moon/package-manage-tour.html and https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html . Local consumption uses a generated `moon.work`; no obsolete path-dependency syntax was invented.

Initial directory/Git inspection found no existing project Git repository or applicable parent AGENTS.md. Existing outputs and work/moonsample-probe were preserved. moon new generated the local project's AGENTS.md; it was read and followed. New local repository history is real development history, no dates rewritten and no remote configured.
