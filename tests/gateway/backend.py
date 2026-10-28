"""Stands in for every Service the gateway routes to.

One process listens on each port in PORTS ("5585:api,8080:hasura,..."), so a
Service named like the real one reaches it on the real port. Every response is
JSON describing the request as it arrived, which is what the tests assert on.

/streams/authorize, /plugins/authorize and /qx/authorize answer like the api's
forward-auth on branch feature/forward-auth-traefik: X-Original-* and
X-Forwarded-* that disagree are refused, a forwarded OPTIONS is a preflight,
and otherwise the session cookie decides.
"""

import base64
import hashlib
import json
import os
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

AUTH_LOG = []
AUTH_LOCK = threading.Lock()
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def recv_exact(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("closed")
        data += chunk
    return data


def ws_frame(opcode, payload):
    header = bytes([0x80 | opcode])
    if len(payload) < 126:
        header += bytes([len(payload)])
    elif len(payload) < 65536:
        header += bytes([126]) + struct.pack(">H", len(payload))
    else:
        header += bytes([127]) + struct.pack(">Q", len(payload))
    return header + payload


def handler_for(name):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def headers_dict(self):
            return {k.lower(): v for k, v in self.headers.items()}

        def read_body(self):
            total = 0
            if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
                while True:
                    size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                    if size == 0:
                        self.rfile.readline()
                        break
                    remaining = size
                    while remaining:
                        remaining -= len(self.rfile.read(min(remaining, 1 << 20)))
                    self.rfile.readline()
                    total += size
                return total
            remaining = int(self.headers.get("Content-Length") or 0)
            while remaining:
                got = len(self.rfile.read(min(remaining, 1 << 20)))
                if not got:
                    break
                remaining -= got
                total += got
            return total

        def reply(self, status, body=None, headers=None):
            data = b"" if body is None else json.dumps(body, sort_keys=True).encode()
            self.send_response(status)
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def describe(self, body_bytes):
            return {
                "backend": name,
                "method": self.command,
                "path": self.path,
                "host": self.headers.get("Host"),
                "headers": self.headers_dict(),
                "body_bytes": body_bytes,
            }

        def authorize(self):
            h = self.headers_dict()
            with AUTH_LOCK:
                AUTH_LOG.append({"method": self.command, "path": self.path, "headers": h})
            for nginx, traefik in (("x-original-method", "x-forwarded-method"), ("x-original-url", "x-forwarded-uri")):
                a, b = h.get(nginx), h.get(traefik)
                if a is not None and b is not None:
                    if nginx == "x-original-method" and a.upper() != b.upper():
                        return self.reply(401)
                    if nginx == "x-original-url" and urlsplit(a).path != urlsplit(b).path:
                        return self.reply(401)
            method = (h.get("x-original-method") or h.get("x-forwarded-method") or self.command).upper()
            if method == "OPTIONS":
                return self.reply(200)
            cookie = h.get("cookie", "")
            role = "administrator" if "session=admin" in cookie else "user" if "session=ok" in cookie else None
            if role is None:
                return self.reply(401)
            if h.get("x-5stack-required-role") == "administrator" and role != "administrator":
                return self.reply(403)
            return self.reply(200, headers={"X-5stack-Role": role})

        def websocket(self):
            key = self.headers["Sec-WebSocket-Key"]
            accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept)
            self.end_headers()
            self.wfile.flush()
            sock = self.connection
            sock.settimeout(None)
            hello = json.dumps({"backend": name, "path": self.path, "host": self.headers.get("Host")}).encode()
            sock.sendall(ws_frame(0x1, hello))
            try:
                while True:
                    b1, b2 = recv_exact(sock, 2)
                    opcode, length = b1 & 0x0F, b2 & 0x7F
                    if length == 126:
                        length = struct.unpack(">H", recv_exact(sock, 2))[0]
                    elif length == 127:
                        length = struct.unpack(">Q", recv_exact(sock, 8))[0]
                    mask = recv_exact(sock, 4) if b2 & 0x80 else b"\0\0\0\0"
                    payload = bytes(c ^ mask[i % 4] for i, c in enumerate(recv_exact(sock, length)))
                    if opcode == 0x8:
                        sock.sendall(ws_frame(0x8, b""))
                        break
                    sock.sendall(ws_frame(0xA if opcode == 0x9 else opcode, payload))
            except (ConnectionError, OSError):
                pass
            self.close_connection = True

        def stream(self, seconds):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for i in range(seconds):
                line = f"tick {i}\n".encode()
                self.wfile.write(b"%x\r\n%s\r\n" % (len(line), line))
                self.wfile.flush()
                time.sleep(1)
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()

        def handle_any(self):
            path = urlsplit(self.path).path
            if self.headers.get("Upgrade", "").lower() == "websocket":
                return self.websocket()
            if path.endswith(("/streams/authorize", "/plugins/authorize", "/qx/authorize")):
                self.read_body()
                return self.authorize()
            if path.endswith("/__auth_log"):
                self.read_body()
                with AUTH_LOCK:
                    log = list(AUTH_LOG)
                    if "clear" in parse_qs(urlsplit(self.path).query):
                        AUTH_LOG.clear()
                return self.reply(200, log)
            if path.endswith("/stream"):
                seconds = int(parse_qs(urlsplit(self.path).query).get("seconds", ["5"])[0])
                return self.stream(seconds)
            body_bytes = self.read_body()
            if self.command == "POST" and path.endswith("/whep"):
                return self.reply(201, self.describe(body_bytes), {"Location": path + "/session-1"})
            return self.reply(200, self.describe(body_bytes))

        do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = do_HEAD = handle_any

    return Handler


def main():
    servers = []
    for entry in os.environ["PORTS"].split(","):
        port, name = entry.split(":")
        server = ThreadingHTTPServer(("0.0.0.0", int(port)), handler_for(name))
        server.daemon_threads = True
        servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    threading.Event().wait()


if __name__ == "__main__":
    main()
