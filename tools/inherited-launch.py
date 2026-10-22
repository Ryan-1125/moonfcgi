"""Test fixture: exec the native app with a real TCP listener at descriptor 0."""
import os
import socket
import sys

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", int(sys.argv[2])))
listener.listen(128)
os.dup2(listener.fileno(), 0, inheritable=True)
if listener.fileno() != 0:
    listener.close()
os.execv(sys.argv[1], [sys.argv[1], "fd:0", "test"])
