# platform/network/managed_http.py
"""Join Hugging Face's actual HTTPX client to the owned native HTTP worker."""

import importlib.util
import os
from pathlib import Path
import threading
import time

import httpx


def _load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError("Managed network source is unavailable")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


_ROOT = Path(__file__).absolute().parents[2]
Native = _load("ergopti_native_http", Path(__file__).with_name("native_http.py"))
Policy = _load("ergopti_proxy_policy", _ROOT.parent / "_shared/python/network_proxy_policy.py")


def _failure(error, request):
    message = "Managed network request failed: " + error.reason
    if error.reason == "deadline":
        return httpx.ReadTimeout(message, request=request)
    if error.reason == "proxy":
        return httpx.ProxyError(message, request=request)
    return httpx.ConnectError(message, request=request)


class _NativeStream(httpx.SyncByteStream):
    def __init__(self, response, request, retired):
        self.response = response
        self.request = request
        self.retired = retired
        self.closed = False

    def __iter__(self):
        try:
            while True:
                data = self.response.read()
                if not data:
                    break
                yield data
        except Native.NativeHTTPError as error:
            raise _failure(error, self.request) from None

    def close(self):
        if not self.closed:
            self.response.close()
            self.closed = True
            self.retired(self)


class ManagedHTTPTransport(httpx.BaseTransport):
    """Select the route for each actual HTTPX request, including every redirect."""

    def __init__(self, idle_timeout):
        if not Native._positive_timeout(idle_timeout):
            raise Native.NativeHTTPError("protocol")
        self.policy = Policy.ProxyPolicy()
        self.idle_timeout = idle_timeout
        self.lock = threading.RLock()
        self.active = set()
        self.explicit = {}
        self.closed = False

    def _retired(self, stream):
        with self.lock:
            self.active.discard(stream)

    def handle_request(self, request):
        if request.extensions.get("ergopti_managed_https_seen") and request.url.scheme != "https":
            raise httpx.UnsupportedProtocol(
                "Managed HTTPS redirects cannot downgrade transport security", request=request
            )
        if request.url.scheme == "https":
            # Actual HTTPX copies request extensions into each redirect request.
            # Enforce before explicit/native selection, never after HTTP contact.
            request.extensions["ergopti_managed_https_seen"] = True
        with self.lock:
            if self.closed:
                raise httpx.ConnectError("Managed network transport is closed", request=request)
        try:
            mode, relay = self.policy.route(str(request.url), dict(os.environ))
        except Policy.ProxyPolicyError:
            raise httpx.ProxyError("Managed network policy is invalid", request=request) from None
        if mode == "environment":
            with self.lock:
                if self.closed:
                    raise httpx.ConnectError("Managed network transport is closed", request=request)
                transport = self.explicit.get(relay)
                if transport is None:
                    if len(self.explicit) >= self.policy.maximum_selections:
                        raise httpx.ProxyError(
                            "Managed network relay limit is exhausted", request=request
                        )
                    try:
                        transport = httpx.HTTPTransport(proxy=relay, trust_env=False)
                    except (ValueError, ImportError, httpx.InvalidURL):
                        raise httpx.ProxyError(
                            "Managed network relay is unavailable", request=request
                        ) from None
                    self.explicit[relay] = transport
            return transport.handle_request(request)
        # GET and HEAD are the actual locked HF snapshot operations. Uploads
        # and non-replayable bodies never silently acquire another transport.
        if request.method not in ("GET", "HEAD"):
            raise httpx.UnsupportedProtocol(
                "Managed network method is unavailable", request=request
            )
        deadline = request.extensions.get("ergopti_native_deadline")
        if deadline is not None and not Native._positive_timeout(deadline):
            raise httpx.ReadTimeout("Managed network deadline is invalid", request=request)
        timeout = None if deadline is None else deadline - time.monotonic()
        if timeout is not None and timeout <= 0:
            raise httpx.ReadTimeout("Managed network deadline is exhausted", request=request)
        timeouts = request.extensions.get("timeout", {})
        idle = timeouts.get("read") if isinstance(timeouts, dict) else None
        if idle is None:
            idle = self.idle_timeout
        headers = [
            (name.decode("ascii"), value.decode("latin-1")) for name, value in request.headers.raw
        ]
        # Foundation owns content decoding. Identity keeps HTTPX's raw stream
        # and HF's range/integrity contract byte-exact; a violating origin is
        # refused by the native receiver before body delivery.
        headers = [(name, value) for name, value in headers if name.lower() != "accept-encoding"]
        headers.append(("Accept-Encoding", "identity"))
        with self.lock:
            if self.closed:
                raise httpx.ConnectError("Managed network transport is closed", request=request)
            # Serialize construction with close: shutdown cannot return while
            # an unregistered physical native child is awaiting its headers.
            try:
                response = Native.open_request(
                    str(request.url), headers, request.method, timeout, idle, mode == "direct"
                )
            except Native.NativeHTTPError as error:
                raise _failure(error, request) from None
            if response.status in (301, 302, 303, 307, 308):
                # HTTPX otherwise drains the redirect body before dispatching
                # its successor. Retire the exact native child at headers so a
                # stalled/error body cannot hold the next full-URL PAC lookup.
                response.close()
                return httpx.Response(
                    response.status,
                    headers=response.headers,
                    stream=httpx.ByteStream(b""),
                    extensions={"ergopti_native": True},
                )
            stream = _NativeStream(response, request, self._retired)
            self.active.add(stream)
        return httpx.Response(
            response.status,
            headers=response.headers,
            stream=stream,
            extensions={"ergopti_native": True},
        )

    def close(self):
        with self.lock:
            self.closed = True
            streams = tuple(self.active)
            transports = tuple(self.explicit.values())
        failure = None
        for owned in streams + transports:
            try:
                owned.close()
            except BaseException as error:
                # Keep uncertain owners reachable and allow a subsequent close
                # to retry. Retire other children before propagating cancellation.
                if failure is None:
                    failure = error
        if failure is not None:
            raise failure


def install_huggingface_transport():
    """Install before the HF singleton client can originate any request.

    Xet and hf_transfer are independent native clients. They stay disabled
    rather than bypass this request-level native routing/trust boundary.
    """
    os.environ["HF_HUB_DISABLE_XET"] = "1"
    os.environ["HF_HUB_ENABLE_HF_TRANSFER"] = "0"
    from huggingface_hub import constants, set_client_factory
    from huggingface_hub.utils._http import hf_request_event_hook

    # The actual locked library snapshots this environment flag at import.
    # Preserve the route even if another import initialized constants earlier.
    constants.HF_HUB_DISABLE_XET = True

    def factory():
        return httpx.Client(
            transport=ManagedHTTPTransport(constants.HF_HUB_DOWNLOAD_TIMEOUT),
            event_hooks={"request": [hf_request_event_hook]},
            follow_redirects=True,
            max_redirects=Policy.ProxyPolicy().maximum_hops,
            timeout=None,
            trust_env=False,
            headers={"Accept-Encoding": "identity"},
        )

    set_client_factory(factory)
