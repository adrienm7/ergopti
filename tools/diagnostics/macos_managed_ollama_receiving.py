# tools/diagnostics/macos_managed_ollama_receiving.py
"""Receive the actual source-built daemon, native routes, model and retirement.

The private TLS registry serves exact manifest/blob bytes produced by unchanged
upstream model creation. A separate empty default model store must pull those
bytes through the rebuilt daemon and run real native inference. No release,
global proxy setting, DNS override or fake CLI is involved.
"""

import argparse
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlsplit
import urllib.request
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
GGUF_SHA256 = "a85aba87b0e9e724d0b499d12d4dcb9fd2ede378c96ffad75a70a919f2c00c0a"


def require(condition, reason):
    if not condition:
        raise RuntimeError(reason)


def load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


class Registry:
    """Actual independently controlled TLS peer; all production clients are real."""

    def __init__(self, fixture):
        self.fixture = fixture
        self.manifest = None
        self.cancel_manifest = None
        self.blobs = {}
        self.held_digest = None
        # WireFixture creates a distinct handler class per instance. Replace
        # only this owned peer's HTTP payload, retaining its TLS/proxy/FD owners.
        handler = fixture.servers[0].RequestHandlerClass
        owner = self
        handler.do_GET = lambda request: owner.receive(request, False)
        handler.do_HEAD = lambda request: owner.receive(request, True)

    def set_model(self, manifest, blobs):
        self.manifest, self.blobs = manifest, dict(blobs)
        value = json.loads(manifest)
        models = [
            layer
            for layer in value["layers"]
            if layer["mediaType"] == "application/vnd.ollama.image.model"
        ]
        require(len(models) == 1, "actual_model_layer")
        original = blobs[models[0]["digest"]]
        require(
            len(original) == 51072 and hashlib.sha256(original).hexdigest() == GGUF_SHA256,
            "actual_model_bytes",
        )
        changed = original[:-1] + bytes([original[-1] ^ 1])
        self.held_digest = "sha256:" + hashlib.sha256(changed).hexdigest()
        self.blobs[self.held_digest] = changed
        models[0]["digest"] = self.held_digest
        self.cancel_manifest = json.dumps(value, separators=(",", ":")).encode()

    def pac(self):
        base = f"https://{self.fixture.host}:{self.fixture.origin_port}"
        selections = []
        for model in ("native-pulled", "native-cancel"):
            path = "/v2/library/" + model + "/manifests/latest"
            selections.extend(
                [
                    (base + path, f"PROXY 127.0.0.1:{self.fixture.ports['first']}"),
                    (
                        base + path + "?native=manifest",
                        f"PROXY 127.0.0.1:{self.fixture.ports['second']}",
                    ),
                ]
            )
            for blob in self.blobs:
                path = "/v2/library/" + model + "/blobs/" + blob
                selections.extend(
                    [
                        (
                            base + path,
                            f"PROXY 127.0.0.1:{self.fixture.ports['refused']}; PROXY 127.0.0.1:{self.fixture.ports['second']}",
                        ),
                        (
                            base + path + "?native=blob",
                            f"PROXY 127.0.0.1:{self.fixture.ports['second']}",
                        ),
                    ]
                )
        return (
            "function FindProxyForURL(url, host) { "
            + " ".join(
                "if (url == " + json.dumps(url) + ") return " + json.dumps(route) + ";"
                for url, route in selections
            )
            + f' return "PROXY 127.0.0.1:{self.fixture.ports["refused"]}"; }}'
        )

    def receive(self, request, head):
        fixture = self.fixture
        with fixture.lock:
            route = fixture.routes.get(request.client_address[1], "direct")
            fixture.records.append(
                {
                    "event": "origin",
                    "route": route,
                    "path": request.path,
                    "method": "HEAD" if head else "GET",
                }
            )
        parsed = urlsplit(request.path)
        manifest = re.fullmatch(
            r"/v2/library/(native-pulled|native-cancel)/manifests/latest", parsed.path
        )
        blob = re.fullmatch(
            r"/v2/library/(native-pulled|native-cancel)/blobs/(sha256:[a-f0-9]{64})", parsed.path
        )
        if manifest and not parsed.query:
            request.send_response(302)
            request.send_header(
                "Location",
                f"https://{fixture.host}:{fixture.origin_port}{parsed.path}?native=manifest",
            )
            request.send_header("Content-Length", "0")
            request.send_header("Connection", "close")
            request.end_headers()
            request.close_connection = True
            return
        if manifest and parsed.query == "native=manifest":
            payload = self.manifest if manifest[1] == "native-pulled" else self.cancel_manifest
            require(payload is not None, "peer_model_not_ready")
            self.respond(
                request, payload, head, "application/vnd.docker.distribution.manifest.v2+json"
            )
            return
        if blob and blob[2] in self.blobs:
            payload = self.blobs[blob[2]]
            bounds = request.headers.get("Range")
            start, end = 0, len(payload) - 1
            if bounds is not None:
                selected = re.fullmatch(r"bytes=([0-9]+)-([0-9]+)", bounds)
                if selected is None:
                    request.send_error(416)
                    return
                start, end = map(int, selected.groups())
                if not 0 <= start <= end < len(payload):
                    request.send_error(416)
                    return
            held = blob[2] == self.held_digest and bounds is not None and not head
            request.send_response(206 if bounds else 200)
            request.send_header("Content-Length", str(end - start + 1))
            request.send_header("Content-Type", "application/octet-stream")
            request.send_header(
                "Location", f"https://{fixture.host}:{fixture.origin_port}{parsed.path}?native=blob"
            )
            request.send_header("Connection", "close")
            if bounds:
                request.send_header("Content-Range", f"bytes {start}-{end}/{len(payload)}")
            request.end_headers()
            if not head:
                request.wfile.write(
                    payload[start : start + 1024] if held else payload[start : end + 1]
                )
                request.wfile.flush()
            if held:
                request.connection.settimeout(15)
                try:
                    closed = request.connection.recv(1) == b""
                except (ConnectionResetError, ssl.SSLEOFError):
                    closed = True
                except OSError:
                    closed = False
                with fixture.lock:
                    fixture.records.append({"event": "held_closed", "closed": closed})
            request.close_connection = True
            return
        request.send_error(404)

    @staticmethod
    def respond(request, payload, head, content_type):
        request.send_response(200)
        request.send_header("Content-Type", content_type)
        request.send_header("Content-Length", str(len(payload)))
        request.send_header("Connection", "close")
        request.end_headers()
        if not head:
            request.wfile.write(payload)
            request.wfile.flush()
        request.close_connection = True


