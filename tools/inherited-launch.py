"""Test fixture: exec the native app with a real TCP listener at descriptor 0."""
import os
import socket
import sys

unix_path = sys.argv[2][5:] if sys.argv[2].startswith("unix:") else None
listener = socket.socket(socket.AF_UNIX if unix_path else socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(unix_path if unix_path else ("127.0.0.1", int(sys.argv[2])))
if unix_path:
    os.chmod(unix_path, 0o600)
listener.listen(128)
os.dup2(listener.fileno(), 0, inheritable=True)
if listener.fileno() != 0:
    listener.close()
os.execv(sys.argv[1], [sys.argv[1], "fd:0", "test"])
