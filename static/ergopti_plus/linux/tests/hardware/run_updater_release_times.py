#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_updater_release_times.py
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
    with tempfile.TemporaryDirectory(prefix="ergopti-updater-release-times-") as folder:
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
        for index in range(1, 13):
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

            def release(tag, at):
                return {
                    "tag_name": tag,
                    "body": "Ordinary notes",
                    "draft": False,
                    "prerelease": tag.endswith("dev.2"),
                    "published_at": at,
                    "assets": assets,
                }

            installed = release("v1.0.0", "2026-10-01T00:00:00Z")
            latest = release("v1.2.0", "2026-10-02T00:00:00Z")
            other_at = "2026-10-03T00:00:00Z" if index in (4, 5) else "2026-09-30T00:00:00Z"
            other = release("v0.0.0-dev.2", other_at)
            if index == 3:
                installed = {"author": {"published_at": "2026-09-29T00:00:00Z"}, **installed}
            if index == 8:
                latest["published_at"] = 123
            elif index == 9:
                latest = {"author": {"published_at": "2026-09-29T00:00:00Z"}, **latest}
            elif index == 10:
                latest["published_at"] = None
            elif index == 12:
                other_at = "2026-10-01T00:00:00Z"
                other["published_at"] = other_at
            body = json.dumps([installed, latest, other], separators=(",", ":"))
            if index == 2:
                body = body.replace(
                    '"published_at":"2026-10-01T00:00:00Z"',
                    '"published_at":"2026-10-0\\u0031T00:00:00Z"',
                )
            elif index == 4:
                body = body.replace(
                    '"published_at":"2026-10-03T00:00:00Z"',
                    '"published_at":"2026-10-0\\u0033T00:00:00Z"',
                )
            elif index == 6:
                body = body.replace(
                    '"published_at":"2026-10-02T00:00:00Z"',
                    '"published_at":"2026-10-0\\u0032T00:00:00Z"',
                )
            elif index == 7:
                body = body.replace(
                    '"published_at":"2026-10-02T00:00:00Z"',
                    '"published_\\u0061t":"2026-10-02T00:00:00Z"',
                )
            decoded = json.loads(body)
            assert decoded[0]["published_at"] == "2026-10-01T00:00:00Z"
            expected_at = "" if index in (8, 10) else "2026-10-02T00:00:00Z"
            if index not in (8, 10):
                assert decoded[1]["published_at"] == expected_at
            else:
                assert not isinstance(decoded[1]["published_at"], str)
            assert decoded[2]["published_at"] == other_at
            expected_others = [{"channel": "dev", "tag": "v0.0.0-dev.2"}] if index in (4, 5) else []
            encoded = body.encode()
            (root / f"response-{index}.json").write_bytes(encoded)
            (root / f"expected-{index}.json").write_text(
                json.dumps(
                    {
                        "others": expected_others,
                        "published_at": expected_at,
                        "current": "1.2.0" if index == 11 else "1.0.0",
                        "available": index != 11,
                        "state": "up_to_date" if index == 11 else "available",
                    }
                )
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
                        print(f"owned TLS release-times wire case={index} {lines[0]!r}", flush=True)
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
            UPDATER_TIME_ROOT=str(root),
            UPDATER_TIME_ORIGIN=origin,
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
                    str(pathlib.Path(__file__).with_name("updater_release_times.lua")),
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
            assert len(requests) == 12
        finally:
            listener.close()
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
