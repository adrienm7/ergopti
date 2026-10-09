#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_updater_release_flags.py
"""Serve controlled valid release JSON to actual verified TLS/public updater checks."""

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
    with tempfile.TemporaryDirectory(prefix="ergopti-updater-release-flags-") as folder:
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
        listener.listen(10)
        listener.settimeout(6)
        origin = "https://127.0.0.1:" + str(listener.getsockname()[1])
        responses = []
        for index in range(1, 9):
            assets = [
                {
                    "name": "ergopti-plus-linux.tar.gz",
                    "browser_download_url": origin + "/never-requested-bundle",
                },
                {
                    "name": "ergopti-plus-linux.tar.gz.sha256",
                    "browser_download_url": origin + "/never-requested-checksum",
                },
            ]
            channel = "dev" if index in (2, 3) else "main"
            tag = "v0.0.0-dev.2" if channel == "dev" else "v1.2.0"
            release = {}
            if index in (4, 5, 6, 7):
                release["author"] = {"prerelease": True}
            release.update(
                {
                    "tag_name": tag,
                    "body": "Ordinary notes",
                    "draft": False,
                    "prerelease": channel == "dev",
                    "published_at": "2026-10-01T00:00:00Z",
                    "assets": assets,
                }
            )
            if index == 5:
                del release["prerelease"]
            elif index == 6:
                release["prerelease"] = None
            elif index == 7:
                release["prerelease"] = "true"
            elif index == 8:
                release["metadata"] = {"draft": True}
            body = json.dumps([release], separators=(",", ":"))
            if index == 3:
                body = body.replace('"prerelease":true', '"pre\\u0072elease":true')
            decoded = json.loads(body)
            expected = decoded[0].get("prerelease") is True
            encoded = body.encode()
            (root / f"response-{index}.json").write_bytes(encoded)
            (root / f"expected-{index}.json").write_text(
                json.dumps({"channel": channel, "tag": tag, "prerelease": expected})
            )
            responses.append(encoded)
        requests, errors = [], []

        def server():
            try:
                for index, body in enumerate(responses, 1):
                    raw, _ = listener.accept()
                    with context.wrap_socket(raw, server_side=True) as connection:
                        request = b""
                        while b"\r\n\r\n" not in request:
                            data = connection.recv(4096)
                            assert data and len(request) < 16384
                            request += data
                        lines = request.split(b"\r\n")
                        assert lines[0] == b"GET /releases?per_page=20&page=1 HTTP/1.1"
                        assert not any(
                            line.lower().startswith((b"authorization:", b"proxy-authorization:"))
                            for line in lines[1:]
                        )
                        requests.append(lines[0])
                        print(f"owned TLS release-flags wire case={index} {lines[0]!r}", flush=True)
                        connection.sendall(
                            b"HTTP/1.1 200 OK\r\nContent-Length: "
                            + str(len(body)).encode()
                            + b'\r\nETag: "fixture-'
                            + str(index).encode()
                            + b'"\r\nConnection: close\r\n\r\n'
                            + body
                        )
            except BaseException as error:
                errors.append(error)

        thread = threading.Thread(target=server, daemon=True)
        thread.start()
        env = os.environ.copy()
        env.update(
            UPDATER_FLAG_ROOT=str(root),
            UPDATER_FLAG_ORIGIN=origin,
            CURL_CA_BUNDLE=str(cert),
            no_proxy="127.0.0.1",
            NO_PROXY="127.0.0.1",
        )
        for name in ("CONFIG", "DATA", "CACHE", "STATE"):
            env[f"XDG_{name}_HOME"] = str(root / name.lower())
        try:
            result = subprocess.run(
                [
                    os.environ.get("ERGOPTI_HTTP_TEST_LUA", "luajit"),
                    str(pathlib.Path(__file__).with_name("updater_release_flags.lua")),
                ],
                env=env,
                text=True,
                capture_output=True,
                timeout=20,
            )
            print(result.stdout, end="")
            print(result.stderr, end="")
            thread.join(7)
            assert not thread.is_alive() and not errors, errors
            assert len(requests) == 8
        finally:
            listener.close()
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
