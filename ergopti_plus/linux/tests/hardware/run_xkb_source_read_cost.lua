--- tests/hardware/run_xkb_source_read_cost.lua

--- ==============================================================================
--- MODULE: X11 Source Read Cost (real X server)
--- DESCRIPTION:
--- Every injected key press proves the layout live through
--- adapters/xkb_source_probe.read(). Until 2026-11-11 each read downloaded the
--- whole keymap from the server and serialized it (48 KB, about 0.6 ms on an
--- idle Xvfb, more on a busy desktop), which made a typed replacement cost
--- about 1.1 ms per character. A read now reuses the text it last downloaded
--- while no XKB NewKeyboard or Map notification has been drained since.
---
--- WHAT IT PINS:
--- 1. Reads without a keymap change cost well under the download they used to
---    repeat: the median of a batch stays below READ_BUDGET_MS.
--- 2. The reuse never outlives the keymap: after setxkbmap the old identity is
---    refused and the new one admitted, the guarantee the download gave.
---
--- HOW TO RUN IT (run_perf_budget_container.py does it in CI):
---   xvfb-run -a luajit tests/hardware/run_xkb_source_read_cost.lua
--- Exit 0 = every assertion held. 1 = a failure. 2 = no X server or library.
--- ==============================================================================

local ffi = require("ffi")
local luv = require("luv")
local Runtime = require("_generated.native_runtime")

-- A read is two state round trips and two synchronizing drains once the text
-- is reused (about 0.15 ms on an idle Xvfb); the download it no longer repeats
-- cost 0.6 ms alone. The budget sits between the two with room for a slow CI
-- runner, so the old per-read download fails it.
local READ_BUDGET_MS = 0.45
local READS_PER_BATCH = 50
local BATCHES = 9

if not os.getenv("DISPLAY") or os.getenv("DISPLAY") == "" then
	io.stderr:write("ENVIRONMENT: no DISPLAY\n")
	os.exit(2)
end

-- The probe declares every libX11 and libxkbcommon function used below; a
-- second declaration here would collide with its own, so it binds first.
local Probe = require("adapters.xkb_source_probe")
Probe.read("bind the probe's native declarations", 1)

--- The server's current keymap text, as the probe's identity expects it.
--- @return string
local function server_keymap()
	local x11, bridge = ffi.load(Runtime.x11), ffi.load(Runtime.x11_xcb)
	local xkb, xkb11 = ffi.load(Runtime.xkbcommon), ffi.load(Runtime.xkbcommon_x11)
	local display = x11.XOpenDisplay(nil)
	assert(display ~= nil, "no X display")
	local xcb = bridge.XGetXCBConnection(display)
	assert(xkb11.xkb_x11_setup_xkb_extension(xcb, 1, 0, 0, nil, nil, nil, nil) == 1, "no XKB")
	local context = xkb.xkb_context_new(0)
	local keymap = xkb11.xkb_x11_keymap_new_from_device(context, xcb, xkb11.xkb_x11_get_core_keyboard_device_id(xcb), 0)
	local bytes = xkb.xkb_keymap_get_as_string(keymap, 1)
	local text = ffi.string(bytes)
	ffi.C.free(bytes)
	xkb.xkb_keymap_unref(keymap)
	xkb.xkb_context_unref(context)
	x11.XCloseDisplay(display)
	return text
end

local failures = 0
local function check(condition, message)
	print((condition and "  ok   " or "  FAIL ") .. message)
	if not condition then failures = failures + 1 end
end

local us = server_keymap()
local receipt, reason = Probe.read(us, 1)
if not receipt and (reason == "native-x11-libraries-unavailable" or reason == "native-display-unavailable") then
	io.stderr:write("ENVIRONMENT: " .. tostring(reason) .. "\n")
	os.exit(2)
end
check(receipt ~= nil, "the probe admits the server's own keymap (" .. tostring(reason) .. ")")

local medians = {}
for _ = 1, BATCHES do
	local started = luv.hrtime()
	for _ = 1, READS_PER_BATCH do assert(Probe.read(us, 1), "a read refused an unchanged keymap") end
	medians[#medians + 1] = (luv.hrtime() - started) / 1e6 / READS_PER_BATCH
end
table.sort(medians)
local median = medians[math.ceil(#medians / 2)]
check(median < READ_BUDGET_MS, string.format("a read of an unchanged keymap costs %.3f ms (budget %.2f ms)",
	median, READ_BUDGET_MS))

local switched = os.execute("setxkbmap fr")
check(switched == true or switched == 0, "setxkbmap changed the server's layout")
local fr = server_keymap()
check(fr ~= us, "the French keymap differs from the US one")
local stale, stale_reason = Probe.read(us, 1)
if not stale and stale_reason == "native-source-raced" then stale, stale_reason = Probe.read(us, 1) end
check(stale == nil and stale_reason == "native-keymap-unacknowledged",
	"the old identity is refused after the change (" .. tostring(stale_reason) .. ")")
check(Probe.read(fr, 1) ~= nil, "the new keymap is admitted")
os.execute("setxkbmap us")
Probe.close()
os.exit(failures == 0 and 0 or 1)
