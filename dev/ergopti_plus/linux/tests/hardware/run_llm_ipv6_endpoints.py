#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_llm_ipv6_endpoints.py
"""Verify actual public provider IPv6 requests with independent owned TLS oracles."""

import json
import os
import pathlib
import re
import socket
import ssl
import subprocess
import tempfile
import threading
import urllib.parse


def main():
    os.umask(0o077)
    assert os.getuid() != 0
    proof = pathlib.Path(__file__).parent
    with tempfile.TemporaryDirectory(prefix="ergopti-ipv6-provider-") as folder:
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
                "subjectAltName=IP:127.0.0.1,IP:::1",
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
        listeners = []
        for family, address in [
            (socket.AF_INET, "127.0.0.1"),
            (socket.AF_INET6, "::1"),
        ]:
            listener = socket.socket(family)
            listener.bind((address, 0))
            listener.listen(16)
            listener.settimeout(0.1)
            listeners.append(listener)
        origins = [
            "https://127.0.0.1:" + str(listeners[0].getsockname()[1]),
            "https://[::1]:" + str(listeners[1].getsockname()[1]),
        ]
        formats = [
            ("openai_compat", "openai", "owned-fixture-token"),
            ("anthropic", "anthropic", "owned-fixture-token"),
            ("gemini", "gemini", "owned-fixture-token"),
            ("lmstudio", "openai", ""),
        ]
        expectations, vectors = {}, []
        for network, origin in [("ipv4", origins[0]), ("ipv6", origins[1])]:
            for provider, fmt, token in formats:
                model = "models/fixture-é" if fmt == "gemini" else "fixture-é"
                suffix = {
                    "openai": "/chat/completions",
                    "anthropic": "/messages",
                    "gemini": "/models/"
                    + urllib.parse.quote("fixture-é", safe="-._~")
                    + ":generateContent?key=owned-fixture-token",
                }[fmt]
                system, user = 'system "owned"\n', "fixture prompt é 😀"
                payload = {
                    "openai": {
                        "model": model,
                        "messages": [
                            {"role": "system", "content": system},
                            {"role": "user", "content": user},
                        ],
                        "temperature": 0.25,
                        "max_tokens": 40,
                        "stream": False,
                    },
                    "anthropic": {
                        "model": model,
                        "system": system,
                        "temperature": 0.25,
                        "max_tokens": 40,
                        "messages": [{"role": "user", "content": user}],
                    },
                    "gemini": {
                        "systemInstruction": {"parts": [{"text": system}]},
                        "contents": [{"role": "user", "parts": [{"text": user}]}],
                        "generationConfig": {
                            "temperature": 0.25,
                            "maxOutputTokens": 40,
                        },
                    },
                }[fmt]
                response = {
                    "openai": '{"choices":[{"message":{"content":"valid reply"}}]}',
                    "anthropic": '{"content":[{"type":"text","text":"valid reply"}]}',
                    "gemini": '{"candidates":[{"content":{"parts":[{"text":"valid reply"}]}}]}',
                }[fmt]
                prefix = "/case/" + network + "/" + provider + "/v1"
                path = prefix + suffix
                headers = {
                    "anthropic": {
                        "x-api-key": token,
                        "anthropic-version": "2023-06-01",
                    },
                    "gemini": {},
                    "openai": {"authorization": "Bearer " + token} if token else {},
                }[fmt]
                expectations[path] = {
                    "payload": payload,
                    "headers": headers,
                    "response": response,
                    "optional_auth": token == "",
                }
                vectors.append(
                    {
                        "name": network + " " + provider,
                        "provider": provider,
                        "model": model,
                        "token": token,
                        "base": origin + prefix + "/",
                        "response": response,
                    }
                )
        errors, requests, stop = [], [], threading.Event()

        def server(listener):
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
                        expected = expectations[path]
                        assert json.loads(body) == expected["payload"], (path, body)
                        for key, value in expected["headers"].items():
                            assert headers[key] == value
                        if expected["optional_auth"]:
                            assert "authorization" not in headers
                        reply = expected["response"].encode()
                        requests.append(
                            {
                                "path": path,
                                "body": body.decode(),
                                "headers_verified": True,
                            }
                        )
                        connection.sendall(
                            b"HTTP/1.1 200 OK\r\nContent-Length: "
                            + str(len(reply)).encode()
                            + b"\r\nConnection: close\r\n\r\n"
                            + reply
                        )
            except BaseException as error:
                errors.append(repr(error))

        threads = [
            threading.Thread(target=server, args=(listener,), daemon=True) for listener in listeners
        ]
        for thread in threads:
            thread.start()
        env = os.environ.copy()
        env.update(
            CURL_CA_BUNDLE=str(cert),
            NO_PROXY="*",
            no_proxy="*",
            AUDIT_VECTORS=json.dumps(vectors),
        )
        for name in ("CONFIG", "DATA", "CACHE", "STATE"):
            env["XDG_" + name + "_HOME"] = str(root / name.lower())
        for v in vectors[4:]:
            fmt = next(fmt for provider, fmt, _ in formats if provider == v["provider"])
            suffix = {
                "openai": "/chat/completions",
                "anthropic": "/messages",
                "gemini": "/models/fixture-%C3%A9:generateContent?key=owned-fixture-token",
            }[fmt]
            url = v["base"].rstrip("/") + suffix
            expected = expectations[
                urllib.parse.urlsplit(url).path
                + (
                    "?" + urllib.parse.urlsplit(url).query
                    if urllib.parse.urlsplit(url).query
                    else ""
                )
            ]
            command = [
                "curl",
                "--silent",
                "--show-error",
                "--max-time",
                "5",
                "--cacert",
                str(cert),
                "--header",
                "Content-Type: application/json",
                "--data-binary",
                json.dumps(expected["payload"]),
            ]
            for key, value in expected["headers"].items():
                command.extend(["--header", key + ": " + value])
            command.append(url)
            result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=7)
            assert result.returncode == 0 and result.stdout == v["response"], result.stderr
            print("Native curl IPv6 verified TLS control PASS " + v["provider"])
        try:
            result = subprocess.run(
                [
                    os.environ.get("ERGOPTI_HTTP_TEST_LUA", "luajit"),
                    str(proof / "llm_ipv6_endpoints.lua"),
                ],
                env=env,
                text=True,
                capture_output=True,
                timeout=20,
            )
            print(result.stdout, end="")
            print(result.stderr, end="")
        finally:
            stop.set()
            for thread in threads:
                thread.join(6)
            for listener in listeners:
                listener.close()
        assert not errors and not any(thread.is_alive() for thread in threads), errors
        native_counts = re.findall(r"^Native curl children: (\d+)$", result.stdout, re.MULTILINE)
        assert len(native_counts) == 1
        native_children = int(native_counts[0])
        assert native_children in (4, 8), native_children
        assert len(requests) == 4 + native_children, requests
        assert len({r["path"] for r in requests[4:]}) == native_children
        output_path = os.environ.get("ERGOPTI_IPV6_TEST_RECEIPT")
        if output_path:
            pathlib.Path(output_path).write_text(
                json.dumps(requests, ensure_ascii=False, indent=2) + "\n"
            )
        print(
            "Native verified TLS: 4 IPv6 curl controls + "
            + str(native_children)
            + " complete public provider POSTs"
        )
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
