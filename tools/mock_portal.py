#!/usr/bin/env python3
"""A stand-in for the hostel Wi-Fi: a connectivity-check endpoint plus a Pronto-style
login portal. Standard library only.

    python3 tools/mock_portal.py --port 8765 --mode captive --login ok

While it runs, change its behaviour with:

    curl http://127.0.0.1:8765/__mode/captive      (or /__mode/online)
    curl http://127.0.0.1:8765/__login/ok          (or bad, limit, expired)
    curl http://127.0.0.1:8765/__state
"""

import argparse
import json
import socketserver
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

MODES = ("captive", "online")
LOGINS = ("ok", "bad", "limit", "expired")

LOGIN_PAGES = {
    "ok": "<html><head><title>Pronto Authentication</title></head><body>"
          "<h3>Congratulations !!!</h3><p>You are successfully logged in</p></body></html>",
    "bad": "<html><body><p>Sorry, please check your userid and password and try again. "
           "Invalid userid or password.</p></body></html>",
    "limit": "<html><body><p>Sorry, your Max Session limit has been reached.</p></body></html>",
    "expired": "<html><body><p>Sorry, your account expired. Please contact the administrator.</p></body></html>",
}

LOGOUT_PAGE = (
    "<html><body><h3>Logout successful</h3><table>"
    "<tr><td>Time Spent : 1 H : 2 M : 3 S</td></tr>"
    "<tr><td>Bytes Sent : 1234</td></tr>"
    "<tr><td>Bytes Received : 5678</td></tr>"
    "</table></body></html>"
)

PORTAL_PAGE = (
    "<html><body><form method=\"post\" action=\"/cgi-bin/authlogin\">"
    "User ID <input name=\"userId\"> Password <input type=\"password\" name=\"password\">"
    "<input type=\"hidden\" name=\"serviceName\" value=\"ProntoAuthentication\">"
    "<input type=\"submit\" value=\"Login\"></form></body></html>"
)


class State:
    def __init__(self, mode, login):
        self.lock = threading.Lock()
        self.mode = mode
        self.login = login
        self.logins = 0
        self.logouts = 0

    def snapshot(self):
        with self.lock:
            return {"mode": self.mode, "login": self.login, "logins": self.logins, "logouts": self.logouts}


class Handler(BaseHTTPRequestHandler):
    state = None
    quiet = False
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        # Log the request line only. Bodies carry passwords and are never printed.
        if not self.quiet:
            print("%s %s" % (self.command, urlsplit(self.path).path), flush=True)

    def reply(self, status, body="", content_type="text/html", headers=None):
        data = body.encode("utf-8")
        self.send_response(status)
        if status != 204:
            self.send_header("Content-Type", content_type + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if data:
            self.wfile.write(data)

    def do_GET(self):
        path = urlsplit(self.path).path
        state = self.state

        if path == "/generate_204":
            with state.lock:
                mode = state.mode
            if mode == "online":
                self.reply(204)
            else:
                host = self.headers.get("Host") or "127.0.0.1:%d" % self.server.server_port
                self.reply(302, headers={"Location": "http://%s/portal" % host})
        elif path == "/portal":
            self.reply(200, PORTAL_PAGE)
        elif path == "/cgi-bin/authlogout":
            with state.lock:
                state.mode = "captive"
                state.logouts += 1
            self.reply(200, LOGOUT_PAGE)
        elif path.startswith("/__mode/") and path.split("/")[-1] in MODES:
            with state.lock:
                state.mode = path.split("/")[-1]
            self.reply(200, json.dumps(state.snapshot()), "application/json")
        elif path.startswith("/__login/") and path.split("/")[-1] in LOGINS:
            with state.lock:
                state.login = path.split("/")[-1]
            self.reply(200, json.dumps(state.snapshot()), "application/json")
        elif path == "/__state":
            self.reply(200, json.dumps(state.snapshot()), "application/json")
        else:
            self.reply(404, "<html><body>Not found</body></html>")

    def do_POST(self):
        path = urlsplit(self.path).path
        length = int(self.headers.get("Content-Length") or 0)
        fields = parse_qs(self.rfile.read(length).decode("utf-8", "replace"), keep_blank_values=True)

        if path != "/cgi-bin/authlogin":
            self.reply(404, "<html><body>Not found</body></html>")
            return

        content_type = (self.headers.get("Content-Type") or "").split(";")[0].strip()
        well_formed = (
            content_type == "application/x-www-form-urlencoded"
            and fields.get("userId", [""])[0] != ""
            and fields.get("password", [""])[0] != ""
            and fields.get("serviceName") == ["ProntoAuthentication"]
        )
        if not well_formed:
            self.reply(400, "<html><body>Malformed request</body></html>")
            return

        state = self.state
        with state.lock:
            login = state.login
            state.logins += 1
            if login == "ok":
                state.mode = "online"
        self.reply(200, LOGIN_PAGES[login])


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def server_bind(self):
        # The stock implementation looks up the host's name, which can hang for a
        # long time on a network whose DNS doesn't answer reverse lookups.
        socketserver.TCPServer.server_bind(self)
        self.server_name = self.server_address[0]
        self.server_port = self.server_address[1]


def main():
    parser = argparse.ArgumentParser(description="Mock hostel Wi-Fi portal")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--mode", choices=MODES, default="captive")
    parser.add_argument("--login", choices=LOGINS, default="ok")
    parser.add_argument("--quiet", action="store_true", help="don't log requests")
    args = parser.parse_args()

    Handler.state = State(args.mode, args.login)
    Handler.quiet = args.quiet
    server = Server((args.host, args.port), Handler)
    if not args.quiet:
        print("Mock portal on http://%s:%d (mode=%s, login=%s). Ctrl-C to stop."
              % (args.host, args.port, args.mode, args.login), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
