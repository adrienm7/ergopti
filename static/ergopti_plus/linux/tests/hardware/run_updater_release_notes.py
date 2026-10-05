#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_updater_release_notes.py
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
    with tempfile.TemporaryDirectory(prefix="ergopti-updater-release-notes-") as folder:
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
        listener.listen(12)
        listener.settimeout(6)
        origin = "https://127.0.0.1:" + str(listener.getsockname()[1])
        responses = []
        notes = [
            "Ordinary release notes",
            "Line 1\nLine 2",
            "Literal \\n example",
            "Literal \\r example",
            "Trailing slash\\",
            "Tab\tseparated",
            "Unicode α 😀",
            'He said "hello" to me',
            "",
            "Line 1\r\nLine 2\rEnd",
            "Actual release notes",
            "Actual release notes",
        ]
        for index, note in enumerate(notes, 1):
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
            release = {
                "tag_name": "v1.2.0",
                "name": "Release 1.2.0",
                "draft": False,
                "prerelease": False,
            }
            if index in (11, 12):
                release["metadata"] = {"body": "Misleading nested notes" if index == 11 else None}
            release.update({"body": note, "assets": assets, "published_at": "2026-10-01T00:00:00Z"})
            encoded = json.dumps([release], separators=(",", ":")).encode()
            expected_notes = "Line 1\nLine 2End" if index == 10 else note
            (root / f"response-{index}.json").write_bytes(encoded)
            (root / f"expected-notes-{index}").write_bytes(expected_notes.encode())
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
                        print(f"owned TLS release-notes wire case={index} {lines[0]!r}", flush=True)
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
            UPDATER_NOTES_ROOT=str(root),
            UPDATER_NOTES_ORIGIN=origin,
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
                    str(pathlib.Path(__file__).with_name("updater_release_notes.lua")),
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
