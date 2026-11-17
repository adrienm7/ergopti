# ai/engine/ollama/managed_ollama_proxy_relay.py
"""Decide the sign-in relay of the Swift-owned managed Ollama daemon.

docs/design/proxy-auth-relay.md, "macOS managed daemon". The serve owner asks the
relay's probe once it has captured the daemon's route and before it seals the
bootstrap snapshot, as run_with_proxy_sign_in_relay (network-retry.sh) does for
the stock daemon:

- a route that is not a plain http proxy, a relay that is not installed, or a
  proxy that needs no sign-in keep the snapshot as captured;
- "required" asks the suspended image guardian to start `listen` beside the
  daemon, and the snapshot's selected proxy becomes the relay's loopback route;
- a refusal (the probe's, or the guardian's of `listen`) writes its closed reason
  to the receipt the pull reads (ai/engine/api/proxy_relay_receipt.lua) and starts
  the daemon with no proxy at all, so the models on disk keep working.

Every line this module prints is "Managed Ollama proxy sign-in relay: EVENT
[WORD]." on stderr, fixed words only (ai/adapters/managed_ollama_daemon.lua logs
it): never the proxy, the registry, the token or a path.
"""

import importlib.util
import os
from pathlib import Path
import subprocess
import sys

SHARED = Path(__file__).absolute().parents[4] / "_shared"


def _load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


POLICY = _load(
    "ergopti_managed_relay_policy", SHARED / "core/network/adapters/python_proxy_auth_relay.py"
)
UNAVAILABLE = POLICY.UNAVAILABLE
# The closed refusals the guardian reports for `listen`
LISTEN_REFUSALS = frozenset(("relay_listen_failed", UNAVAILABLE))
LOG_PREFIX = "Managed Ollama proxy sign-in relay: "


class RelayOptions:
    """The caller's receipt path, registry authority and registry deadlines.

    Args:
        receipt: Absolute path of the refusal receipt, removed at each start.
        authority: The registry's CONNECT authority (HOST:443), from route_origins.json.
        dial_ms, handshake_ms, idle_ms, probe_ms: The timing registry's
            proxy_relay_* values, positive milliseconds.
    """

    def __init__(self, receipt, authority, dial_ms, handshake_ms, idle_ms, probe_ms):
        if (
            type(receipt) is not str
            or not receipt.startswith("/")
            or "\0" in receipt
            or any(part in ("", ".", "..") for part in receipt[1:].split("/"))
            or type(authority) is not str
            or not authority.endswith(":443")
            or POLICY.ProxyAuthRelay.authority("https://" + authority[:-4]) != authority
            or any(
                type(value) is not int or value <= 0
                for value in (dial_ms, handshake_ms, idle_ms, probe_ms)
            )
        ):
            raise ValueError("relay options")
        self.receipt, self.authority = receipt, authority
        self.timings = {"dial_ms": dial_ms, "handshake_ms": handshake_ms, "idle_ms": idle_ms}
        self.probe_seconds = probe_ms / 1000


class RelayDecision:
    """What the serve owner does with the captured snapshot.

    outcome: "keep" (unchanged), "required" (start listen; replace `name`) or
    "refused" (no proxy; `reason` is in the receipt).
    """

    def __init__(self, outcome, *, name=None, upstream=None, reason=None, sign_in=None):
        self.outcome, self.name, self.upstream, self.reason = outcome, name, upstream, reason
        # The Kerberos variables (KRB5CCNAME, KRB5_CONFIG) the guardian hands to
        # listen: it starts the relay with no inherited environment.
        self.sign_in = dict(sign_in or {})

    def request_fields(self, options):
        """The suspended image request's relay fields (ManagedProxyRelayRequest)."""
        if self.outcome != "required":
            return {}
        return {
            "relay_upstream": self.upstream,
            "relay_dial_ms": options.timings["dial_ms"],
            "relay_handshake_ms": options.timings["handshake_ms"],
            "relay_idle_ms": options.timings["idle_ms"],
            **({"relay_environment": dict(self.sign_in)} if self.sign_in else {}),
        }


def log(event, word=None):
    print(LOG_PREFIX + event + (" " + word if word else "") + ".", file=sys.stderr, flush=True)


def write_receipt(options, reason):
    """Record a closed refusal for the pull; a failed write is logged by name."""
    try:
        Path(options.receipt).parent.mkdir(parents=True, exist_ok=True)
        Path(options.receipt).write_text(reason + "\n", encoding="utf-8")
    except OSError:
        log("receipt_failed", reason)


def selected(environment, order):
    """The (name, value) the daemon's transport selects for https, or (None, None)."""
    values = dict(environment)
    for name in order:
        if values.get(name):
            return name, values[name]
    return None, None


def decide(
    options, environment, order, launcher, *, remaining=None, policy=None, run=subprocess.run
):
    """Probe the proxy the captured snapshot selects and decide the daemon's route.

    Args:
        options: RelayOptions.
        environment: The snapshot's captured [name, value] pairs.
        order: The policy's https environment precedence.
        launcher: The admitted launcher; the relay ships beside it.
        remaining: Seconds left of the serve owner's startup clock, which also
            bounds the probe; None for the registry's probe deadline alone.
        policy: A ProxyAuthRelay (test seam).
        run: subprocess.run (test seam).

    Returns:
        A RelayDecision.
    """
    policy = policy or POLICY.ProxyAuthRelay()
    # A receipt names the daemon of its own start, never a later one
    try:
        os.unlink(options.receipt)
    except FileNotFoundError:
        pass
    name, value = selected(environment, order)
    upstream = policy.upstream(value)
    if upstream is None:
        return RelayDecision("keep")
    relay = Path(launcher).parent / POLICY.EXECUTABLE_NAME
    if not relay.is_file() or relay.is_symlink() or not os.access(relay, os.X_OK):
        log("not_installed")
        return RelayDecision("keep")
    arguments = policy.probe_args(upstream, options.authority, options.timings)
    try:
        sign_in = policy.sign_in_values(os.environ)
    except POLICY.RelayPolicyError:
        return refuse(options, "invalid_arguments")
    try:
        result = run(
            [str(relay), *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=options.probe_seconds
            if remaining is None
            else min(options.probe_seconds, remaining),
            env={
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": os.environ.get("HOME", "/"),
                **sign_in,
            },
        )
        stdout = result.stdout.decode("utf-8", "replace")
        status, detail = policy.read_probe(result.returncode, stdout)
    except (OSError, subprocess.SubprocessError):
        status, detail = "refused", UNAVAILABLE
    if status == "not_needed":
        log("not_needed")
        return RelayDecision("keep")
    if status == "required":
        log("required", detail)
        return RelayDecision("required", name=name, upstream=upstream, sign_in=sign_in)
    return refuse(options, detail)


def refuse(options, reason):
    """The refused outcome: the receipt, one log line, a daemon without a proxy."""
    write_receipt(options, reason)
    log("refused", reason)
    return RelayDecision("refused", reason=reason)


def route(port, token, policy=None):
    """The loopback route the daemon's transport reads; never logged."""
    policy = policy or POLICY.ProxyAuthRelay()
    return "http://%s:%s@127.0.0.1:%d" % (policy.relay_user, token, port)
