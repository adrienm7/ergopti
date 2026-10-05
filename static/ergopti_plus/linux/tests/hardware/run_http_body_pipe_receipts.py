#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_http_body_pipe_receipts.py
# Drives production Linux curl/libuv against an owned loopback HTTP server.
# Python independently constructs and verifies exact JSON bytes and SHA-256;
# Lua observes callback, pending-write, descriptor and native handle receipts.
# No process, socket, filesystem or timer API is mocked.

import hashlib
import http.server
import json
import os
import subprocess
import threading


LUA_REQUEST = r"""
local uv = require("luv")
local Http = require("adapters.http_client")
assert(uv.getuid() ~= 0, "native body-pipe checks require an ordinary user")
local origin = assert(os.getenv("ERGOPTI_BODY_ORIGIN"))
local method = assert(os.getenv("ERGOPTI_BODY_METHOD"))
local kind = assert(os.getenv("ERGOPTI_BODY_KIND"))
local size = assert(tonumber(os.getenv("ERGOPTI_BODY_SIZE")))
local mode = assert(os.getenv("ERGOPTI_BODY_MODE"))
local owner = "native-body-pipe"
local function descriptors()
    local scan = assert(uv.fs_scandir("/proc/self/fd"))
    local count = 0
    while uv.fs_scandir_next(scan) do count = count + 1 end
    return count
end
local warmup
assert(Http.get(origin .. "/warmup", {}, { owner = owner, timeout_ms = 2000 }, function(value) warmup = value end))
uv.run()
assert(warmup and warmup.ok and warmup.body == "abc" and not uv.loop_alive())
local before = descriptors()
local body
if kind == "small" then body = [=[{"text":"@literal é 日本語 \\ \" \u0000"}]=]
elseif kind == "nul" then body = "before\0after"
elseif kind == "escaped" then body = '{"text":"' .. string.rep('\\"', size) .. '"}'
else body = '{"text":"' .. string.rep("x", size) .. '"}' end
local result, callbacks, chunks = nil, 0, ""
local options = { owner = owner, timeout_ms = kind == "timeout" and 1 or 5000 }
local function complete(value) result, callbacks = value, callbacks + 1 end
local url = origin .. "/body?literal=%2F%00&filter[name]=one"
local dispatched
if method == "post" then dispatched = Http.post(url, { ["Content-Type"] = "application/json" }, body, complete, options)
else dispatched = Http.postStream(url, { ["Content-Type"] = "application/json" }, body, options,
    function(bytes) chunks = chunks .. bytes end, complete) end
if kind == "nul" then
    assert(dispatched == false and result and not result.ok and result.status == 0 and callbacks == 1)
else
    assert(dispatched)
end
if kind == "cancel" or kind == "timeout" then
    local queued = false
    uv.walk(function(handle)
        local ok, bytes = pcall(uv.stream_get_write_queue_size, handle)
        if ok and bytes > 0 then queued = true end
    end)
    assert(queued, "fixture must own an actual backpressured body writer")
end
local successor, operation
if kind == "cancel" then
    assert(Http.cancel(owner))
    operation = Http.get_owned(origin .. "/successor", {}, { owner = owner, timeout_ms = 2000 },
        function(value) successor = value end)
    assert(operation.started)
end
uv.run()
assert(not uv.loop_alive(), "body request retained a native process/pipe/timer")
assert(descriptors() == before, "body request leaked an anonymous pipe descriptor")
assert(not Http.isActive(owner))
if kind == "cancel" then
    assert(callbacks == 0 and result == nil, "cancelled body delivery published a stale receipt")
    assert(successor and successor.ok and successor.body == "abc" and operation:is_settled())
else
    assert(result and callbacks == 1, "body transfer did not publish exactly one receipt")
    if kind == "timeout" then assert(not result.ok and result.status == 0 and result.error == "timeout")
    elseif kind == "nul" then assert(not result.ok and result.status == 0)
    elseif mode == "refused" then
        assert(not result.ok and result.status == 401 and result.error == "HTTP 401")
        assert(result.error_body == '{"error":"controlled refusal"}')
    elseif mode == "incomplete" then
        assert(not result.ok and result.status == 200 and result.body == "" and result.error_body == nil)
    else
        assert(result.ok and result.status == 200)
        if method == "post" then assert(result.body == "abc") else assert(chunks == "abc") end
    end
end
print("PASS native " .. method .. " " .. kind .. " " .. mode .. " bytes=" .. #body .. " callbacks=" .. callbacks)
"""


