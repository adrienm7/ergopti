--- tests/hardware/desktop/run_wayland_desktop_changes.lua

--- ==============================================================================
--- MODULE: Wayland Desktop Changes Against A Real Compositor
--- DESCRIPTION:
--- Run by run_wayland_sessions.sh inside a live headless compositor session.
--- The daemon's own path: workspace_switcher.current_workspace_source feeds
--- system_metrics.bind_desktop_source, and the focus tick's observe_desktop
--- counts `space_switches`. The workspaces are switched through the module's
--- own backend (swaymsg, KWin's D-Bus), each switch at least 1 s apart, and
--- the count must rise by exactly one per switch. A switch and its return
--- inside the 1 s reuse window are missed, as documented. On GNOME the source
--- is absent and the metric names its reason, as the Metrics menu shows it.
---
--- USAGE: luajit run_wayland_desktop_changes.lua <driver root> <sway|kde|gnome>
--- Exit 0 = verified; any assertion failure exits non-zero.
--- ==============================================================================

local root, mode = assert(arg[1], "driver root"), assert(arg[2], "session mode")
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
	.. root .. "/../_shared/?.lua;" .. root .. "/../_shared/?/init.lua;" .. package.path
require("core.lifecycle.engine.compat.utf8").install()
local uv = require("luv")
local Display = require("infra.display_server")
local Monotonic = require("infra.monotonic")
local Navigation = require("keyboard.engine.desktop_navigation")
local Switcher = require("modules.gestures.workspace_switcher")
local SystemMetrics = require("modules.keystats.system_metrics")

local UNMEASURED_REASON = "platform_reason.desktop_changes_need_workspace_interface"
-- Past the switcher's 1 s reuse window, so each observation is a fresh query.
local SETTLE_MS = 1150

local function sleep_ms(ms)
	local timer = uv.new_timer()
	timer:start(ms, 0, function() timer:close() end)
	uv.run()
end

local function never_press(combo)
	error("the backend must switch by itself; the fallback pressed " .. tostring(combo), 0)
end

assert(Display.refresh() == Display.WAYLAND, "the session must be a Wayland one")
print(string.format("SESSION mode=%s desktop=%s wayland_display=%s", mode, Display.desktop(),
	tostring(os.getenv("WAYLAND_DISPLAY"))))

SystemMetrics._reset()
SystemMetrics.bind_event_capture(function() return true end)
-- The binding exactly as ergopti_hotstrings.lua makes it on a session with no
-- X11 desktop.
local read, reason = Switcher.current_workspace_source(Monotonic.now_ms)
SystemMetrics.bind_desktop_source(read, not read and UNMEASURED_REASON or nil)

if mode == "gnome" then
	assert(read == nil, "GNOME Wayland exposes no workspace interface to a client")
	assert(reason == "unsupported", "the reason must be the unsupported session, got " .. tostring(reason))
	local availability = SystemMetrics.space_change_availability()
	assert(availability.measured == false and availability.reason == UNMEASURED_REASON,
		"the Metrics menu row must name the reason")
	assert(SystemMetrics.observe_desktop() == nil, "nothing is observed without a source")
	print("PASS gnome unmeasured reason=" .. availability.reason .. " detect=" .. reason)
	return
end

assert(read, "the compositor must answer a workspace source, refused: " .. tostring(reason))
local backend = assert(Switcher.detect())
print("BACKEND " .. backend.name)
assert(SystemMetrics.space_change_availability().measured == true, "a bound source is measured")
SystemMetrics.sample()
assert(SystemMetrics.observe_desktop() == false, "the first answer is the baseline")
local day = assert(SystemMetrics.current(), "a sampled day")
local baseline = day.space_switches
local switches = { Navigation.NEXT, Navigation.NEXT, Navigation.NEXT, Navigation.PREVIOUS }
for index, direction in ipairs(switches) do
	local before = read()
	sleep_ms(SETTLE_MS)
	local outcome = Switcher.switch(direction, true, never_press)
	assert(outcome == "switched", "switch " .. index .. " answered " .. outcome)
	sleep_ms(SETTLE_MS)
	assert(SystemMetrics.observe_desktop() == true, "switch " .. index .. " must be one change")
	assert(day.space_switches == baseline + index, "the count must rise by one per switch")
	assert(SystemMetrics.observe_desktop() == false, "an unchanged workspace is no switch")
	print(string.format("PASS switch %d %s %s -> %s space_switches=%d", index, direction,
		tostring(before), tostring(read()), day.space_switches))
end

-- The documented limit: a round trip inside the reuse window is not seen.
local counted = day.space_switches
sleep_ms(SETTLE_MS)
local here = read()
assert(Switcher.switch(Navigation.NEXT, true, never_press) == "switched")
assert(Switcher.switch(Navigation.PREVIOUS, true, never_press) == "switched")
assert(read() == here, "the reader reuses its answer inside 1 s")
sleep_ms(SETTLE_MS)
assert(SystemMetrics.observe_desktop() == false and day.space_switches == counted,
	"a round trip shorter than the reuse window is missed, never double counted")
print("PASS sub-second round trip missed space_switches=" .. day.space_switches)

local events = 0
for _, event in ipairs(SystemMetrics.take_events()) do
	if event.action == "space_change" then events = events + 1 end
end
assert(events == #switches, "one space_change event per switch")
print(string.format("PASS %s %d switches counted, %d space_change events", mode, #switches, events))
