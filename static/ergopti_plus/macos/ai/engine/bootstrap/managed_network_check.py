# ai/engine/bootstrap/managed_network_check.py
"""One harmless HEAD request, then one verified download, through the managed chain.

The Debug menu's network check runs this helper with the interpreter the
driver already uses. It sends one HEAD request for the first pinned managed
input through the same signed native transport, route lookup and TLS trust as a
real download; when that answers, it downloads the input (about 3 MB) through
the same chain into a private scratch folder and checks its pinned SHA-256 and
size, as an installation does, then removes it. It prints one line per step on
stdout:

    step <id> <state> <value>

Every value comes from a closed vocabulary (a native failure stage or reason,
an HTTP status class); no URL, host, user name or PAC content is ever printed.

With --hosts it instead sends one HEAD to the root (or the probe path) of every external host the
drivers declare (_shared/core/text/data/identifiers.json), one after the other, and
prints one "step host_<name> <state> <value>" line each: the field run's
reachability check. A host is named by its declared key, never by its name.

With --ollama-blob <model> it reads that model's manifest from the Ollama
registry, then asks for one of its blobs without following the redirect, and
prints whether the host the registry sends the blob to is one the route
inventory plans (_shared/core/network/data/route_origins.json): the daemon's
pull is routed by that inventory, so an unplanned blob host would be fetched
on the wrong route. It then asks two bytes of that blob, following each
redirect the way the daemon does, and judges whether the final answer honours
Range. Only verdicts are printed, never a host or a digest.
"""

import importlib.util
import json
import re
import sys
import tempfile
import time
import urllib.parse
from pathlib import Path

DRIVER_ROOT = Path(__file__).resolve().parents[2]
SHARED_ROOT = DRIVER_ROOT.parent / "_shared"
RELEASE = SHARED_ROOT / "ai/data/managed_python_release.json"
IDENTIFIERS = SHARED_ROOT / "core/text/data/identifiers.json"
ROUTE_ORIGINS = SHARED_ROOT / "core/network/data/route_origins.json"
BOOTSTRAP = DRIVER_ROOT / "ai/engine/bootstrap/managed_bootstrap_http.py"

# Seconds for the whole request, then for each read.
TIMEOUT = 20.0
IDLE_TIMEOUT = 10.0

# Seconds for the verified download after the HEAD. With TIMEOUT it stays
# under the 40 s the field run gives this helper (adapters/field_check_ports.lua).
DIGEST_TIMEOUT = 15.0

# Seconds for one host's HEAD in --hosts mode; the field run bounds the sum.
HOST_TIMEOUT = 15.0


def emit(step, state, value):
    """Print one step line; a value outside the closed grammar is refused."""
    value = str(value)
    if not value or len(value) > 48 or not all(c.isalnum() or c in "_.:+-" for c in value):
        value = "redacted"
    print("step " + step + " " + state + " " + value, flush=True)


def load_bootstrap():
    specification = importlib.util.spec_from_file_location("_ergopti_network_check", BOOTSTRAP)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def route_step(fallback, kind=None):
    """The lookup verdict: no fallback means the native route was usable.

    A fallback is the policy of proxy_policy.json "pac_unavailable_fallback":
    the automatic configuration could not be used and the request went direct,
    so the step informs and the transfer step says whether direct worked.
    """
    if fallback is None:
        # The kind of route the lookup chose: a DIRECT it answered by itself
        # leaves no fallback stage (ledger L42). An older launcher names none.
        emit("route_lookup", "pass", "selected:" + kind if kind else "selected")
    else:
        emit("route_lookup", "info", "direct_" + fallback.removeprefix("native_"))


# The worker refuses the request before any route lookup or connection when the
# CA file or folder named by SSL_CERT_FILE or SSL_CERT_DIR cannot be read as
# certificates (ManagedCertificateAuthorities). That is not a TLS verdict.
CERTIFICATE_LOAD_STAGE = "native_certificate_load"


def failure_steps(failure):
    """The route, TLS and transfer lines of a request that raised.

    The field run of 2026-10-27 19:47 read "route_lookup pass selected" and
    "tls fail certificate" for a request the worker refused while loading the
    inherited trust variables: no lookup and no handshake had taken place.
    """
    reason = getattr(failure, "reason", "unavailable")
    native = getattr(failure, "native_diagnostic", None)
    if type(native) is dict and native.get("stage") == CERTIFICATE_LOAD_STAGE:
        emit("route_lookup", "skip", "not_reached")
        emit("tls", "fail", "ssl_cert_env")
        emit("transfer", "fail", reason)
        return
    route_step(getattr(failure, "native_route_fallback", None))
    emit(
        "tls",
        "fail" if reason == "certificate" else "skip",
        "certificate" if reason == "certificate" else "not_reached",
    )
    emit("transfer", "fail", reason)


