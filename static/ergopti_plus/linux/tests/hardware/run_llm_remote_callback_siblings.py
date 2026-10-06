#!/usr/bin/env python3
# tests/hardware/run_llm_remote_callback_siblings.py
"""Owned verified TLS callback audit; independent request/response oracles."""

import json
import os
import pathlib
import socket
import ssl
import subprocess
import tempfile
import threading


def expected_payload(owner, fmt):
    assert owner == "test"
    return {
        "openai": {
            "model": "fixture-model",
            "messages": [
                {
                    "role": "system",
                    "content": "You are a connectivity probe. Reply with exactly: OK",
                },
                {"role": "user", "content": "ping"},
            ],
            "temperature": 0,
            "max_tokens": 16,
            "stream": False,
        },
        "anthropic": {
            "model": "fixture-model",
            "system": "You are a connectivity probe. Reply with exactly: OK",
            "messages": [{"role": "user", "content": "ping"}],
            "temperature": 0,
            "max_tokens": 16,
        },
        "gemini": {
            "systemInstruction": {
                "parts": [{"text": "You are a connectivity probe. Reply with exactly: OK"}]
            },
            "contents": [{"role": "user", "parts": [{"text": "ping"}]}],
            "generationConfig": {"temperature": 0, "maxOutputTokens": 16},
        },
    }[fmt]


def main():
    assert os.getuid() != 0
    os.umask(0o077)
    proof = pathlib.Path(__file__).parent
    expectations = {}
    specs = [
        ("models", "lmstudio", "openai", ""),
        ("models", "openai_compat", "openai", "owned-fixture-token"),
        ("test", "openai_compat", "openai", "owned-fixture-token"),
        ("test", "anthropic", "anthropic", "owned-fixture-token"),
        ("test", "gemini", "gemini", "owned-fixture-token"),
    ]
    for owner, provider, fmt, token in specs:
        for case in [
            "healthy",
            "string",
            "object",
            "throwing-object",
            "reentry-object",
            "reentry-throwing-object",
        ]:
            for phase in ["primary", "retry"] + (
                ["successor"] if case.startswith("reentry") else []
            ):
                suffix = (
                    "/models"
                    if owner == "models"
                    else {
                        "openai": "/chat/completions",
                        "anthropic": "/messages",
                        "gemini": "/models/fixture-model:generateContent?key=owned-fixture-token",
                    }[fmt]
                )
                expectations[f"/{owner}/{provider}/{case}/{phase}{suffix}"] = (
                    owner,
                    fmt,
                    token,
                )
    assert len(expectations) == 70
    responses = {
        "openai": b'{"choices":[{"message":{"content":"valid reply"}}]}',
        "anthropic": b'{"content":[{"type":"text","text":"valid reply"}]}',
        "gemini": b'{"candidates":[{"content":{"parts":[{"text":"valid reply"}]}}]}',
    }
    with tempfile.TemporaryDirectory(prefix="ergopti-callback-audit-") as folder:
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
                "/CN=owned-loopback",
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
        listener.settimeout(0.1)
        origin = "https://127.0.0.1:" + str(listener.getsockname()[1])
        errors, requests, stop = [], [], threading.Event()

        def server():
            try:
                while not stop.is_set():
                    try:
                        raw, _ = listener.accept()
                    except socket.timeout:
                        continue
                    raw.settimeout(5)
                    with context.wrap_socket(raw, server_side=True) as connection:
                        request = b""
                        while b"\r\n\r\n" not in request:
                            data = connection.recv(4096)
                            assert data and len(request) < 16384
                            request += data
                        header, body = request.split(b"\r\n\r\n", 1)
                        lines = header.split(b"\r\n")
                        method, path, version = lines[0].decode().split(" ")
                        assert version == "HTTP/1.1"
                        headers = dict(
                            (k.decode().lower(), v.strip().decode())
                            for k, v in (line.split(b":", 1) for line in lines[1:])
                        )
                        owner, fmt, token = expectations[path]
                        if owner == "models":
                            assert (
                                method == "GET" and body == b"" and "content-length" not in headers
                            )
                        else:
                            assert method == "POST"
                            length = int(headers["content-length"])
                            assert 0 < length < 4096
                            while len(body) < length:
                                data = connection.recv(4096)
                                assert data
                                body += data
                            assert len(body) == length
                            assert json.loads(body) == expected_payload(owner, fmt), (
                                path,
                                body,
                            )
                        assert headers["content-type"] == "application/json"
                        if fmt == "openai":
                            if token:
                                assert headers["authorization"] == "Bearer " + token
                            else:
                                assert "authorization" not in headers
                        elif fmt == "anthropic":
                            assert headers["x-api-key"] == "owned-fixture-token"
                            assert headers["anthropic-version"] == "2023-06-01"
                        else:
                            assert "authorization" not in headers and "x-api-key" not in headers
                        assert path not in requests
                        requests.append(path)
                        response = (
                            b'{"data":[{"id":"fixture-model"}]}'
                            if owner == "models"
                            else responses[fmt]
                        )
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
            LLM_WRAPPER_ORIGIN=origin,
            CURL_CA_BUNDLE=str(cert),
            no_proxy="127.0.0.1",
            NO_PROXY="127.0.0.1",
        )
        for name in ("CONFIG", "DATA", "CACHE", "STATE"):
            env[f"XDG_{name}_HOME"] = str(root / name.lower())
        try:
            result = subprocess.run(
                [
                    env.get("ERGOPTI_HTTP_TEST_LUA", "luajit"),
                    str(proof / "llm_remote_callback_siblings.lua"),
                ],
                env=env,
                capture_output=True,
                text=True,
                timeout=40,
            )
            print(result.stdout, end="")
            print(result.stderr, end="")
        finally:
            stop.set()
            thread.join(6)
            listener.close()
        assert not thread.is_alive() and not errors, errors
        assert len(requests) == 70 and set(requests) == set(expectations), len(requests)
        print("Owned verified TLS: 70 complete independently verified public wrapper requests")
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
