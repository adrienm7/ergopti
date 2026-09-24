--- tests/hardware/run_wpm_readouts_live.lua

--- ==============================================================================
--- MODULE: The WPM Readouts, Live, On A Real Display
--- DESCRIPTION:
--- The floating widget through its real GTK surface and the tray readout
--- through the real libayatana-appindicator, fed the stats the keylogger
--- hands the daemon's tick:
---   - the pill appears where the canon puts it, the size it says, painted in
---     the source's colour (read back from real cairo pixels);
---   - graph mode resizes it and keeps its bottom-right corner;
---   - a real pointer drag (xdotool) moves it, and the place is kept;
---   - the tray readout registers with a StatusNotifier host, Active, with its
---     number painted into an icon file the panel can open.
--- The host (tests/hardware/sni_host.py) runs beside this process and judges
--- the tray item; this script judges everything else.
---
--- Exit 0 = shown and right. 1 = it was not. 2 = the environment cannot host the
--- test (no display, no lgi, no tray library).
--- ==============================================================================

local WAIT_SECONDS = 0.05

local function abort(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end

print("=== the WPM readouts, on a real display ===")

if not os.getenv("DISPLAY") then abort("no display server — run under xvfb-run.") end
local ok_lgi, lgi = pcall(require, "lgi")
if not ok_lgi then abort("lgi is not installed.") end
local Gtk = lgi.require("Gtk", "3.0")
local Gdk = lgi.require("Gdk", "3.0")

local Surface = require("adapters.wpm_surface")
local Indicator = require("platform.tray.appindicator")
if not Surface.is_available() then abort("the widget surface cannot bind GTK.") end
if not Indicator.is_available() then abort("the tray library cannot bind.") end

local Model = require("wpm_widget.model")
local Constants = require("infra.wpm_constants")
local Widget = require("ui.wpm.widget")
local Readout = require("ui.wpm.tray_readout")
local canon = assert(Constants.load(), "the shared canon must load")

local failures = {}
local function expect(ok, label)
	print((ok and "  ok   " or "  FAIL ") .. label)
	if not ok then failures[#failures + 1] = label end
end

local function pump(seconds)
	for _ = 1, math.max(1, math.floor(seconds / WAIT_SECONDS)) do
		while Gtk.events_pending() do Gtk.main_iteration_do(false) end
		Indicator.pump()
		os.execute("sleep " .. tostring(WAIT_SECONDS))
	end
end

local clock = 100
local function tick(stats)
	clock = clock + 1
	Widget.tick(stats, clock)
	Readout.tick(stats, clock)
	pump(0.3)
end

local typing_ai = { wpm = 72, source = "llm", source_variant = "llm", source_time = 1e9 }
local function fresh(stats)
	stats.source_time = clock + 1
	return stats
end




-- =========================================
-- ======= 1/ The pill =====================
-- =========================================

Widget.restore()
expect(Widget.start(), "the widget starts")
tick(fresh(typing_ai))
expect(Surface.is_visible(), "the pill is on screen while the user types")

local screen = assert(Surface.screen_frame(), "the monitor has a geometry")
local want_x, want_y = Model.default_anchor(canon, screen)
local x, y = Surface.position()
print(string.format("  pill at %s,%s on a %dx%d screen", tostring(x), tostring(y), screen.w, screen.h))
expect(x == want_x and y == want_y, "it sits in the screen's bottom-right corner, inset by the canon's margin")

-- The frame's pixels, painted by the real cairo and Pango.
local pill = Model.compact_frame(canon, fresh(typing_ai), Widget.frame_options(clock, true))
local image = lgi.cairo.ImageSurface.create("ARGB32", pill.width, pill.height)
Surface.paint(lgi.cairo.Context.create(image), pill)
local pixel = Gdk.pixbuf_get_from_surface(image, 3, math.floor(pill.height / 2) - 10, 1, 1):get_pixels()
local r, g, b = pixel:byte(1, 3)
local ai = Model.rgb(canon.colors.bg_ai)
local function near(value, target) return math.abs(value - math.floor(target * 255 + 0.5)) <= 3 end
print(string.format("  pill pixel: #%02x%02x%02x, AI colour %s", r, g, b, canon.colors.bg_ai))
expect(near(r, ai.red) and near(g, ai.green) and near(b, ai.blue), "the AI's text paints the pill in the AI colour")
local corner = Gdk.pixbuf_get_from_surface(image, 0, 0, 1, 1):get_pixels()
expect(corner:byte(4) == 0, "the corner outside the rounded pill is transparent")




-- =========================================
-- ======= 2/ The graph ====================
-- =========================================

expect(Widget.set_graph(true), "graph mode switches on")
for _ = 1, 3 do tick(fresh(typing_ai)) end
local gx, gy = Surface.position()
local graph = Model.graph_frame(canon, {}, typing_ai, Widget.frame_options(clock, true))
expect(gx + graph.width == want_x + pill.width and gy + graph.height == want_y + pill.height,
	"the graph keeps the pill's bottom-right corner")
expect(Widget.set_graph(false), "and back to the pill")
tick(fresh(typing_ai))




-- =========================================
-- ======= 3/ A real drag ==================
-- =========================================

local has_xdotool = os.execute("command -v xdotool >/dev/null 2>&1")
if has_xdotool == true or has_xdotool == 0 then
	local px, py = Surface.position()
	local grab_x, grab_y = px + 10, py + 10
	os.execute(string.format("xdotool mousemove %d %d mousedown 1", grab_x, grab_y))
	pump(0.3)
	os.execute(string.format("xdotool mousemove %d %d", grab_x - 150, grab_y - 120))
	pump(0.3)
	os.execute("xdotool mouseup 1")
	pump(0.3)
	local nx, ny = Surface.position()
	print(string.format("  dragged from %d,%d to %d,%d", px, py, nx, ny))
	expect(nx == px - 150 and ny == py - 120, "a pointer drag moves the pill")
	local Storage = require("adapters.storage")
	expect(Storage.get("wpm_widget.pos_x", nil) == nx and Storage.get("wpm_widget.pos_y", nil) == ny,
		"and its new place is kept for the next start")
else
	print("  skip the drag: xdotool is not installed")
end




-- =========================================
-- ======= 4/ The tray readout =============
-- =========================================

expect(Readout.start(), "the tray readout starts")
local seconds = tonumber(arg and arg[1]) or 8
local deadline = os.time() + seconds
local shown = nil
while os.time() < deadline do
	shown = Readout.tick(fresh({ wpm = 88, source = "manual", source_variant = "manual" }), clock) or shown
	clock = clock + 1
	pump(0.5)
end
expect(shown ~= nil and shown.number == "88", "the tray readout shows the speed")
Widget.stop()
Readout.stop()
pump(0.3)
expect(not Surface.is_visible(), "stopping the widget takes it off the screen")

if #failures == 0 then os.exit(0) end
os.exit(1)
