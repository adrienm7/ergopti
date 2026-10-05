#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_llm_response_errors.py
"""Serve owned verified TLS responses to the native public LLM provider caller."""

import json
import os
import pathlib
import socket
import ssl
import subprocess
import tempfile
import threading


def main():
    assert os.getuid() != 0
    os.umask(0o077)
    runtime = os.environ.get("ERGOPTI_HTTP_TEST_LUA", "luajit")
    vectors = json.loads(
        subprocess.check_output(
            [
                runtime,
                "-e",
                'io.write(require("json").encode(require("test.response_error_contract").vectors))',
            ]
        )
    )
    assert len(vectors) == 23
    with tempfile.TemporaryDirectory(prefix="ergopti-llm-response-") as folder:
        root = pathlib.Path(folder)
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
        listener.listen(16)
        listener.settimeout(6)
        origin = "https://127.0.0.1:" + str(listener.getsockname()[1])
        errors, requests = [], []
        for index, vector in enumerate(vectors, 1):
            (root / f"response-{index}.json").write_bytes(vector["body"].encode())

        def server():
            try:
                for index, vector in enumerate(vectors, 1):
                    raw, _ = listener.accept()
                    with context.wrap_socket(raw, server_side=True) as connection:
                        request = b""
                        while b"\r\n\r\n" not in request:
                            data = connection.recv(4096)
                            assert data and len(request) < 16384
                            request += data
                        headers, body = request.split(b"\r\n\r\n", 1)
                        lines = headers.split(b"\r\n")
                        lengths = [
                            int(line.split(b":", 1)[1])
                            for line in lines
                            if line.lower().startswith(b"content-length:")
                        ]
                        assert len(lengths) == 1 and lengths[0] < 4096
                        while len(body) < lengths[0]:
                            body += connection.recv(4096)
                        assert len(body) == lengths[0]
                        suffix = {
                            "openai": "/chat/completions",
                            "anthropic": "/messages",
                            "gemini": "/models/fixture-model:generateContent?key=owned-fixture-token",
                        }[vector["format"]]
                        assert lines[0] == f"POST /case/{index}{suffix} HTTP/1.1".encode()
                        sent = json.loads(body)
                        assert sent.get("model", "fixture-model") == "fixture-model"
                        assert b"fixture prompt" in body
                        requests.append(lines[0])
                        response = vector["body"].encode()
                        connection.sendall(
                            b"HTTP/1.1 200 OK\r\nContent-Length: "
                            + str(len(response)).encode()
                            + b"\r\nConnection: close\r\n\r\n"
                            + response
                        )
            except BaseException as error:
                errors.append(error)

        thread = threading.Thread(target=server, daemon=True)
        thread.start()
        env = os.environ.copy()
        env.update(
            LLM_RESPONSE_ORIGIN=origin,
            LLM_RESPONSE_ROOT=str(root),
            CURL_CA_BUNDLE=str(cert),
            no_proxy="127.0.0.1",
            NO_PROXY="127.0.0.1",
        )
        for name in ("CONFIG", "DATA", "CACHE", "STATE"):
            env[f"XDG_{name}_HOME"] = str(root / name.lower())
        try:
            result = subprocess.run(
                [
                    runtime,
                    str(pathlib.Path(__file__).with_name("llm_response_errors.lua")),
                ],
                env=env,
                text=True,
                capture_output=True,
                timeout=25,
            )
            print(result.stdout, end="")
            print(result.stderr, end="")
            thread.join(7)
            assert not thread.is_alive() and not errors, errors
            assert len(requests) == 23
            print("Owned verified TLS: 23 complete public provider POSTs")
        finally:
            listener.close()
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
