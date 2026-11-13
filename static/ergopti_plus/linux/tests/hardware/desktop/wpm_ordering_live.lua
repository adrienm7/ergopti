--- tests/hardware/desktop/wpm_ordering_live.lua

--- ==============================================================================
--- MODULE: WPM Widget Ordering, Visibility and Colour, On A Real Display
--- DESCRIPTION:
--- The floating WPM widget (ui/wpm/widget.lua over its real GTK surface) fed by
--- the real metrics collector (modules/keystats/keystats.lua with its native
--- SQLite owner), through the two callbacks the daemon calls: the collector's
--- on_keydown for a physical key, and the widget's observe_pointer for a
--- physical pointer event. Checked against the shown window and real cairo
--- pixels:
---   - pointer then key shows the widget; key then pointer hides it;
---   - a hotstring preview on screen keeps it up after a pointer move;
---   - a real xdotool drag keeps it up while the pointer moves, and moves it;
---   - AI > hotstring group > autocorrection while their holds overlap, each
---     painted in its own colour, and the lower one back once the higher ends;
---   - no source colour survives the collector or the widget being switched
---     off and on, or the source-colour switch going off and on.
--- Times are the collector's own monotonic milliseconds, given explicitly so a
--- slow container cannot age a one-second colour hold between two lines.
---
--- Exit 0 = every check held. 1 = one failed. 2 = no display, lgi or surface.
--- ==============================================================================

