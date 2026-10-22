/* MoonFCGI POSIX transport glue, Apache-2.0. Protocol and scheduling remain MoonBit. */
#include "moonbit.h"
#include <stdint.h>
#ifdef _WIN32
MOONBIT_FFI_EXPORT int moonfcgi_unix_open(const unsigned char *p, int mode) { return -1; }
MOONBIT_FFI_EXPORT int moonfcgi_listener_dup(int fd) { return -1; }
MOONBIT_FFI_EXPORT int moonfcgi_listener_accept(int fd) { return -1; }
MOONBIT_FFI_EXPORT int64_t moonfcgi_path_ino(const unsigned char *p) { return -1; }
MOONBIT_FFI_EXPORT int64_t moonfcgi_path_dev(const unsigned char *p) { return -1; }
MOONBIT_FFI_EXPORT void moonfcgi_unix_remove(const unsigned char *p, int64_t ino, int64_t dev) {}
#else
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
static int path_copy(const unsigned char *p, struct sockaddr_un *a) {
  int n = Moonbit_array_length(p);
  if (n < 1 || n >= (int)sizeof(a->sun_path) || memchr(p, 0, n)) { errno = EINVAL; return -1; }
  memset(a, 0, sizeof(*a)); a->sun_family = AF_UNIX;
  memcpy(a->sun_path, p, n); return 0;
}
MOONBIT_FFI_EXPORT int moonfcgi_unix_open(const unsigned char *p, int mode) {
  struct sockaddr_un a;
  if (path_copy(p, &a) < 0) return -1;
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 ||
      fcntl(fd, F_SETFL, O_NONBLOCK) < 0 || bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0) {
    int e = errno; close(fd); errno = e; return -1;
  }
  if (chmod(a.sun_path, mode) < 0 || listen(fd, 128) < 0) {
    int e = errno; close(fd); unlink(a.sun_path); errno = e; return -1;
  }
  return fd;
}
MOONBIT_FFI_EXPORT int moonfcgi_listener_dup(int source) {
  int type = 0, acceptconn = 0; socklen_t n = sizeof(int);
  struct sockaddr_storage addr; socklen_t size = sizeof(addr);
  if (getsockopt(source, SOL_SOCKET, SO_TYPE, &type, &n) < 0 || type != SOCK_STREAM ||
      getsockopt(source, SOL_SOCKET, SO_ACCEPTCONN, &acceptconn, &n) < 0 || !acceptconn ||
      getsockname(source, (struct sockaddr *)&addr, &size) < 0 ||
      !(addr.ss_family == AF_UNIX || addr.ss_family == AF_INET || addr.ss_family == AF_INET6)) {
    errno = EINVAL; return -1;
  }
  int fd = fcntl(source, F_DUPFD_CLOEXEC, 3);
  if (fd < 0) return -1;
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
    int e = errno; close(fd); errno = e; return -1;
  }
  return fd;
}
MOONBIT_FFI_EXPORT int moonfcgi_listener_accept(int listener) {
  int fd = accept(listener, NULL, NULL);
  if (fd < 0) return (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) ? -2 : -1;
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
    close(fd); return -1;
  }
  return fd;
}
MOONBIT_FFI_EXPORT int64_t moonfcgi_path_ino(const unsigned char *p) {
  struct sockaddr_un a; struct stat st;
  if (path_copy(p,&a) < 0 || lstat(a.sun_path,&st) < 0) return -1;
  return (int64_t)st.st_ino;
}
MOONBIT_FFI_EXPORT int64_t moonfcgi_path_dev(const unsigned char *p) {
  struct sockaddr_un a; struct stat st;
  if (path_copy(p,&a) < 0 || lstat(a.sun_path,&st) < 0) return -1;
  return (int64_t)st.st_dev;
}
MOONBIT_FFI_EXPORT void moonfcgi_unix_remove(const unsigned char *p, int64_t ino, int64_t dev) {
  struct sockaddr_un a; struct stat st;
  if (path_copy(p,&a) == 0 && lstat(a.sun_path,&st) == 0 && S_ISSOCK(st.st_mode) &&
      (int64_t)st.st_ino == ino && (int64_t)st.st_dev == dev) unlink(a.sun_path);
}
#endif
