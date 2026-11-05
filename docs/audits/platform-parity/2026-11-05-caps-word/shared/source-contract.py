"""Authenticate source-only CapsWord claims without executing AutoHotkey."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
pin = "f2a7dba5fc580aad61e6a0ed16ede84406aed2b0"
paths = [
    "static/ergopti_plus/_shared/lua/caps_word/auto_off.lua",
    "static/ergopti_plus/_shared/modules/features/caps_word_auto_off_policy.ahk",
    "static/ergopti_plus/_shared/modules/features/manifest.toml",
    "static/ergopti_plus/windows/modules/shortcuts/capsword_auto_off.ahk",
    "static/ergopti_plus/macos/infra/capsword_auto_off.lua",
    "static/ergopti_plus/linux/modules/shortcuts/manager.lua",
    "static/ergopti_plus/linux/modules/shortcuts/caps_word_auto_off.lua",
]
source = {}
receipts = []
for name in paths:
    raw = (root / name).read_bytes()
    assert raw == subprocess.check_output(["git", "-C", str(root), "show", f"{pin}:{name}"]), name
    source[name] = raw.decode("utf-8-sig")
    receipts.append({"path": name, "sha256": hashlib.sha256(raw).hexdigest()})
lua = source[paths[0]]
ahk = source[paths[1]]
checks = {
    "lua_positive_seconds_rounded_independently_of_nil_disabled": "idle_ms = seconds > 0 and math.floor(seconds * MS_PER_SECOND + 0.5) or nil"
    in lua,
    "lua_zero_millisecond_policy_is_enabled": "return policy.idle_ms ~= nil and now_ms - last_ms >= policy.idle_ms"
    in lua,
    "ahk_positive_seconds_rounded_into_zero_sentinel": '"idle_ms", Seconds > 0 ? Round(Seconds * 1000) : 0'
    in ahk,
    "ahk_expiry_requires_strictly_positive_ms": 'return Policy["idle_ms"] > 0 && NowMs - LastMs >= Policy["idle_ms"]'
    in ahk,
    "lua_nonnegative_fraction_not_integer_only": 'if type(value) ~= "number" or value ~= value or value == math.huge or value < 0 then'
    in lua,
    "ahk_nonnegative_fraction_not_integer_only": '(Kind != "Integer" && Kind != "Float")' in ahk
    and "Value < 0" in ahk,
    "macos_owner_publishes_each_live_apply": "_policy = policy" in source[paths[4]]
    and "reaches the next event" in source[paths[4]],
    "linux_resolver_uses_real_policy_validator": "if Policy.validate_idle_timeout(idle) then"
    in source[paths[6]],
    "linux_active_owner_snapshots_policy": "_caps_word_policy, _caps_word_last_ms = policy, Monotonic.now_ms()"
    in source[paths[5]],
    "linux_idle_zero_nonnil_queues_check": "if delay then schedule_idle_check(_caps_word_session, delay) end"
    in source[paths[5]],
}
assert all(checks.values()), checks
print(
    json.dumps(
        {
            "audited_sha": pin,
            "sources": receipts,
            "checks": checks,
            "qualification": "Exact pinned source relationships. No AHK execution or Python reimplementation of AHK output.",
        },
        indent=2,
    )
)