local function abort(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end

if not os.getenv("DISPLAY") then abort("no display server") end
require("core.lifecycle.engine.compat.utf8").install()
local ok_lgi, lgi = pcall(require, "lgi")
if not ok_lgi then abort("lgi is not installed") end
local Gtk = lgi.require("Gtk", "3.0")
local Gdk = lgi.require("Gdk", "3.0")
local Surface = require("adapters.wpm_surface")
if not Surface.is_available() then abort("the widget surface cannot bind GTK") end

require("infra.i18n").init()
local Monotonic = require("infra.monotonic")
local Model = require("metrics.engine.wpm_widget_model")
local Constants = require("infra.wpm_constants")
local Timings = require("infra.timings")
local Widget = require("ui.wpm.widget")
local Preview = require("ui.tooltip.preview")
local Hotstrings = require("modules.hotstrings.hotstrings_config")
local canon = assert(Constants.load(), "the shared canon must load")
local UPDATE_MS = Timings.ms("ui", "wpm_widget_update_ms")
local HOLD_MS = Timings.ms("ui", "wpm_color_hold_ms")

-- The hotstring groups resolve their colours through the real catalogue.
assert(Hotstrings.init(require("modules.hotstrings.engine").new(), nil, function() end))
assert(select(2, Hotstrings.load_all(nil, true)) == true, "the bundled catalogue must load")

local failures = {}
local function expect(condition, label)
	print((condition and "  PASS " or "  FAIL ") .. label)
	if not condition then failures[#failures + 1] = label end
end

local function pump(seconds)
	local deadline = Monotonic.now_ms() + seconds * 1000
	repeat
		while Gtk.events_pending() do Gtk.main_iteration_do(false) end
		os.execute("sleep 0.03")
	until Monotonic.now_ms() >= deadline
end

local function hex_of(frame)
	local image = lgi.cairo.ImageSurface.create("ARGB32", frame.width, frame.height)
	Surface.paint(lgi.cairo.Context.create(image), frame)
	local pixel = Gdk.pixbuf_get_from_surface(image, 3, math.floor(frame.height / 2) - 10, 1, 1):get_pixels()
	return string.format("#%02x%02x%02x", pixel:byte(1, 3))
end

local function near(observed, expected)
	local function channel(text, index) return tonumber(text:sub(index, index + 1), 16) end
	for index = 2, 6, 2 do
		if math.abs(channel(observed, index) - channel(expected, index)) > 3 then return false end
	end
	return true
end

local Preferences = require("tests.support.metrics_preferences_fixture")
local Fixture = require("tests.support.keystats_native_fixture")
local APP = "proof-editor"

print("=== the WPM widget's ordering, visibility and colours (display " .. os.getenv("DISPLAY") .. ") ===")
Preferences.with(function()
	Fixture.with(function(k)
		k.init({ sqlite_path = os.tmpname() })
		require("tests.support.metrics_consent_fixture").enable(k)
		require("tests.support.live_preferences").ensure_directory()
		Widget.restore()
		assert(Widget.set_use_source_colors(true) and Widget.set_graph(false) and Widget.reset_position())
		assert(Widget.start() == true, "the widget must start")

		-- One clock for the whole scenario: the collector's own milliseconds.
		local now = math.floor(Monotonic.now_ms())
		local function at(step) now = now + step; return now end
		local function key(ch) k.on_keydown(ch, at(30), APP) end
		local function pointer(kind, value) Widget.observe_pointer(kind, value, at(30) / 1000) end
		local function tick()
			local frame = Widget.tick(k.get_live_stats(at(UPDATE_MS + 1)), now / 1000)
			pump(0.25)
			return frame
		end
		-- Six keys give the readout a speed; the pill is drawn from then on.
		for ch in ("bonjour"):gmatch(".") do key(ch) end

		print("--- 1. pointer and key ordering ---")
		pointer("motion", 4)
		key("a")
		tick()
		expect(Surface.is_visible(), "pointer then key: the widget is shown")
		key("b")
		pointer("motion", 3)
		tick()
		expect(not Surface.is_visible(), "key then pointer: the widget is hidden")
		pointer("press", 1)
		key("c")
		tick()
		expect(Surface.is_visible(), "a click then a key shows it again")
		key("d")
		pointer("motion", 0)
		tick()
		expect(Surface.is_visible(), "a motion event of zero travel does not hide it")

		print("--- 2. a hotstring preview keeps it up ---")
		key("e")
		-- As the daemon initialises it: the shared style, the real catalogue's policy.
		Preview.init({ style = require("ui.tooltip.config").load(), config = Hotstrings })
		Preview.show({ { trigger = "★a", replacement = "à", group = "magickey", section = "replace", fires = true } },
			"star")
		pump(0.3)
		pointer("motion", 5)
		tick()
		expect(Preview.is_visible() and Surface.is_visible(), "with the preview on screen a pointer move leaves it shown")
		Preview.hide()
		pump(0.2)
		tick()
		expect(not Surface.is_visible(), "the preview gone, the same pointer move hides it")

		print("--- 3. a real drag keeps it up ---")
		key("f")
		tick()
		local px, py = Surface.position()
		os.execute(string.format("xdotool mousemove %d %d mousedown 1", px + 10, py + 10))
		pump(0.3)
		os.execute(string.format("xdotool mousemove %d %d", px - 140, py - 110))
		pump(0.3)
		pointer("motion", 7)
		tick()
		expect(Surface.is_dragging() and Surface.is_visible(), "the pointer moves after the key during a drag: still shown")
		os.execute("xdotool mouseup 1")
		pump(0.3)
		local nx, ny = Surface.position()
		expect(nx == px - 150 and ny == py - 120, string.format("the drag moved it from %d,%d to %d,%d", px, py, nx, ny))

		print("--- 4. AI > hotstring group > autocorrection ---")
		local colour = {
			llm = canon.colors.bg_ai,
			magickey = Model.source_hex(canon, "magickey", function(group) return Hotstrings.resolve(group, nil).color end),
			autocorrection = Model.source_hex(canon, "autocorrection",
				function(group) return Hotstrings.resolve(group, nil).color end),
		}
		print(string.format("  colours: AI %s, magickey %s, autocorrection %s, manual %s",
			colour.llm, colour.magickey, colour.autocorrection, canon.colors.bg_manual))
		expect(colour.llm ~= colour.magickey and colour.magickey ~= colour.autocorrection
			and colour.autocorrection ~= canon.colors.bg_manual, "the three sources paint three distinct colours")
		key("g")
		k.record_hotstring(APP, "ca", "ça", at(20), "autocorrection", 2)
		local frame = assert(tick())
		expect(near(hex_of(frame), colour.autocorrection), "an autocorrection alone paints its colour: " .. hex_of(frame))
		k.record_hotstring(APP, "★a", "à", at(20), "magickey", 2)
		frame = assert(tick())
		expect(near(hex_of(frame), colour.magickey), "a later hotstring group outranks it: " .. hex_of(frame))
		k.record_hotstring(APP, "ca", "ça", at(20), "autocorrection", 2)
		frame = assert(tick())
		expect(near(hex_of(frame), colour.magickey), "a newer autocorrection does not take it back: " .. hex_of(frame))
		k.record_synthetic_output(APP, " et la suite", "llm", at(20))
		local ai_at = now
		frame = assert(tick())
		expect(near(hex_of(frame), colour.llm), "the AI outranks both: " .. hex_of(frame))
		k.record_hotstring(APP, "★a", "à", at(20), "magickey", 2)
		local magickey_at = now
		frame = assert(tick())
		expect(near(hex_of(frame), colour.llm), "a newer hotstring does not take it back: " .. hex_of(frame))
		key("h")
		-- One millisecond past the AI hold, still inside the later magickey hold.
		assert(ai_at + HOLD_MS + 1 < magickey_at + HOLD_MS and ai_at + HOLD_MS + 1 > now)
		now = ai_at + HOLD_MS + 1
		frame = assert(Widget.tick(k.get_live_stats(now), now / 1000))
		pump(0.2)
		expect(near(hex_of(frame), colour.magickey),
			"the AI hold ends first, the newer magickey hold paints again: " .. hex_of(frame))
		frame = assert(Widget.tick(k.get_live_stats(at(HOLD_MS)), now / 1000))
		pump(0.2)
		expect(near(hex_of(frame), canon.colors.bg_manual), "every hold ended, manual typing paints: " .. hex_of(frame))

		print("--- 5. no retained colour after disable and re-enable ---")
		k.record_synthetic_output(APP, " suite", "llm", at(20))
		expect(near(hex_of(assert(tick())), colour.llm), "an AI insertion colours the pill")
		assert(k.set_enabled(false) == true and k.set_enabled(true) == true)
		key("i")
		frame = assert(tick())
		expect(near(hex_of(frame), canon.colors.bg_manual), "metrics off and on inside the hold: manual colour " .. hex_of(frame))
		k.record_synthetic_output(APP, " suite", "llm", at(20))
		expect(near(hex_of(assert(tick())), colour.llm), "a new AI insertion colours it again")
		assert(Widget.set_use_source_colors(false))
		key("j")
		frame = assert(tick())
		expect(near(hex_of(frame), canon.colors.bg_manual), "source colours off: manual colour " .. hex_of(frame))
		at(HOLD_MS)
		assert(Widget.set_use_source_colors(true))
		key("k")
		frame = assert(tick())
		expect(near(hex_of(frame), canon.colors.bg_manual), "back on after the hold: no stale AI colour " .. hex_of(frame))
		k.record_hotstring(APP, "★a", "à", at(20), "magickey", 2)
		expect(near(hex_of(assert(tick())), colour.magickey), "a hotstring colours the pill")
		assert(Widget.stop() == true)
		pump(0.2)
		expect(not Surface.is_visible(), "the widget switched off is hidden")
		at(HOLD_MS)
		assert(Widget.start() == true)
		key("l")
		frame = assert(tick())
		expect(Surface.is_visible() and near(hex_of(frame), canon.colors.bg_manual),
			"switched on again it shows manual typing, not the old hotstring colour " .. hex_of(frame))
		assert(Widget.stop() == true)
	end)
end)

if #failures > 0 then
	print(string.format("=== %d check(s) failed ===", #failures))
	os.exit(1)
end
print("=== every check held ===")
os.exit(0)
