#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_updater_release_array_admission.py
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
    with tempfile.TemporaryDirectory(prefix="ergopti-updater-release-array-") as folder:
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
        for index in range(1, 12):
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

            def release(tag):
                return {
                    "tag_name": tag,
                    "body": 'Notes with [ ] { } and \\ " delimiters',
                    "draft": False,
                    "prerelease": False,
                    "published_at": "2026-10-01T00:00:00Z",
                    "assets": assets,
                }

            ordinary, nested = release("v1.2.0"), release("v9.9.9")
            objects = [ordinary]
            if index == 2:
                objects = [[ordinary]]
            elif index == 3:
                objects = [ordinary, [nested]]
            elif index == 7:
                objects = [False, ordinary]
            elif index == 8:
                ordinary = {"author": {"related_releases": [nested]}, **ordinary}
                objects = [ordinary]
            elif index == 9:
                objects = [[nested], ordinary]
            elif index == 10:
                objects = [[ordinary, nested]]
            elif index == 11:
                higher = release("v1.3.0")
                objects = [ordinary, higher]
            body = json.dumps(objects, separators=(",", ":"))
            if index == 4:
                body = body[:-1]
            elif index == 5:
                body += " " + json.dumps(nested, separators=(",", ":"))
            elif index == 6:
                body = body[:-1] + ",]"
            if index not in (4, 5, 6):
                assert json.loads(body) == objects
            else:
                try:
                    json.loads(body)
                except json.JSONDecodeError:
                    pass
                else:
                    raise AssertionError("malformed control unexpectedly valid")
            expected_error = index not in (1, 8, 11)
            expected_tag = "v1.3.0" if index == 11 else "v1.2.0"
            encoded = body.encode()
            (root / f"response-{index}.json").write_bytes(encoded)
            (root / f"expected-{index}.json").write_text(
                json.dumps({"error": expected_error, "tag": expected_tag})
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
                        print(f"owned TLS release-array wire case={index} {lines[0]!r}", flush=True)
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
            UPDATER_ARRAY_ROOT=str(root),
            UPDATER_ARRAY_ORIGIN=origin,
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
                    str(pathlib.Path(__file__).with_name("updater_release_array_admission.lua")),
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
            assert len(requests) == 11
        finally:
            listener.close()
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
