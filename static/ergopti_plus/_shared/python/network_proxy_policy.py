"""Interpret the canonical proxy policy without performing native operations."""

import ipaddress
import json
from pathlib import Path
from urllib.parse import urlsplit


class ProxyPolicyError(ValueError):
    """A fixed policy error which never formats a private URL or relay."""

    def __init__(self):
        super().__init__("proxy-policy-invalid")


class ProxyPolicy:
    """Select environment/loopback fast paths; leave system lookup to the OS."""

    def __init__(self, contract=None):
        try:
            if contract is None:
                path = Path(__file__).parent.parent / "modules/network/proxy_policy.json"
                with path.open(encoding="utf-8") as source:
                    contract = json.load(source)
            if type(contract.get("schema_version")) is not int or contract["schema_version"] != 1:
                raise ProxyPolicyError()
            self.orders = contract["environment_precedence"]
            self.bypass_order = contract["environment_bypass_precedence"]
            self.system_lookup_environment_exclusions = tuple(
                contract["system_lookup_environment_exclusions"]
            )
            loopback = contract["loopback"]
            self.hosts = frozenset(loopback["dns_hosts"])
            self.suffixes = tuple(loopback["dns_suffixes"])
            self.networks = tuple(ipaddress.ip_network(value) for value in loopback["ipv4_cidrs"])
            self.ipv6 = frozenset(
                ipaddress.ip_address(value) for value in loopback["ipv6_addresses"]
            )
            self.schemes = frozenset(contract["allowed_proxy_schemes"])
            self.maximum_bytes = contract["max_proxy_bytes"]
            self.maximum_selections = contract["max_selections"]
            self.maximum_hops = contract["redirects"]["max_hops"]
            if set(self.orders) != {"http", "https"}:
                raise ProxyPolicyError()
            for values in (
                *self.orders.values(),
                self.bypass_order,
                self.system_lookup_environment_exclusions,
            ):
                if (
                    not isinstance(values, (list, tuple))
                    or not values
                    or len(set(values)) != len(values)
                    or any(not isinstance(value, str) or not value for value in values)
                ):
                    raise ProxyPolicyError()
            if (
                not self.hosts
                or not self.suffixes
                or not self.networks
                or not self.ipv6
                or not self.schemes
            ):
                raise ProxyPolicyError()
            for value in (self.maximum_bytes, self.maximum_hops, self.maximum_selections):
                if type(value) is not int or value <= 0:
                    raise ProxyPolicyError()
        except (AttributeError, KeyError, TypeError, ValueError, OSError):
            raise ProxyPolicyError() from None

    @staticmethod
    def _authority(url):
        if not isinstance(url, str) or any(ord(value) < 32 or ord(value) == 127 for value in url):
            raise ProxyPolicyError()
        try:
            parsed = urlsplit(url)
            if (
                parsed.scheme.lower() not in ("http", "https")
                or not parsed.hostname
                or parsed.username is not None
                or parsed.password is not None
                or parsed.fragment
            ):
                raise ProxyPolicyError()
            host = parsed.hostname.rstrip(".").lower()
            host = host.encode("idna").decode("ascii")
            if any(ord(value) <= 32 or ord(value) == 127 for value in host):
                raise ProxyPolicyError()
            port = parsed.port
            if port is not None and not 1 <= port <= 65535:
                raise ProxyPolicyError()
            return (
                parsed.scheme.lower(),
                host,
                port or (443 if parsed.scheme.lower() == "https" else 80),
            )
        except (UnicodeError, ValueError):
            raise ProxyPolicyError() from None

    def _loopback(self, host):
        if host in self.hosts or any(
            len(host) > len(suffix) and host.endswith(suffix) for suffix in self.suffixes
        ):
            return True
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            return False
        if address.version == 6:
            return address in self.ipv6
        return any(address in network for network in self.networks)

    @staticmethod
    def _bypass(host, port, values):
        for value in values.split(","):
            value = value.strip().lower()
            if value == "*":
                return True
            if not value:
                continue
            try:
                if "/" in value and ipaddress.ip_address(host) in ipaddress.ip_network(
                    value, strict=False
                ):
                    return True
            except ValueError:
                pass
            # Unbracketed IPv6 is an address, never an ambiguous host:port.
            try:
                if ipaddress.ip_address(value) == ipaddress.ip_address(host):
                    return True
            except ValueError:
                pass
            try:
                parsed = urlsplit(value if "://" in value else "//" + value)
                target = parsed.hostname
                if not target or parsed.username is not None or parsed.password is not None:
                    continue
                if parsed.port is not None and parsed.port != port:
                    continue
                target = target.rstrip(".").lstrip("*.")
                if host == target or host.endswith("." + target):
                    return True
            except ValueError:
                continue
        return False

    def route(self, url, environment):
        """Return ``(direct|environment|native, selected-private-relay-or-None)``."""
        scheme, host, port = self._authority(url)
        if not isinstance(environment, dict) or any(
            not isinstance(key, str) or not isinstance(value, str)
            for key, value in environment.items()
        ):
            raise ProxyPolicyError()
        if self._loopback(host):
            return "direct", None
        bypass = next(
            (environment[name] for name in self.bypass_order if environment.get(name)), ""
        )
        if self._bypass(host, port, bypass):
            return "direct", None
        relay = next(
            (environment[name] for name in self.orders[scheme] if environment.get(name)), None
        )
        if relay is None:
            return "native", None
        if len(relay.encode("utf-8")) > self.maximum_bytes or any(
            ord(value) < 32 or ord(value) == 127 for value in relay
        ):
            raise ProxyPolicyError()
        try:
            parsed = urlsplit(relay)
            if (
                parsed.scheme.lower() not in self.schemes
                or not parsed.hostname
                or parsed.path not in ("", "/")
                or parsed.query
                or parsed.fragment
            ):
                raise ProxyPolicyError()
            if any(ord(value) <= 32 or ord(value) == 127 for value in parsed.hostname):
                raise ProxyPolicyError()
            if parsed.port is not None and not 1 <= parsed.port <= 65535:
                raise ProxyPolicyError()
        except ValueError:
            raise ProxyPolicyError() from None
        return "environment", relay
