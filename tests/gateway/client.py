"""Runs in the client container, where curl can't drive a websocket or time
an outage.

  client.py ws IP HOST PATH HOLD_SECONDS
      Opens wss://HOST/PATH against IP, echoes a frame through it every 10s
      for HOLD_SECONDS, and prints what came back as JSON.

  client.py poll IP HOST PATH STOPFILE
      Requests https://HOST/PATH against IP every 0.2s until STOPFILE exists,
      and prints the requests that failed and the longest outage as JSON.
"""

import base64
import json
import os
import socket
import ssl
import struct
import sys
import time


def tls_socket(ip, host, timeout):
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    raw = socket.create_connection((ip, 443), timeout=timeout)
    return ctx.wrap_socket(raw, server_hostname=host)


def read_frame(sock):
    def exact(n):
        data = b""
        while len(data) < n:
            chunk = sock.recv(n - len(data))
            if not chunk:
                raise ConnectionError("closed")
            data += chunk
        return data

    b1, b2 = exact(2)
    length = b2 & 0x7F
    if length == 126:
        length = struct.unpack(">H", exact(2))[0]
    elif length == 127:
        length = struct.unpack(">Q", exact(8))[0]
    return b1 & 0x0F, exact(length)


def send_frame(sock, payload):
    mask = os.urandom(4)
    masked = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
    sock.sendall(bytes([0x81, 0x80 | len(payload)]) + mask + masked)


def ws(ip, host, path, hold):
    result = {"status": None, "hello": None, "echoes": 0, "held": 0, "error": None}
    started = time.monotonic()
    try:
        sock = tls_socket(ip, host, 30)
        key = base64.b64encode(os.urandom(16)).decode()
        sock.sendall(
            (f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
             f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode()
        )
        head = b""
        while b"\r\n\r\n" not in head:
            head += sock.recv(1)
        result["status"] = int(head.split(b" ")[1])
        _, hello = read_frame(sock)
        result["hello"] = json.loads(hello)
        sock.settimeout(30)
        while True:
            message = f"echo {result['echoes']}".encode()
            send_frame(sock, message)
            opcode, payload = read_frame(sock)
            if opcode != 0x1 or payload != message:
                raise ValueError(f"bad echo {opcode} {payload!r}")
            result["echoes"] += 1
            if time.monotonic() - started >= hold:
                break
            time.sleep(10)
    except Exception as e:
        result["error"] = repr(e)
    result["held"] = round(time.monotonic() - started)
    print(json.dumps(result))


def poll(ip, host, path, stopfile):
    failures, outage_started, longest, requests = [], None, 0.0, 0
    started = time.monotonic()
    while not os.path.exists(stopfile):
        now = time.monotonic()
        status = None
        try:
            sock = tls_socket(ip, host, 2)
            sock.sendall(f"GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
            status = int(sock.recv(64).split(b" ")[1])
            sock.close()
        except Exception:
            pass
        requests += 1
        if status == 200:
            if outage_started is not None:
                longest = max(longest, now - outage_started)
                outage_started = None
        else:
            failures.append({"t": round(now - started, 1), "status": status})
            if outage_started is None:
                outage_started = now
        time.sleep(0.2)
    if outage_started is not None:
        longest = max(longest, time.monotonic() - outage_started)
    print(json.dumps({"requests": requests, "failed": len(failures), "longest_outage": round(longest, 1),
                      "failures": failures[:50]}))


if __name__ == "__main__":
    if sys.argv[1] == "ws":
        ws(sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]))
    else:
        poll(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
