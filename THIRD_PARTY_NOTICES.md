# Third-party sources

MoonFCGI source is licensed under Apache-2.0 (LICENSE). Protocol logic and fixed vectors were independently written from the FastCGI 1.0 specification. No Go source or C FastCGI implementation is linked into the MoonBit library.

- FastCGI 1.0 specification, Open Market, 1996-04-29: https://fastcgi-archives.github.io/FastCGI_Specification.html . Used as protocol documentation; no whole specification is redistributed.
- Go go1.23.2 `src/net/http/fcgi/{child.go,fcgi.go,fcgi_test.go}`: https://github.com/golang/go/tree/go1.23.2/src/net/http/fcgi . Read for behavior and test ideas. The independent Go test fixture imports the unmodified standard library. BSD-3-Clause copyright and disclaimer are preserved in `licenses/Go-LICENSE`.
- moonbitlang/async 0.20.0: https://github.com/moonbitlang/async . Apache-2.0, fetched by Moon package manager, not vendored. Includes its own upstream notices and dependencies.
- Nginx 1.28.0 is an external test/runtime program: https://nginx.org/ . Neither Nginx nor Go toolchain binaries are included in the distributable.

No third-party source was presented as original work; this project does not claim authorship of the FastCGI protocol or reference implementations.
