# tools/diagnostics/native_global_switcher/native_controller_owner.py
"""Retain exact early-registered native capabilities until physical retirement."""

from pathlib import Path


class ProbeControllerOwner:
    """A pending fixture keeps its parent and WNOWAIT reservation alive."""

    def __init__(self, native, ownership, scratch):
        self.native, self.ownership, self.scratch = native, ownership, Path(scratch)
        self.capabilities = []
        self.hs = None
        self.cancel_requested = False
        self.pending_reason = None
        self.qualification_refused = False

    def request_cancel(self, reason):
        self.cancel_requested = True
        self.pending_reason = reason
        # Only this scope's private source marker; never external TCC or user config.
        try:
            (self.scratch / "cancel").touch(exist_ok=True)
            return True
        except BaseException:
            # Logical cancellation is latched before IO. A refused marker cannot
            # abandon exact native capabilities or manufacture physical cleanup.
            self.pending_reason = "cancel_marker_refused"
            self.qualification_refused = True
            return False

    def register(self, role, capability):
        self.capabilities.append((role, capability))
        if role == "hammerspoon":
            self.hs = capability

    def acquire(self, role, arguments, **options):
        if self.cancel_requested:
            raise RuntimeError("Acquisition refused after controller cancellation")

        def register(capability):
            # This parent reservation is visible before acquisition-time signals
            # are restored or an external adopter is called.
            self.register(role, capability)

        return self.ownership.acquire_owned(arguments, self.native, register, **options)

    def acquire_external(self, arguments, native, adopter, **options):
        """Existing inventory helpers share this retained exact-capability carrier."""
        if native is not self.native:
            raise RuntimeError("Foreign native owner refused")
        if self.cancel_requested:
            raise RuntimeError("Acquisition refused after controller cancellation")

        def register(capability):
            self.register("inventory_tool", capability)
            adopter(capability)

        return self.ownership.acquire_owned(arguments, native, register, **options)

    def hammerspoon_is_physically_settled(self, receipt):
        """Only the same live native runtime can attest its cooperative input cleanup."""
        if self.hs is None:
            return True
        if not isinstance(receipt, dict) or type(receipt.get("hs_pid")) is not int:
            return False
        if (
            receipt["hs_pid"] != self.hs.process.pid
            or receipt.get("coverage") != "isolated_fixture_only"
        ):
            return False
        if receipt.get("status") not in ("observed", "refused", "blocked_accessibility"):
            return False
        return receipt.get("cleanup_debt") is False and all(
            receipt.get(key) is True
            for key in ("tasks_retired", "tap_retired", "timer_retired", "session_retired")
        )

    def retirement_step(self, receipt):
        """Never exit or signal the runtime while its input-owner debt is unacknowledged."""
        hs_settled = self.hammerspoon_is_physically_settled(receipt)
        for role, capability in self.capabilities:
            if capability.reaped:
                continue
            if role in ("hammerspoon", "fixture_a", "fixture_b") and not hs_settled:
                continue
            try:
                # Existing native owner preserves WNOWAIT and exact group membership
                # through refusal; this capsule remains reachable on every failure.
                if capability.settle() is not True:
                    self.pending_reason = "native_group_retirement_refused"
            except BaseException:
                self.pending_reason = "native_group_retirement_refused"
        return all(capability.reaped is True for _, capability in self.capabilities)

    def retire_until_settled(self, read_receipt, sources_current, publish_pending, pause):
        """Keep this exact parent alive through cooperative boundary/IO refusal."""
        while True:
            try:
                receipt = read_receipt()
            except BaseException:
                receipt = None
                self.request_cancel("receipt_read_refused")
                self.qualification_refused = True
            if self.hs is not None and not self.hammerspoon_is_physically_settled(receipt):
                self.request_cancel("native_cleanup_pending")
            try:
                current = sources_current() is True
            except BaseException:
                current = False
            if not current:
                self.request_cancel("source_pins_revoked")
            if self.retirement_step(receipt):
                return receipt
            try:
                publish_pending(receipt)
            except BaseException:
                self.request_cancel("evidence_publish_refused")
                self.qualification_refused = True
            try:
                pause(0.05)
            except BaseException:
                self.request_cancel("controller_pause_refused")
                self.qualification_refused = True

    def receipts(self):
        return [
            {"role": role, "native": capability.receipt()} for role, capability in self.capabilities
        ]
