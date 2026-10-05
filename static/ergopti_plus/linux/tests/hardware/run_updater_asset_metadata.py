#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_updater_asset_metadata.py
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
    with tempfile.TemporaryDirectory(prefix="ergopti-updater-asset-metadata-") as folder:
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
        listener.listen(8)
        listener.settimeout(6)
        origin = "https://127.0.0.1:" + str(listener.getsockname()[1])
        responses = []
        for index, label in enumerate(
            (None, "} x64", None, "[x64] {build}", 'quoted " ] } \\ metadata', None, None, None), 1
        ):
            assets = [
                {
                    "name": "ergopti-plus-linux.tar.gz",
                    "label": label,
                    "browser_download_url": origin + "/never-requested-bundle",
                },
                {
                    "name": "ergopti-plus-linux.tar.gz.sha256",
                    "label": None,
                    "browser_download_url": origin + "/never-requested-checksum",
                },
            ]
            if index == 3:
                assets.insert(0, {"name": "notes.txt", "label": "] metadata"})
            elif index == 6:
                assets[0] = {
                    "name": "ergopti-plus-linux.tar.gz",
                    "uploader": {"browser_download_url": origin + "/never-requested-wrong"},
                    "browser_download_url": origin + "/never-requested-bundle",
                }
            elif index == 7:
                assets.insert(
                    0,
                    {
                        "uploader": {
                            "name": "ergopti-plus-linux.tar.gz",
                            "browser_download_url": origin + "/never-requested-wrong",
                        },
                        "name": "notes.txt",
                        "browser_download_url": origin + "/never-requested-notes",
                    },
                )
            release = {
                "tag_name": "v1.2.0",
                "name": "Release 1.2.0",
                "draft": False,
                "prerelease": False,
                "body": "Normal release notes",
                "assets": assets,
                "published_at": "2026-10-01T00:00:00Z",
            }
            body = json.dumps([release], separators=(",", ":"))
            if index == 8:
                body = body.replace("/", r"\/")
            encoded = body.encode()
            (root / f"response-{index}.json").write_bytes(encoded)
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
                        print(f"owned TLS metadata wire case={index} {lines[0]!r}", flush=True)
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
            UPDATER_ASSET_ROOT=str(root),
            UPDATER_ASSET_ORIGIN=origin,
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
                    str(pathlib.Path(__file__).with_name("updater_asset_metadata.lua")),
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
