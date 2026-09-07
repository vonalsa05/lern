from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"OK")
            return

        if self.path == "/readyz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"READY")
            return

        self.send_response(404)
        self.end_headers()

    def log_message(self, format, *args):
        print(format % args)


server = HTTPServer(("0.0.0.0", 8080), Handler)

print("Server started on port 8080")
server.serve_forever()
