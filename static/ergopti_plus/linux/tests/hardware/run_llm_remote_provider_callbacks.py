#!/usr/bin/env python3
# tests/hardware/run_llm_remote_provider_callbacks.py
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
    if owner == "remote":
        return {
            "openai": {
                "model": "fixture-model",
                "messages": [{"role": "user", "content": "fixture prompt"}],
                "temperature": 0.25,
                "max_tokens": 40,
                "stream": False,
            },
            "anthropic": {
                "model": "fixture-model",
                "system": "",
                "messages": [{"role": "user", "content": "fixture prompt"}],
                "temperature": 0.25,
                "max_tokens": 40,
            },
            "gemini": {
                "systemInstruction": {"parts": [{"text": ""}]},
                "contents": [{"role": "user", "parts": [{"text": "fixture prompt"}]}],
                "generationConfig": {"temperature": 0.25, "maxOutputTokens": 40},
            },
        }[fmt]
    return {
        "openai": {
            "model": "fixture-model",
            "max_tokens": 40,
            "stream": False,
            "messages": [
                {"role": "system", "content": "fixture system"},
                {"role": "user", "content": "fixture prompt"},
            ],
        },
        "anthropic": {
            "model": "fixture-model",
            "max_tokens": 40,
            "system": "fixture system",
            "messages": [
                {
                    "role": "user",
                    "content": [{"type": "text", "text": "fixture prompt"}],
                }
            ],
        },
        "gemini": {
            "system_instruction": {"parts": [{"text": "fixture system"}]},
            "contents": [{"role": "user", "parts": [{"text": "fixture prompt"}]}],
            "generationConfig": {"maxOutputTokens": 40},
        },
    }[fmt]


def main():
    assert os.getuid() != 0
    os.umask(0o077)
    proof = pathlib.Path(__file__).parent
    expectations = {}
    for owner, cases in [
        (
            "remote",
            [
                "healthy",
                "chunk-string",
                "chunk-object",
                "terminal-string",
                "terminal-object",
                "terminal-throwing-object",
                "reentry-object",
                "reentry-throwing-object",
            ],
        ),
        ("vision", ["healthy", "terminal-string", "reentry-string"]),
    ]:
        for fmt in ["openai", "anthropic", "gemini"]:
            for case in cases:
                phases = ["primary", "retry"] + (
                    ["successor"] if case.startswith("reentry") else []
                )
                for phase in phases:
                    suffix = {
                        "openai": "/chat/completions",
                        "anthropic": "/messages",
                        "gemini": "/models/fixture-model:generateContent?key=owned-fixture-token",
                    }[fmt]
                    path = f"/{owner}/{fmt}/{case}/{phase}{suffix}"
                    expectations[path] = (owner, fmt)
    assert len(expectations) == 75
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
                        assert method == "POST" and version == "HTTP/1.1"
                        headers = dict(
                            (k.decode().lower(), v.strip().decode())
                            for k, v in (line.split(b":", 1) for line in lines[1:])
                        )
                        length = int(headers["content-length"])
                        assert 0 < length < 4096
                        while len(body) < length:
                            data = connection.recv(4096)
                            assert data
                            body += data
                        assert len(body) == length
                        owner, fmt = expectations[path]
                        assert json.loads(body) == expected_payload(owner, fmt), (
                            path,
                            body,
                        )
                        assert headers["content-type"] == "application/json"
                        if fmt == "openai":
                            assert headers["authorization"] == "Bearer owned-fixture-token"
                        elif fmt == "anthropic":
                            assert headers["x-api-key"] == "owned-fixture-token"
                            assert headers["anthropic-version"] == "2023-06-01"
                        else:
                            assert "authorization" not in headers and "x-api-key" not in headers
                        assert path not in requests
                        requests.append(path)
                        response = responses[fmt]
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
            LLM_CALLBACK_ORIGIN=origin,
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
                    str(proof / "llm_remote_provider_callbacks.lua"),
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
        assert len(requests) == 75 and set(requests) == set(expectations), len(requests)
        print("Owned verified TLS: 75 complete independently verified public provider POSTs")
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
