#!/usr/bin/env python3
import hashlib
import hmac
import os
import stat
import sys


token_path, status_path, kind, value = sys.argv[1:5]
token_before = os.lstat(token_path)
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
token_fd = os.open(token_path, flags)
try:
    token_opened = os.fstat(token_fd)
    if not stat.S_ISREG(token_opened.st_mode):
        raise SystemExit(125)
    if (token_before.st_dev, token_before.st_ino) != (
        token_opened.st_dev,
        token_opened.st_ino,
    ):
        raise SystemExit(125)
    token_chunks = []
    token_remaining = 33
    while token_remaining:
        token_chunk = os.read(token_fd, token_remaining)
        if not token_chunk:
            break
        token_chunks.append(token_chunk)
        token_remaining -= len(token_chunk)
    token = b"".join(token_chunks)
finally:
    os.close(token_fd)
if len(token) != 32:
    raise SystemExit(125)
os.unlink(token_path)

flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
status_fd = os.open(status_path, flags, 0o600)
try:
    if os.name == "posix":
        os.fchmod(status_fd, 0o600)
    identity = os.fstat(status_fd)
    canonical = (
        "cccc-timeout-result-v2 kind=%s value=%s status_dev=%d status_ino=%d"
        % (kind, value, identity.st_dev, identity.st_ino)
    ).encode("ascii")
    mac = hmac.new(token, canonical, hashlib.sha256).hexdigest().encode("ascii")
    os.write(status_fd, canonical + b" mac=" + mac + b"\n")
    os.fsync(status_fd)
finally:
    os.close(status_fd)
