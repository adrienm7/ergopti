#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_updater_conditional_receipts.py
"""Exercise real updater conditional receipts against an owned verified TLS server."""

import os
import pathlib
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time


def run_case(mode):
    with tempfile.TemporaryDirectory(prefix="ergopti-updater-conditional-") as folder:
        root = pathlib.Path(folder)
        (root / ".cache").mkdir()
        cert, key = root / "cert.pem", root / "key.pem"
        subprocess.run(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-days",
                "1",
                "-subj",
                "/CN=127.0.0.1",
                "-addext",
                "subjectAltName=IP:127.0.0.1",
                "-keyout",
                str(key),
                "-out",
                str(cert),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(4)
        listener.settimeout(6)
        requests, errors = [], []
        old = b'[{"tag_name":"v0.1.1","draft":false,"prerelease":false,"assets":[]}]'
        fresh = old.replace(b"v0.1.1", b"v0.1.2")
        count = {"reset": 4, "completed": 2, "uncached": 1}[mode]

        def server():
            try:
                for index in range(1, count + 1):
                    raw, _ = listener.accept()
                    raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    connection = context.wrap_socket(raw, server_side=True)
                    try:
                        request = b""
                        while b"\r\n\r\n" not in request:
                            chunk = connection.recv(4096)
                            assert chunk and len(request) < 16384
                            request += chunk
                        lines = request.split(b"\r\n")
                        assert lines[0] == b"GET /releases?per_page=20&page=1 HTTP/1.1"
                        headers = {
                            line.split(b":", 1)[0].lower(): line.split(b":", 1)[1].strip()
                            for line in lines[1:]
                            if b":" in line
                        }
                        assert (
                            b"authorization" not in headers
                            and b"proxy-authorization" not in headers
                        )
                        validator = headers.get(b"if-none-match", b"")
                        (root / f"wire-{index}-validator").write_bytes(validator)
                        requests.append(validator)
                        print(
                            f"{mode} wire request={index} If-None-Match={validator!r}", flush=True
                        )
                        if mode == "reset" and index == 2:
                            connection.sendall(
                                b'HTTP/1.1 304 Not Modified\r\nETag: "fixture-v2"\r\n'
                            )
                            # Deliver the headers before the genuine TCP reset, preserving status 304.
                            time.sleep(0.25)
                            connection.setsockopt(
                                socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)
                            )
                        elif mode == "uncached" or validator:
                            tag = b"fixture-v2" if mode == "reset" else b"fixture-v1"
                            connection.sendall(
                                b'HTTP/1.1 304 Not Modified\r\nETag: "'
                                + tag
                                + b'"\r\nConnection: close\r\n\r\n'
                            )
                        else:
                            body = old if index == 1 else fresh
                            tag = b"fixture-v1" if index == 1 else b"fixture-v2"
                            connection.sendall(
                                b'HTTP/1.1 200 OK\r\nETag: "'
                                + tag
                                + b'"\r\nContent-Length: '
                                + str(len(body)).encode()
                                + b"\r\nConnection: close\r\n\r\n"
                                + body
                            )
                    finally:
                        connection.close()
            except BaseException as error:
                errors.append(error)

        thread = threading.Thread(target=server, daemon=True)
        thread.start()
        env = os.environ.copy()
        env.update(
            HTTP_CONDITIONAL_ROOT=str(root),
            HTTP_CONDITIONAL_MODE=mode,
            HTTP_CONDITIONAL_ORIGIN="https://127.0.0.1:" + str(listener.getsockname()[1]),
            CURL_CA_BUNDLE=str(cert),
            no_proxy="127.0.0.1",
            NO_PROXY="127.0.0.1",
        )
        for name in ("CONFIG", "DATA", "CACHE", "STATE"):
            env[f"XDG_{name}_HOME"] = str(root / name.lower())
        try:
            run = subprocess.run(
                [
                    os.environ.get("ERGOPTI_HTTP_TEST_LUA", "luajit"),
                    str(pathlib.Path(__file__).with_name("updater_conditional_receipts.lua")),
                ],
                env=env,
                text=True,
                capture_output=True,
                timeout=15,
            )
            print(run.stdout, end="")
            print(run.stderr, end="")
            thread.join(7)
            assert not thread.is_alive() and not errors, errors
            assert len(requests) == count
            return run.returncode
        finally:
            listener.close()


def main():
    assert os.getuid() != 0
    os.umask(0o077)
    failures = sum(run_case(mode) != 0 for mode in ("reset", "completed", "uncached"))
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