def digest_step(bootstrap, source):
    """Download the pinned input through the chain and check its SHA-256 and size.

    Issue #101 follow-up (6): a HEAD proves the route and TLS, not that the
    bytes the chain delivers are the pinned ones (a company proxy that
    rewrites or truncates a download answers a HEAD normally).
    """
    try:
        with tempfile.TemporaryDirectory(prefix="ergopti-network-check-") as folder:
            bootstrap.download(
                source["url"],
                Path(folder) / "input",
                source["sha256"],
                source["bytes"],
                time.monotonic() + DIGEST_TIMEOUT,
                IDLE_TIMEOUT,
            )
    except bootstrap.BootstrapFailure as failure:
        emit("digest", "fail", "mismatch" if failure.reason == "integrity" else failure.reason)
        return
    except Exception as failure:
        emit("digest", "fail", getattr(failure, "reason", "unavailable"))
        return
    emit("digest", "pass", "sha256")


def main():
    bootstrap = load_bootstrap()
    source = json.loads(RELEASE.read_text(encoding="utf-8"))["source"]
    url = source["url"]
    reached = False
    try:
        with bootstrap._native_request(
            url,
            headers=(("Accept-Encoding", "identity"),),
            method="HEAD",
            timeout=TIMEOUT,
            idle_timeout=IDLE_TIMEOUT,
            direct=bootstrap._direct_route(url),
        ) as response:
            route_step(response.route_fallback, getattr(response, "route_kind", None))
            emit("tls", "pass", "trusted")
            emit(
                "transfer",
                "pass" if response.status < 400 else "fail",
                "http_" + str(response.status),
            )
            reached = response.status < 400
    except Exception as failure:
        failure_steps(failure)
    if reached:
        digest_step(bootstrap, source)
    else:
        emit("digest", "skip", "not_reached")


# The path a host is probed at when its root does not prove reachability: the
# Ollama registry answers 503 at its root (field run of 2026-10-30 20:51) and
# 200 or 401 at the registry API base, /v2/, whenever it is reachable.
PROBE_PATHS = {"ollama_registry": "v2/"}


def declared_hosts():
    """The declared external hosts as (key, probe URL), in key order."""
    hosts = json.loads(IDENTIFIERS.read_text(encoding="utf-8"))["hosts"]
    return [
        (key, "https://" + host + "/" + PROBE_PATHS.get(key, ""))
        for key, host in sorted(hosts.items())
    ]


def host_step(bootstrap, key, url):
    """One HEAD to a host's root: any HTTP answer below 500 proves the route and TLS."""
    step = "host_" + key
    try:
        with bootstrap._native_request(
            url,
            headers=(("Accept-Encoding", "identity"),),
            method="HEAD",
            timeout=HOST_TIMEOUT,
            idle_timeout=IDLE_TIMEOUT,
            direct=bootstrap._direct_route(url),
        ) as response:
            emit(step, "pass" if response.status < 500 else "fail", "http_" + str(response.status))
    except Exception as failure:
        emit(step, "fail", getattr(failure, "reason", "unavailable"))


def main_hosts():
    bootstrap = load_bootstrap()
    for key, url in declared_hosts():
        host_step(bootstrap, key, url)


# The manifest media types the registry serves a pull (the daemon asks for these).
MANIFEST_ACCEPT = (
    "application/vnd.docker.distribution.manifest.v2+json, "
    "application/vnd.oci.image.manifest.v1+json"
)

# A manifest is a few kilobytes; anything far larger is not one.
MANIFEST_MAX_BYTES = 1024 * 1024


def ollama_planned_hosts():
    """The registry origin and every host the route inventory plans for the daemon."""
    origins = json.loads(ROUTE_ORIGINS.read_text(encoding="utf-8"))["clients"]["ollama"]
    hosts = {origin.removeprefix("https://").rstrip("/").lower() for origin in origins}
    return origins[0].rstrip("/"), hosts


def model_path(model):
    """The registry repository path and tag of a catalogue model name."""
    name, _, tag = model.partition(":")
    return (name if "/" in name else "library/" + name), (tag or "latest")


def header(response, name):
    """One response header, case-insensitively, or None."""
    for key, value in response.headers:
        if key.lower() == name:
            return value
    return None


def read_bounded(response):
    body = b""
    while True:
        chunk = response.read()
        if not chunk:
            return body
        body += chunk
        if len(body) > MANIFEST_MAX_BYTES:
            raise ValueError("manifest too large")


REDIRECT_STATUSES = (301, 302, 303, 307, 308)

# Hops a ranged blob request follows, as many as Go's default client (and so
# the daemon's downloader) does before it gives up.
MAX_BLOB_REDIRECTS = 10


def blob_redirect_verdict(status, location, planned, origin="https://"):
    """The blob_host step for a blob answer: (state, value).

    A redirect may not leave the scheme of the URL that answered it: the
    registry is HTTPS, so its storage must be too.
    """
    if 200 <= status < 300:
        return "pass", "registry_served"
    if status not in REDIRECT_STATUSES:
        return "fail", "http_" + str(status)
    if not location:
        return "fail", "no_location"
    target = urllib.parse.urlsplit(location)
    if origin.lower().startswith("https:") and target.scheme.lower() != "https":
        return "fail", "not_https"
    return ("pass", "planned") if (target.hostname or "") in planned else ("fail", "unplanned_host")


