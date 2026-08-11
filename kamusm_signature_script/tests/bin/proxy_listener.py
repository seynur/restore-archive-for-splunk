#!/usr/bin/env python3
"""Bind 127.0.0.1:0, print port, wait for one TCP client, write hit file.

Usage: proxy_listener.py HIT_FILE [TIMEOUT_SEC]
Stdout: chosen port (single line). Exits 0 after accept+close, 1 on timeout.
"""
from __future__ import annotations

import socket
import sys
import time


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: proxy_listener.py HIT_FILE [TIMEOUT_SEC]", file=sys.stderr)
        return 2
    hit_file = sys.argv[1]
    timeout = float(sys.argv[2]) if len(sys.argv) > 2 else 8.0

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.listen(1)
    sock.settimeout(timeout)
    print(port, flush=True)

    try:
        conn, addr = sock.accept()
    except socket.timeout:
        return 1
    with conn:
        with open(hit_file, "w", encoding="utf-8") as f:
            f.write(f"hit from {addr[0]}:{addr[1]}\n")
        # Brief pause so peer nc -z / connect can complete cleanly.
        time.sleep(0.05)
    sock.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
