# modules/llm/managed_network_check.py
"""One harmless HEAD request through the managed download chain.

The Debug menu's network check runs this helper with the interpreter the
driver already uses. It sends one HEAD request for the first pinned managed
input through the same signed native transport, route lookup and TLS trust as a
real download, then prints one line per step on stdout:

    step <id> <state> <value>

Every value comes from a closed vocabulary (a native failure stage or reason,
an HTTP status class); no URL, host, user name or PAC content is ever printed.
"""

import importlib.util
import json
import sys
from pathlib import Path

DRIVER_ROOT = Path(__file__).resolve().parents[2]
SHARED_ROOT = DRIVER_ROOT.parent / "_shared"
RELEASE = SHARED_ROOT / "modules/llm/managed_python_release.json"
BOOTSTRAP = DRIVER_ROOT / "modules/llm/managed_bootstrap_http.py"

# Seconds for the whole request, then for each read.
TIMEOUT = 20.0
IDLE_TIMEOUT = 10.0


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


def route_step(fallback):
    """The lookup verdict: no fallback means the native route was usable.

    A fallback is the policy of proxy_policy.json "pac_unavailable_fallback":
    the automatic configuration could not be used and the request went direct,
    so the step informs and the transfer step says whether direct worked.
    """
    if fallback is None:
        emit("route_lookup", "pass", "selected")
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


def main():
    bootstrap = load_bootstrap()
    url = json.loads(RELEASE.read_text(encoding="utf-8"))["source"]["url"]
    try:
        with bootstrap._native_request(
            url,
            headers=(("Accept-Encoding", "identity"),),
            method="HEAD",
            timeout=TIMEOUT,
            idle_timeout=IDLE_TIMEOUT,
            direct=bootstrap._direct_route(url),
        ) as response:
            route_step(response.route_fallback)
            emit("tls", "pass", "trusted")
            emit(
                "transfer",
                "pass" if response.status < 400 else "fail",
                "http_" + str(response.status),
            )
    except Exception as failure:
        failure_steps(failure)
    emit("digest", "skip", "head_only")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        emit("transfer", "fail", "internal")
        sys.exit(1)
