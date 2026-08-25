#!/usr/bin/env python3
"""hwhisper API-path test stub. Behavior keyed off the requested model name."""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8", "replace")
        try:
            model = json.loads(body).get("model", "")
        except Exception:
            model = ""

        if model == "echo-422":
            # FastAPI/pydantic-style validation error that ECHOES the request
            # (the leak shape the audit flagged) + a sentinel marker.
            payload = json.dumps({"detail": [{"loc": ["body"], "msg": "SENTINEL-ECHO-XYZ", "input": body}]})
            self._send(422, payload)
        elif model == "envelope-404":
            self._send(404, json.dumps({"error": {"code": 404, "message": "model not found here"}}))
        elif model == "selective":
            if "ZZFAIL" in body:
                self._send(500, json.dumps({"error": {"code": 500, "message": "selective failure"}}))
            else:
                self._send(200, json.dumps({
                    "choices": [{"message": {"content": "REFINED-BY-STUB"}, "finish_reason": "stop"}]}))
        else:
            self._send(200, json.dumps({
                "choices": [{"message": {"content": "REFINED-BY-STUB"}, "finish_reason": "stop"}]}))

    def _send(self, status, payload):
        data = payload.encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

HTTPServer(("127.0.0.1", 18765), H).serve_forever()