# Two bytes past the start: an answer that ignores Range cannot pass by chance.
BLOB_RANGE_PROBE = "bytes=1-2"


def blob_range_verdict(status, content_range):
    """The blob_range step for a ranged blob answer: (state, value).

    The Ollama pull fetches its parts by range. "ignored" is information: the
    managed daemon skips to each part's offset, at the cost of the skipped bytes.
    """
    if status == 206:
        match = re.fullmatch(r"bytes 1-2/(\*|[0-9]+)", content_range or "")
        total = match.group(1).lstrip("0") if match else ""
        served = bool(match) and (total == "*" or len(total) > 1 or total >= "3")
        return ("pass", "honoured") if served else ("fail", "wrong_range")
    if status == 200:
        return "info", "ignored"
    return "fail", "http_" + str(status)


def request(bootstrap, url, method, headers):
    return bootstrap._native_request(
        url,
        headers=headers,
        method=method,
        timeout=HOST_TIMEOUT,
        idle_timeout=IDLE_TIMEOUT,
        direct=bootstrap._direct_route(url),
    )


def main_blob(model):
    bootstrap = load_bootstrap()
    registry, planned = ollama_planned_hosts()
    repository, tag = model_path(model)
    manifest_url = registry + "/v2/" + repository + "/manifests/" + tag
    try:
        with request(
            bootstrap,
            manifest_url,
            "GET",
            (("Accept", MANIFEST_ACCEPT), ("Accept-Encoding", "identity")),
        ) as response:
            if response.status != 200:
                emit("blob_manifest", "fail", "http_" + str(response.status))
                emit("blob_host", "skip", "no_manifest")
                return
            manifest = json.loads(read_bounded(response))
    except Exception as failure:
        emit("blob_manifest", "fail", getattr(failure, "reason", "unreadable"))
        emit("blob_host", "skip", "no_manifest")
        return
    digest = (manifest.get("config") or {}).get("digest")
    if not isinstance(digest, str) or not digest.startswith("sha256:"):
        emit("blob_manifest", "fail", "no_digest")
        emit("blob_host", "skip", "no_manifest")
        return
    emit("blob_manifest", "pass", "http_200")
    blob_url = registry + "/v2/" + repository + "/blobs/" + digest
    try:
        with request(bootstrap, blob_url, "HEAD", (("Accept-Encoding", "identity"),)) as response:
            location = header(response, "location")
            if location:
                location = urllib.parse.urljoin(blob_url, location)
            state, value = blob_redirect_verdict(response.status, location, planned)
    except Exception as failure:
        state, value = "fail", getattr(failure, "reason", "unavailable")
    emit("blob_host", state, value)
    if state != "pass":
        emit("blob_range", "skip", "no_blob")
        return
    try:
        state, value = ranged_blob_verdict(bootstrap, location or blob_url, planned)
    except Exception as failure:
        state, value = "fail", getattr(failure, "reason", "unavailable")
    emit("blob_range", state, value)


def ranged_blob_verdict(bootstrap, url, planned):
    """Ask two bytes of a blob, following its redirects, and judge the final answer.

    The registry answers a HEAD itself but sends a GET to its storage host
    (field run of 2026-11-03: blob_host registry_served, then a 307 to the
    GET). The daemon follows that redirect before it asks its ranges, so the
    probe follows it too; each hop must stay on HTTPS and a planned host.
    """
    for _ in range(MAX_BLOB_REDIRECTS + 1):
        with request(
            bootstrap, url, "GET", (("Range", BLOB_RANGE_PROBE), ("Accept-Encoding", "identity"))
        ) as response:
            status = response.status
            location = header(response, "location")
            content_range = header(response, "content-range")
            if status == 206 and blob_range_verdict(status, content_range) == ("pass", "honoured"):
                received = 0
                while True:
                    chunk = response.read(3 - received)
                    if not chunk:
                        break
                    received += len(chunk)
                    if received > 2:
                        return "fail", "wrong_length"
                if received != 2:
                    return "fail", "wrong_length"
        if status not in REDIRECT_STATUSES:
            return blob_range_verdict(status, content_range)
        target = urllib.parse.urljoin(url, location) if location else None
        state, value = blob_redirect_verdict(status, target, planned, url)
        if state != "pass":
            return state, value
        url = target
    return "fail", "too_many_redirects"


if __name__ == "__main__":
    arguments = sys.argv[1:]
    hosts_mode = arguments == ["--hosts"]
    blob_mode = len(arguments) == 2 and arguments[0] == "--ollama-blob"
    try:
        if hosts_mode:
            main_hosts()
        elif blob_mode:
            main_blob(arguments[1])
        else:
            main()
    except Exception:
        emit(
            "hosts" if hosts_mode else ("blob_host" if blob_mode else "transfer"),
            "fail",
            "internal",
        )
        sys.exit(1)