class Receiver:
    def __init__(self, options):
        self.options = options
        self.root = options.repository.resolve(strict=True)
        self.mac = self.root / "static/ergopti_plus/macos"
        self.output = options.output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        # Private keys, daemon leases/model state and unfiltered logs never live
        # below the artifact directory, including when cleanup refuses.
        self.work = Path(tempfile.mkdtemp(prefix=".native-ollama-private-", dir=self.output.parent))
        os.chmod(self.work, 0o700)
        self.fixture = None
        self.daemon = None
        self.source_hashes = {}
        self.input_hashes = {
            name: digest(getattr(options, name)) for name in ("archive", "catalogue", "launcher")
        }
        self.stage = "prepare"
        self.receipt = {
            "version": 1,
            "profile": options.profile,
            "success": False,
            "private_children_retired": False,
            "native_trust_restored": False,
        }

    def own_command(self, arguments, environment, timeout=60):
        owner = None
        with tempfile.TemporaryFile() as output:

            def register(value):
                nonlocal owner
                owner = value

            try:
                self.fixture.groups.acquire_owned(
                    arguments,
                    self.fixture.native_groups,
                    register,
                    stdin=subprocess.DEVNULL,
                    stdout=output,
                    stderr=output,
                    env=environment,
                )
                owner.wait_for_exit(timeout)
                require(owner.process.returncode == 0, "actual_native_command")
                output.seek(0)
                return output.read(65536)
            finally:
                if owner is not None:
                    require(owner.settle(), "native_command_retirement")

    def copy_source(self, relative, destination):
        source = self.root / relative
        self.source_hashes[relative] = digest(source)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)

    def payload(self, app):
        payload = app / "Contents/Resources/static/ergopti_plus"
        relatives = [
            "_shared/modules/network/proxy_policy.json",
            "_shared/python/network_proxy_policy.py",
            "_shared/modules/llm/managed_ollama_runtime.json",
            "_shared/python/managed_ollama_runtime.py",
            "_shared/python/managed_ollama_pull.py",
            "_shared/modules/llm/managed_python_release.json",
            "macos/platform/network/native_http.py",
            "macos/platform/network/native_ollama_api.py",
            "macos/modules/llm/managed_bootstrap_http.py",
            "macos/modules/llm/managed_ollama_runtime.py",
            "macos/modules/llm/managed-python-release.sh",
            "macos/modules/llm/managed-python-downloads.json",
        ]
        for relative in relatives:
            self.copy_source("static/ergopti_plus/" + relative, payload / relative)
        catalogue = payload / "_shared/modules/llm/managed_ollama_release.json"
        shutil.copy2(self.options.catalogue, catalogue)
        return payload

    @staticmethod
    def worker_environment(app):
        binary = app / "Contents/MacOS/ErgoptiPlus"
        identity = binary.stat(follow_symlinks=False)
        return {
            "ERGOPTI_LAUNCHER_EXECUTABLE": str(binary),
            "ERGOPTI_LAUNCHER_DEVICE": str(identity.st_dev),
            "ERGOPTI_LAUNCHER_INODE": str(identity.st_ino),
        }

    def prepare(self):
        wire = load(
            "ollama_real_native_peers", self.mac / "tests/support/native_http_wire_fixture.py"
        )
        self.fixture = wire.WireFixture(native=True)
        self.registry = Registry(self.fixture)
        self.http_app = self.work / "OwnedOutgoingHTTP.app"
        self.api_app = self.work / "OwnedListenerAPI.app"
        self.http_payload = self.payload(self.http_app)
        self.api_payload = self.payload(self.api_app)
        http_binary = self.http_app / "Contents/MacOS/ErgoptiPlus"
        http_binary.parent.mkdir(parents=True)
        worker = self.work / "ManagedHTTPWorker.swift"
        main = self.work / "native_http_fixture_main.swift"
        self.copy_source(
            "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/ManagedHTTPWorker.swift", worker
        )
        self.copy_source(
            "static/ergopti_plus/macos/tests/support/native_http_fixture_main.swift", main
        )
        self.fixture._command(
            [
                "/usr/bin/xcrun",
                "swiftc",
                "-parse-as-library",
                str(worker),
                str(main),
                "-o",
                str(http_binary),
            ],
            timeout=90,
        )
        api_binary = self.api_app / "Contents/MacOS/ErgoptiPlus"
        api_binary.parent.mkdir(parents=True)
        shutil.copy2(self.options.launcher, api_binary)
        frameworks = self.api_app / "Contents/Frameworks"
        frameworks.mkdir()
        shutil.copytree(self.options.framework, frameworks / "Sparkle.framework", symlinks=True)
        for binary in (http_binary, api_binary):
            self.fixture._command(["/usr/bin/codesign", "--force", "--sign", "-", str(binary)])
            self.fixture._command(["/usr/bin/codesign", "--verify", "--strict", str(binary)])
        self.fixture.trust(True)
        self.home = self.work / "home"
        self.home.mkdir(mode=0o700)
        policy = load(
            "ollama_fixture_proxy_policy",
            self.http_payload / "_shared/python/network_proxy_policy.py",
        )
        environment = dict(os.environ)
        for name in policy.ProxyPolicy().system_lookup_environment_exclusions + (
            "no_proxy",
            "NO_PROXY",
            "OLLAMA_MODELS",
            "OLLAMA_HOST",
        ):
            environment.pop(name, None)
        environment["HOME"] = str(self.home)
        self.clean = environment
        self.http_environment = environment | self.worker_environment(self.http_app)
        self.api_environment = environment | self.worker_environment(self.api_app)
        self.settings = self.http_app / "Contents/Resources/fixture-proxy-settings.json"
        self.settings.write_text(
            json.dumps(
                {
                    "HTTPSEnable": 1,
                    "HTTPSProxy": "127.0.0.1",
                    "HTTPSPort": self.fixture.ports["first"],
                }
            )
        )
        self.runtime = load(
            "ollama_fixture_real_runtime",
            self.http_payload / "macos/modules/llm/managed_ollama_runtime.py",
        )
        archive = self.options.archive.resolve(strict=True)
        require(
            archive.name
            == json.loads(self.options.catalogue.read_bytes())["assets"][
                "macos-" + ("arm64" if os.uname().machine == "arm64" else "amd64")
            ]["filename"],
            "actual_archive_name",
        )

        class Asset(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                if self.path != "/" + archive.name:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Length", str(archive.stat().st_size))
                self.send_header("Connection", "close")
                self.end_headers()
                with archive.open("rb") as stream:
                    shutil.copyfileobj(stream, self.wfile, 65536)
                self.close_connection = True

        server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Asset)
        server.daemon_threads = True
        self.fixture.servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.fixture.started_servers.append(server)
        with patch.dict(os.environ, self.http_environment, clear=True):
            self.binary = self.runtime.install(
                time.monotonic() + 600,
                60,
                fixture_url=f"http://127.0.0.1:{server.server_address[1]}/{archive.name}",
                connect_timeout=30,
                minimum_bytes_per_second=1024,
            )
        self.api = load(
            "ollama_fixture_bound_api",
            self.api_payload / "macos/platform/network/native_ollama_api.py",
        )
        self.pull = load(
            "ollama_fixture_pull_owner", self.api_payload / "_shared/python/managed_ollama_pull.py"
        )
        self.receipt["asset_sha256"] = digest(archive)
        self.receipt["catalogue_sha256"] = digest(self.options.catalogue)
        self.receipt["source_hashes"] = self.source_hashes
        self.receipt["outgoing_worker_sha256"] = digest(http_binary)
        self.receipt["listener_worker_sha256"] = digest(api_binary)

    def start(self, producer=False):
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            self.port = reservation.getsockname()[1]
        with patch.dict(os.environ, self.http_environment, clear=True):
            self.session_path = Path(self.runtime.create_session(time.monotonic() + 60, self.port))
        environment = self.http_environment | {
            "OLLAMA_HOST": "127.0.0.1:" + str(self.port),
            "ERGOPTI_OLLAMA_NATIVE_HTTP": "1",
            "ERGOPTI_OLLAMA_NATIVE_SESSION": str(self.session_path),
            "ERGOPTI_OLLAMA_NETWORK_POLICY": str(
                self.http_payload / "_shared/modules/network/proxy_policy.json"
            ),
            "ERGOPTI_OLLAMA_NATIVE_HTTP_IDLE_TIMEOUT": "60",
        }
        if producer:
            environment["OLLAMA_MODELS"] = str(self.work / "producer-models")
        if self.options.profile == "explicit-proxy" and not producer:
            environment["https_proxy"] = f"http://127.0.0.1:{self.fixture.ports['first']}"
        self.daemon_log = (self.work / ("producer.log" if producer else "receiver.log")).open("xb")
        self.fixture.groups.acquire_owned(
            [str(self.binary), "serve"],
            self.fixture.native_groups,
            lambda owner: setattr(self, "daemon", owner),
            stdin=subprocess.DEVNULL,
            stdout=self.daemon_log,
            stderr=self.daemon_log,
            env=environment,
        )
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            require(self.daemon.process.poll() is None, "actual_daemon_start")
            try:
                with opener.open(
                    f"http://127.0.0.1:{self.port}/api/version", timeout=1
                ) as response:
                    require(json.load(response)["version"] == "0.24.0", "actual_daemon_version")
                    with patch.dict(os.environ, self.api_environment, clear=True):
                        self.owner()
                    return
            except (OSError, ValueError):
                time.sleep(0.1)
        raise RuntimeError("actual_daemon_readiness")

    def stop(self):
        if self.daemon is not None:
            require(self.daemon.settle(timeout=15), "actual_daemon_retirement")
            self.daemon = None
            self.daemon_log.close()

    def owner(self):
        session = self.runtime.POLICY.private_session(
            self.runtime.POLICY.metadata_bytes(self.session_path.read_bytes())
        )
        owner = self.pull.PullOwner(session, str(self.binary), self.api, 60, 65536)
        owner.admit(10)
        require(owner.listener["pid"] == self.daemon.process.pid, "actual_owned_daemon_listener")
        return owner

    def retirement(self, owner):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if owner.retirement(min(5, deadline - time.monotonic())):
                return
            time.sleep(0.05)
        raise RuntimeError("actual_operation_retirement")

    def run(self):
        self.prepare()
        self.stage = "create"
        model_source = "tools/diagnostics/ollama_native_tiny_gguf.py"
        self.source_hashes[model_source] = digest(self.root / model_source)
        model = load("ollama_fixture_tiny_gguf", self.root / model_source)
        gguf = self.work / "native.gguf"
        model.write(gguf)
        require(
            gguf.stat().st_size == 51072 and digest(gguf) == GGUF_SHA256, "independent_gguf_vector"
        )
        modelfile = self.work / "Modelfile"
        modelfile.write_text(
            f"FROM {gguf}\nPARAMETER num_predict 1\nPARAMETER num_ctx 64\nPARAMETER num_gpu 0\nPARAMETER temperature 0\n"
        )
        self.start(producer=True)
        environment = self.clean | {"OLLAMA_HOST": "127.0.0.1:" + str(self.port)}
        self.own_command(
            [str(self.binary), "create", "native-source", "-f", str(modelfile)], environment
        )
        manifests = list((self.work / "producer-models/manifests").rglob("latest"))
        require(len(manifests) == 1, "actual_created_manifest")
        manifest = manifests[0].read_bytes()
        value = json.loads(manifest)
        blobs = {}
        for layer in [value["config"], *value["layers"]]:
            path = self.work / "producer-models/blobs" / layer["digest"].replace(":", "-")
            data = path.read_bytes()
            require(
                len(data) == layer["size"]
                and "sha256:" + hashlib.sha256(data).hexdigest() == layer["digest"],
                "actual_created_blob",
            )
            blobs[layer["digest"]] = data
        self.stop()
        self.registry.set_model(manifest, blobs)
        self.fixture.pac = self.registry.pac()
        fields = {
            "ProxyAutoConfigEnable": 1,
            "ProxyAutoConfigURLString"
            if self.options.profile == "pac-url"
            else "ProxyAutoConfigJavaScript": self.fixture.pac_url
            if self.options.profile == "pac-url"
            else self.fixture.pac,
        }
        self.settings.write_text(json.dumps(fields))
        require(not (self.home / ".ollama/models").exists(), "empty_default_receiving_store")
        self.stage = "pull"
        self.start()
        model_name = f"{self.fixture.host}:{self.fixture.origin_port}/library/native-pulled:latest"
        rows = []
        with patch.dict(os.environ, self.api_environment, clear=True):
            owner = self.owner()
            require(owner.pull(model_name, rows.append), "actual_pull_success")
            require(owner.pending, "http_exit_is_not_daemon_ack")
            self.retirement(owner)
        require(not owner.pending, "actual_pull_retired")
        receiving = self.home / ".ollama/models"
        actual = list((receiving / "manifests").rglob("latest"))
        require(
            len(actual) == 1 and actual[0].read_bytes() == manifest, "exact_manifest_publication"
        )
        for name, data in blobs.items():
            require(
                (receiving / "blobs" / name.replace(":", "-")).read_bytes() == data,
                "exact_blob_publication",
            )
        self.stage = "inference"
        with patch.dict(os.environ, self.api_environment, clear=True):
            self.owner()
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/generate",
            method="POST",
            data=json.dumps(
                {
                    "model": model_name,
                    "prompt": "x",
                    "stream": False,
                    "options": {"num_predict": 1, "num_ctx": 64, "num_gpu": 0, "temperature": 0},
                }
            ).encode(),
            headers={"Content-Type": "application/json"},
        )
        with opener.open(request, timeout=60) as response:
            inference = json.load(response)
        require(
            inference.get("done") is True
            and inference.get("eval_count") == 1
            and type(inference.get("eval_duration")) is int
            and inference["eval_duration"] > 0,
            "actual_native_inference",
        )
        self.stage = "cancel"
        with patch.dict(os.environ, self.api_environment, clear=True):
            self.owner()
        cancel_name = f"{self.fixture.host}:{self.fixture.origin_port}/library/native-cancel:latest"
        cancellation_seen = False

        def cancel_after_actual_bytes(row):
            nonlocal cancellation_seen
            if row.get("digest") == self.registry.held_digest and row.get("completed", 0) > 0:
                cancellation_seen = True
                raise KeyboardInterrupt()

        with patch.dict(os.environ, self.api_environment, clear=True):
            cancellation = self.owner()
            try:
                cancellation.pull(cancel_name, cancel_after_actual_bytes, timeout=30)
            except KeyboardInterrupt:
                pass
            require(cancellation_seen and cancellation.pending, "actual_cancelled_body")
            self.retirement(cancellation)
        require(not cancellation.pending, "actual_cancelled_operation_retired")
        require(
            len(list((receiving / "manifests").rglob("latest"))) == 1,
            "cancel_does_not_publish_partial_model",
        )
        snapshot = self.fixture.stats()
        require(snapshot["active"] == 0, "actual_origin_and_proxy_sockets_retired")
        origins = [row for row in snapshot["records"] if row["event"] == "origin"]
        require(
            any(row["path"].endswith("?native=manifest") for row in origins),
            "actual_full_query_reached_origin",
        )
        routes = {row["route"] for row in origins}
        require(
            routes
            == ({"first"} if self.options.profile == "explicit-proxy" else {"first", "second"}),
            "actual_full_url_route_selection",
        )
        require(
            any(
                row.get("event") == "held_closed" and row.get("closed") is True
                for row in snapshot["records"]
            ),
            "actual_cancelled_tls_peer_closed",
        )
        self.receipt.update(
            manifest_sha256=hashlib.sha256(manifest).hexdigest(),
            model_sha256=GGUF_SHA256,
            blob_sha256={name: hashlib.sha256(data).hexdigest() for name, data in blobs.items()},
            progress_rows=len(rows),
            inference_eval_count=inference["eval_count"],
            native_pull_retired=True,
            native_cancel_retired=True,
            native_sockets=snapshot["active"],
            origin_requests=origins,
        )

    def close(self):
        self.stop()
        self.receipt["private_children_retired"] = True
        if self.fixture is not None:
            self.fixture.close()
            self.receipt["native_trust_restored"] = True
        for name, frozen in self.input_hashes.items():
            require(digest(getattr(self.options, name)) == frozen, "native_receiving_input_changed")
        self.receipt["input_hashes"] = self.input_hashes
        for relative, frozen in self.source_hashes.items():
            require(digest(self.root / relative) == frozen, "native_receiving_source_changed")
        # All private leases, generated account keys, CA keys and model files are
        # removed only after exact native process/group and trust retirement.
        shutil.rmtree(self.work)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--catalogue", type=Path, required=True)
    parser.add_argument("--launcher", type=Path, required=True)
    parser.add_argument("--framework", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repository", type=Path, default=ROOT)
    parser.add_argument(
        "--profile", choices=("pac-inline", "pac-url", "explicit-proxy"), required=True
    )
    options = parser.parse_args()
    require(sys.platform == "darwin", "genuine_macos_required")
    owner = Receiver(options)
    failure = None
    try:
        owner.run()
    except BaseException:
        failure = "native_receiving_failed"
        owner.receipt["failed_stage"] = owner.stage
    try:
        owner.close()
    except BaseException:
        failure = "native_receiving_cleanup_failed"
    owner.receipt["success"] = failure is None
    owner.receipt["reason"] = failure or "complete"
    with (owner.output / "native-receiving.json").open("x", encoding="utf-8") as output:
        json.dump(owner.receipt, output, indent=2, sort_keys=True)
        output.write("\n")
    return 0 if failure is None else 1


if __name__ == "__main__":
    raise SystemExit(main())
