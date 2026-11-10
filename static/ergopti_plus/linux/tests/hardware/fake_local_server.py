#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/fake_local_server.py
"""A stand-in for a local OpenAI-compatible model server.

The container proof cannot install llama.cpp, vLLM, Lemonade or KoboldCpp
with a model, so this program takes their place: copied under the server's
executable name and started with the server's own flags, it shows the same
command line in /proc, listens where the real server would, and answers
GET <prefix>/models with the OpenAI ModelList shape, `owned_by` set as the
real server sets it. Unknown arguments (a model path, `serve`) are accepted.

Usage: <name> [serve MODEL] [--port N | --api-port N] [--config-port FILE KEY]
       [--default-port N] [--owned-by TEXT] [--served-model ID] [--prefix /v1]
"""

import argparse
import json
import pathlib
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--port", type=int)
    parser.add_argument("--api-port", type=int)
    parser.add_argument("--config-port", nargs=2, metavar=("FILE", "KEY"))
    parser.add_argument("--default-port", type=int)
    parser.add_argument("--owned-by", default="owner")
    parser.add_argument("--served-model", default="stand-in-model")
    parser.add_argument("--prefix", default="/v1")
    args, _ = parser.parse_known_args()
    port = args.port or args.api_port
    if port is None and args.config_port:
        path, key = args.config_port
        port = json.loads(pathlib.Path(path).expanduser().read_text())[key]
    port = port or args.default_port
    if not port:
        parser.error("no port: give --port, --api-port, --config-port or --default-port")

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def reply(self, status, document):
            payload = json.dumps(document).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            if self.path == args.prefix + "/models":
                self.reply(
                    200,
                    {
                        "object": "list",
                        "data": [
                            {
                                "id": args.served_model,
                                "object": "model",
                                "created": 0,
                                "owned_by": args.owned_by,
                            }
                        ],
                    },
                )
            else:
                self.reply(404, {"error": {"message": "not found"}})

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            self.rfile.read(length)
            if self.path == args.prefix + "/chat/completions":
                self.reply(
                    200, {"choices": [{"message": {"role": "assistant", "content": "bonjour"}}]}
                )
            else:
                self.reply(404, {"error": {"message": "not found"}})

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    sys.stdout.write(f"listening {port}\n")
    sys.stdout.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
