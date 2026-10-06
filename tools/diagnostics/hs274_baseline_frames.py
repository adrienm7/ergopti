# tools/diagnostics/hs274_baseline_frames.py
"""Validate the paged initial state independently of raw stream sequencing."""

from hs274_capture import decimal, integer


class BaselineFrames:
    """Decode one bounded baseline; the stream reader validates session identity."""

    def __init__(self, descriptor, *, historical_replay=False):
        if not isinstance(descriptor, dict) or set(descriptor) != {"version", "boundary", "rows"}:
            raise ValueError("Invalid baseline descriptor")
        if type(historical_replay) is not bool:
            raise ValueError("Invalid historical replay mode")
        if historical_replay:
            self.version = integer(descriptor["version"], "historical baseline version", 1, 2)
        else:
            self.version = integer(descriptor["version"], "baseline version", 2, 2)
        self.boundary = decimal(descriptor["boundary"])
        self.total = integer(descriptor["rows"], "baseline rows", 1, 64 * 1025)
        self.cursor = 0
        self.complete = False
        self.devices = {}
        self.current = None

    def _device_complete(self):
        if self.current is not None:
            if len(self.current["keys"]) != self.current["elements"]:
                raise ValueError("Incomplete baseline device inventory")
            if self.version == 2:
                has_keyboard = any(key["page"] == 7 for key in self.current["keys"].values())
                if has_keyboard != self.current["keyboard"]:
                    raise ValueError("Baseline keyboard flag differs from its inventory")

    def accept(self, frame, envelope_fields):
        """Reject gaps, identity aliasing and raw admission before explicit completion."""
        if self.complete:
            raise ValueError("Baseline is already complete")
        if frame["kind"] == "baseline_ready":
            if set(frame) != envelope_fields or self.cursor != self.total:
                raise ValueError("Premature baseline completion")
            self._device_complete()
            self.complete = True
            return
        fields = {"boundary", "offset", "next", "total", "complete", "rows"}
        if frame["kind"] != "baseline" or set(frame) != envelope_fields | fields:
            raise ValueError("Unexpected baseline frame")
        if decimal(frame["boundary"]) != self.boundary:
            raise ValueError("Baseline opening boundary changed")
        if integer(frame["offset"], "baseline offset") != self.cursor:
            raise ValueError("Baseline cursor skipped or repeated rows")
        if integer(frame["total"], "baseline total") != self.total:
            raise ValueError("Baseline row count changed")
        next_cursor = integer(frame["next"], "baseline next", self.cursor + 1, self.total)
        rows = frame["rows"]
        if (
            not isinstance(rows, list)
            or not 1 <= len(rows) <= 64
            or len(rows) != next_cursor - self.cursor
        ):
            raise ValueError("Invalid baseline page size")
        if type(frame["complete"]) is not bool or frame["complete"] != (next_cursor == self.total):
            raise ValueError("Invalid baseline page completion")
        for row in rows:
            if not isinstance(row, dict):
                raise ValueError("Invalid baseline row")
            device = decimal(row.get("device"), minimum=1)
            if row.get("kind") == "device":
                self._device_complete()
                device_fields = {"kind", "device", "keyboard", "elements"}
                if self.version == 2:
                    device_fields.add("keyboard_type")
                if set(row) != device_fields or type(row["keyboard"]) is not bool:
                    raise ValueError("Invalid baseline device marker")
                if device in self.devices or len(self.devices) == 64:
                    raise ValueError("Duplicated or excessive baseline devices")
                count = integer(
                    row["elements"],
                    "baseline elements",
                    1 if row["keyboard"] else 0,
                    1024 if self.version == 2 or row["keyboard"] else 0,
                )
                self.current = {"keyboard": row["keyboard"], "elements": count, "keys": {}}
                if self.version == 2:
                    expected_types = {"ansi", "iso", "jis"} if row["keyboard"] else {"none"}
                    if (
                        not isinstance(row["keyboard_type"], str)
                        or row["keyboard_type"] not in expected_types
                    ):
                        raise ValueError("Invalid baseline keyboard type")
                    self.current["keyboard_type"] = row["keyboard_type"]
                self.devices[device] = self.current
            elif row.get("kind") == "key":
                key_fields = {"kind", "device", "usage", "cookie", "timestamp", "down"}
                if self.version == 2:
                    key_fields.add("page")
                if set(row) != key_fields:
                    raise ValueError("Invalid baseline key fields")
                if device not in self.devices or self.devices[device] is not self.current:
                    raise ValueError("Baseline key has no current device marker")
                cookie = integer(row["cookie"], "baseline cookie", 0, (1 << 32) - 1)
                page = 7
                if self.version == 2:
                    page = integer(row["page"], "baseline page", 1, 65535)
                    if page not in (7, 12, 255, 65281):
                        raise ValueError("Unsupported baseline key page")
                usage = integer(row["usage"], "baseline usage", 1, 255 if page == 7 else 65535)
                timestamp = decimal(row["timestamp"], maximum=self.boundary)
                if type(row["down"]) is not bool or (page == 7 and usage <= 3 and row["down"]):
                    raise ValueError("Invalid baseline key value")
                keys = self.current["keys"]
                if cookie in keys or len(keys) >= self.current["elements"]:
                    raise ValueError("Duplicated or excessive baseline elements")
                keys[cookie] = {"usage": usage, "timestamp": timestamp, "down": row["down"]}
                if self.version == 2:
                    keys[cookie]["page"] = page
            else:
                raise ValueError("Unknown baseline row kind")
        self.cursor = next_cursor

    def result(self):
        """Retain partial receipt evidence without claiming completed admission."""
        return {
            "boundary": self.boundary,
            "complete": self.complete,
            "received_rows": self.cursor,
            "devices": self.devices,
        }
