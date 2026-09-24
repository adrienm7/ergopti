#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/fake_llm_server.py
#
# A stand-in for a hosted, OpenAI-compatible completion API (Cerebras speaks
# this dialect), so the live daemon test can prove a prediction end to end
# without a key or the network. Every request is appended to a log as one JSON
# line: the path, the Authorization header and the body the daemon sent.
#
# Usage: fake_llm_server.py --port N --log FILE --reply TEXT --ready-file FILE

import argparse
import json
import pathlib
from http.server import BaseHTTPRequestHandler, HTTPServer


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--reply", required=True)
    parser.add_argument("--ready-file", required=True)
    args = parser.parse_args()

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length).decode("utf-8", "replace")
            with open(args.log, "a", encoding="utf-8") as log:
                log.write(json.dumps({
                    "path": self.path,
                    "authorization": self.headers.get("Authorization"),
                    "body": body,
                }) + "\n")
            # ensure_ascii, as Python servers answer by default: the daemon must
            # decode \u escapes to get the accented text back.
            reply = json.dumps({"choices": [{"message": {"role": "assistant", "content": args.reply}}]})
            payload = reply.encode("ascii")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *_):
            pass

    server = HTTPServer(("127.0.0.1", args.port), Handler)
    pathlib.Path(args.ready_file).write_text("ready\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
