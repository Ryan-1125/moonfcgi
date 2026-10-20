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
with_timeout and Timer. Actual compilation will determine compatibility.