def payload(kind, size):
    """Construct expectations independently of the Lua producer and curl."""
    if kind == "small":
        return r'{"text":"@literal é 日本語 \\ \" \u0000"}'.encode("utf-8")
    if kind == "escaped":
        return b'{"text":"' + b'\\"' * size + b'"}'
    return b'{"text":"' + b"x" * size + b'"}'


def main():
    assert os.getuid() != 0, "native receipts require an ordinary user"
    checks, failures = 0, 0
    for method in ("post", "postStream"):
        cases = [
            ("small", 0, "normal"),
            ("large", 7 * 1024 * 1024, "normal"),
            ("large", 10 * 1024 * 1024, "normal"),
            ("large", 12 * 1024 * 1024, "normal"),
            ("escaped", 3 * 1024 * 1024, "normal"),
            ("large", 12 * 1024 * 1024, "refused"),
            ("large", 12 * 1024 * 1024, "incomplete"),
            ("cancel", 32 * 1024 * 1024, "normal"),
            ("timeout", 32 * 1024 * 1024, "normal"),
            ("nul", 0, "normal"),
        ]
        for kind, size, mode in cases:
            expected = payload(kind, size)
            json.loads(expected)  # Independently validate all admitted JSON controls.
            expected_hash = hashlib.sha256(expected).hexdigest()
            receipts, server_errors = [], []

            class Handler(http.server.BaseHTTPRequestHandler):
                protocol_version = "HTTP/1.1"

                def log_message(self, *_args):
                    pass

                def respond(self, status, data, declared=None):
                    self.send_response(status)
                    self.send_header(
                        "Content-Length", str(len(data) if declared is None else declared)
                    )
                    self.send_header("Connection", "close")
                    self.end_headers()
                    self.wfile.write(data)
                    self.close_connection = True

                def do_GET(self):
                    self.respond(200, b"abc")

                def do_POST(self):
                    received = self.rfile.read(int(self.headers["Content-Length"]))
                    identity = hashlib.sha256(received).hexdigest()
                    receipts.append((len(received), identity, self.path))
                    if received != expected or identity != expected_hash:
                        server_errors.append("independent server observed changed body bytes")
                    try:
                        if mode == "refused":
                            self.respond(401, b'{"error":"controlled refusal"}')
                        else:
                            self.respond(200, b"abc", 103 if mode == "incomplete" else None)
                    except (BrokenPipeError, ConnectionResetError):
                        if kind not in ("cancel", "timeout"):
                            server_errors.append("unexpected native connection retirement")

            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            env = os.environ.copy()
            env.update(
                {
                    "ERGOPTI_BODY_ORIGIN": f"http://127.0.0.1:{server.server_port}",
                    "ERGOPTI_BODY_METHOD": method,
                    "ERGOPTI_BODY_KIND": kind,
                    "ERGOPTI_BODY_SIZE": str(size),
                    "ERGOPTI_BODY_MODE": mode,
                }
            )
            try:
                result = subprocess.run(
                    ["luajit", "-"],
                    input=LUA_REQUEST,
                    text=True,
                    capture_output=True,
                    env=env,
                    timeout=15,
                )
                checks += 1
                refused_before_wire = kind in ("cancel", "timeout", "nul")
                expected_receipts = 0 if refused_before_wire else 1
                valid = (
                    result.returncode == 0
                    and len(receipts) == expected_receipts
                    and not server_errors
                )
                valid = valid and all(
                    target == "/body?literal=%2F%00&filter[name]=one"
                    for _length, _identity, target in receipts
                )
                if valid:
                    print(result.stdout.strip(), flush=True)
                else:
                    failures += 1
                    print(
                        f"FAIL {method} {kind} {mode}: exit={result.returncode} receipts={receipts} errors={server_errors}",
                        flush=True,
                    )
                    print(result.stdout + result.stderr, flush=True)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)
                assert not thread.is_alive(), "owned HTTP server did not retire"
    assert checks == 20, "native body regression case inventory changed"
    print(f"Native HTTP body pipe receipts: {checks} checks, {failures} failures")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
