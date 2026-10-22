// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "Ryan-1125/moonfcgi"

version = "0.2.0"

readme = "README.md"

repository = "https://github.com/Ryan-1125/moonfcgi"

license = "Apache-2.0"

keywords = [ "fastcgi", "fcgi", "server", "protocol" ]

preferred_target = "native"

description = "Native FastCGI codec, streaming Responder/Authorizer/Filter and TCP/POSIX server"

import {
  "moonbitlang/async@0.20.0",
}
