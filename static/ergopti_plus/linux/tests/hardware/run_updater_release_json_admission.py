#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_updater_release_json_admission.py
"""Audit release JSON admission through verified native TLS/public updater checks."""

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
    with tempfile.TemporaryDirectory(prefix="ergopti-updater-json-audit-") as folder:
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
        import math

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
        base = json.dumps(
            {
                "tag_name": "v1.2.0",
                "body": "ordinary notes",
                "draft": False,
                "prerelease": False,
                "published_at": "2026-10-01T00:00:00Z",
                "assets": assets,
            },
            separators=(",", ":"),
        )

        def extra(value):
            return "[" + base[:-1] + ',"audit":' + value + "}]"

        cases = [
            ("unknown escape", extra(r'"\q"'), True),
            ("raw newline", extra('"a\nb"'), True),
            ("raw tab", extra('"a\tb"'), True),
            ("raw NUL", extra('"a\x00b"'), True),
            ("positive leading zero", extra("01"), True),
            ("negative leading zero", extra("-01"), True),
            ("trailing decimal point", extra("1."), True),
            ("leading zero exponent", extra("01e1"), True),
            ("lone high surrogate", extra(r'"\ud800"'), True),
            ("lone low surrogate", extra(r'"\udc00"'), True),
            ("nested lone high surrogate", extra(r'{"text":"\udbff"}'), True),
            ("nested lone low surrogate", extra(r'["\udfff"]'), True),
            ("positive nonfinite number", extra("1e999"), True),
            ("negative nonfinite number", extra("-1e999"), True),
            ("nested positive nonfinite", extra('{"count":1e999}'), True),
            ("nested negative nonfinite", extra("[-1e999]"), True),
            ("duplicate ignored field", "[" + base[:-1] + ',"audit":1,"audit":2}]', True),
            ("duplicate nested field", extra('{"x":1,"x":2}'), True),
            ("duplicate selected tag", "[" + base[:-1] + ',"tag_name":"v1.3.0"}]', True),
            ("duplicate assets", "[" + base[:-1] + ',"assets":' + json.dumps(assets) + "}]", True),
            (
                "duplicate asset name",
                "["
                + base.replace(
                    '"name":"ergopti-plus-linux.tar.gz"',
                    '"name":"obsolete","name":"ergopti-plus-linux.tar.gz"',
                )
                + "]",
                True,
            ),
            ("duplicate after null", extra('{"x":null,"x":2}'), True),
            ("ordinary release", "[" + base + "]", False),
            ("surrogate pair", extra(r'"\ud83d\ude00"'), False),
            ("literal unicode", extra(json.dumps("é漢字😀", ensure_ascii=False)), False),
            ("null ignored metadata", extra("null"), False),
            ("nested null metadata", extra('{"x":null}'), False),
            ("zero", extra("0"), False),
            ("negative zero", extra("-0"), False),
            ("fraction", extra("0.125"), False),
            ("finite exponent", extra("1e2"), False),
            ("escaped JSON delimiters", extra(json.dumps('[] {} \\ "')), False),
            ("structural whitespace", " \t[\n" + base + "\r]\n", False),
            (
                "higher release ordering",
                "[" + base + "," + base.replace("v1.2.0", "v1.3.0") + "]",
                False,
            ),
        ]
        assert len(cases) == 34

        def strict_object(pairs):
            value = {}
            for key, item in pairs:
                if key in value:
                    raise ValueError("duplicate key")
                value[key] = item
            return value

        def scalar_check(value):
            if isinstance(value, str):
                assert not any(0xD800 <= ord(c) <= 0xDFFF for c in value), "unpaired surrogate"
            elif isinstance(value, float):
                assert math.isfinite(value), "nonfinite number"
            elif isinstance(value, dict):
                for key, item in value.items():
                    scalar_check(key)
                    scalar_check(item)
            elif isinstance(value, list):
                for item in value:
                    scalar_check(item)

        for index, (label, body, expected_error) in enumerate(cases, 1):
            try:
                objects = json.loads(body, object_pairs_hook=strict_object)
                scalar_check(objects)
            except (ValueError, AssertionError) as error:
                assert expected_error, (label, error)
                oracle = str(error)
            else:
                assert not expected_error, (label, objects)
                assert objects[0]["tag_name"] == "v1.2.0" and objects[0]["assets"] == assets
                oracle = "accepted strict independent Python object/finite/scalar oracle"
            expected_tag = "v1.3.0" if label == "higher release ordering" else "v1.2.0"
            encoded = body.encode()
            (root / f"response-{index}.json").write_bytes(encoded)
            (root / f"expected-{index}.json").write_text(
                json.dumps({"error": expected_error, "tag": expected_tag, "label": label})
            )
            print(
                f"independent release JSON oracle case={index} label={label} verdict={oracle}",
                flush=True,
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
                    str(pathlib.Path(__file__).with_name("updater_release_json_admission.lua")),
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
            assert len(requests) == 34
        finally:
            listener.close()
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
