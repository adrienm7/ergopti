#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_http_redirect_method_receipts.py
# Real production curl/libuv against one owned loopback HTTP listener.
# Independently checks redirect verbs, literal bytes, callback/FD retirement,
# direct POST bodies, no-follow controls, synthetic credential fences and GET.

import http.server
import os
import subprocess
import tempfile
import threading

BODY = b'{"text":"controlled literal"}'
WIRE = []
CURRENT = {}


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()

    def handle_request(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        fenced = self.headers.get("X-Api-Key") is not None
        WIRE.append((self.command, self.path, body, fenced))
        if self.path.startswith("/start/"):
            code = int(self.path.rsplit("/", 1)[1])
            self.send_response(code)
            self.send_header("Location", "/result/" + str(code))
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            return
        if self.path == "/warmup":
            good = self.command == "GET" and body == b"" and not fenced
        elif self.path == "/direct":
            good = self.command == "POST" and body == CURRENT["body"] and not fenced
        else:
            good = (
                self.command == CURRENT["target_method"]
                and body == CURRENT["target_body"]
                and not fenced
            )
        result = b"abc" if good else b'{"error":"redirect method/body mismatch"}'
        self.send_response(200 if good else 405)
        self.send_header("Content-Length", str(len(result)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(result)
        self.close_connection = True


LUA = r"""
local uv=require('luv')
local H=require('adapters.http_client')
assert(uv.getuid()~=0)
local method=assert(os.getenv('CASE_METHOD'))
local code=assert(tonumber(os.getenv('CASE_STATUS')))
local mode=assert(os.getenv('CASE_MODE'))
local kind=assert(os.getenv('CASE_BODY'))
local origin=assert(os.getenv('CASE_ORIGIN'))
local destination=assert(os.getenv('CASE_DESTINATION'))
local function fds()
 local scan=assert(uv.fs_scandir('/proc/self/fd'));local n=0
 while uv.fs_scandir_next(scan)do n=n+1 end
 return n
end
local warmup
assert(H.get(origin..'/warmup',{}, {},function(r)warmup=r end));uv.run()
assert(warmup and warmup.ok and not uv.loop_alive())
local before=fds()
local body=kind=='empty' and '' or kind=='literal' and '{"text":"controlled literal"}' or nil
local result,callbacks,chunks=nil,0,''
local function done(r)result,callbacks=r,callbacks+1 end
local options={owner='native-redirect-method',follow_redirects=mode~='no-follow',timeout_ms=2000}
local headers={}
if mode=='fenced' then headers['X-Api-Key']='SyntheticFixtureOnly' end
local target=origin..(mode=='direct' and '/direct' or '/start/'..code)
local dispatched,operation
if method=='post' then dispatched=H.post(target,headers,body,done,options)
elseif method=='postStream' then dispatched=H.postStream(target,headers,body,options,function(s)chunks=chunks..s end,done)
elseif method=='get_owned' then operation=H.get_owned(target,{},options,done);dispatched=operation.started
elseif method=='download' then dispatched=H.download(target,{},destination,options,done)
else dispatched=H.get(target,{},options,done)end
assert(dispatched);uv.run()
assert(result and callbacks==1 and not H.isActive(options.owner) and not uv.loop_alive())
assert(fds()==before,'native curl redirect leaked a descriptor')
if operation then assert(operation:is_settled())end
print('NATIVE RECEIPT '..method..' '..code..' '..mode..' '..kind..' ok='..tostring(result.ok)..' status='..result.status..' callbacks='..callbacks..' retired=true')
if mode=='no-follow' or mode=='fenced' then
 assert(not result.ok and result.status==code and result.error=='HTTP '..code and result.body=='')
 assert(result.error_body=='' and chunks=='')
else
 assert(result.ok and result.status==200,'valid followed request rejected: '..tostring(result.error))
 if method=='download' then
  local file=assert(io.open(destination,'rb'));assert(file:read('*a')=='abc' and file:close())
 elseif method=='postStream' then assert(chunks=='abc')
 else assert(result.body=='abc')end
end
"""


def cases():
    for method in ("post", "postStream"):
        for kind in ("nil", "empty", "literal"):
            yield method, 0, "direct", kind
        for code in (301, 302, 303, 307, 308):
            yield method, code, "follow", "literal"
            yield method, code, "no-follow", "literal"
        for code in (303, 307):
            yield method, code, "fenced", "literal"
    for method in ("get", "get_owned", "download"):
        yield method, 303, "follow", "nil"


def main():
    server = Server(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    failures, checks = 0, 0
    try:
        with tempfile.TemporaryDirectory(prefix="ergopti-redirect-method-") as directory:
            for method, code, mode, kind in cases():
                checks += 1
                body = BODY if kind == "literal" else b""
                retrieve = method in ("get", "get_owned", "download") or code in (301, 302, 303)
                CURRENT.update(
                    body=body,
                    target_method="GET" if retrieve else "POST",
                    target_body=b"" if retrieve else body,
                )
                before = len(WIRE)
                destination = os.path.join(directory, "response-" + str(checks))
                env = os.environ.copy()
                env.update(
                    CASE_METHOD=method,
                    CASE_STATUS=str(code),
                    CASE_MODE=mode,
                    CASE_BODY=kind,
                    CASE_ORIGIN="http://127.0.0.1:" + str(server.server_address[1]),
                    CASE_DESTINATION=destination,
                )
                result = subprocess.run(
                    ["luajit", "-"],
                    input=LUA,
                    text=True,
                    env=env,
                    capture_output=True,
                    timeout=8,
                )
                expected = [("GET", "/warmup", b"", False)]
                if mode == "direct":
                    expected.append(("POST", "/direct", body, False))
                else:
                    initial_method = "GET" if method in ("get", "get_owned", "download") else "POST"
                    expected.append((initial_method, "/start/" + str(code), body, mode == "fenced"))
                    if mode == "follow":
                        expected.append(
                            (
                                CURRENT["target_method"],
                                "/result/" + str(code),
                                CURRENT["target_body"],
                                False,
                            )
                        )
                wire = WIRE[before:]
                good = result.returncode == 0 and wire == expected
                if method == "download" and good:
                    with open(destination, "rb") as response:
                        good = response.read() == b"abc"
                print(("PASS " if good else "FAIL ") + f"native {method} {code} {mode} {kind}")
                if not good:
                    failures += 1
                    print("wire=" + repr(wire))
                    print(result.stdout.strip())
                    print(result.stderr.strip())
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    print(f"Native HTTP redirect method receipts: {checks} checks, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
