--- tests/unit/modules/keystats/core/test_keystats_media_keys.lua

--- ==============================================================================
--- MODULE: Linux Media Key Metrics Tests
--- DESCRIPTION:
--- The first consumer of the Linux device identity: a media key (play/pause,
--- next and previous track, brightness) is counted under its semantic identity
--- from the shared catalogue, with the device number of the descriptor that
--- read it, and flushed with its hold through the writer's media store; it never
--- reaches the numeric heatmap. Without a device identity nothing is counted,
--- and without a media store the entries wait for one instead of being lost.
--- ==============================================================================

local helpers = require("tests.helpers")
local Home = require("tests.support.keystats_home_fixture")
local Fakes = helpers.load_module("tests.fakes")
local Calendar = require("modules.keystats.calendar")

local KEY_PLAYPAUSE, KEY_NEXTSONG, KEY_A = 164, 163, 30
local DEVICE = "3393"

--- Runs body with a fresh keystats over a writer double that records each media batch.
local function with_keystats(options, body)
	local calls = { media = {}, scancodes = {}, holds = {} }
	local media_open = options.media_open ~= false
	local writer = {
		read_open_walk = function() return nil, true end,
		upsert_open_walk = function() return true end,
		is_available = function() return true end,
		bump_rev = function() return true end,
		media_available = function() return media_open end,
		insert_media_events = function(_, events, threshold_ms)
			calls.media[#calls.media + 1] = { events = events, threshold_ms = threshold_ms }
			return true
		end,
		upsert_scancodes = function(_, _, _, entries)
			calls.scancodes[#calls.scancodes + 1] = entries
			return true
		end,
		upsert_kc_hold = function(_, row)
			calls.holds[#calls.holds + 1] = row
			return true
		end,
	}
	setmetatable(writer, { __index = Fakes.sqlite_writer() })
	require("tests.support.sqlite_flush_fake").attach(writer)
	local writer_name, module_name = "modules.keystats.sqlite_writer", "modules.keystats.keystats"
	local previous_writer, previous_module = package.loaded[writer_name], package.loaded[module_name]
	package.loaded[writer_name], package.loaded[module_name] = writer, nil
	local ok, err = pcall(function()
		local keystats = require(module_name)
		keystats.init({ sqlite_path = Home.fresh_db() })
		require("tests.support.metrics_consent_fixture").enable(keystats)
		keystats.reset_session()
		keystats.on_app_focus("org.gnome.Rhythmbox", 1000)
		body(keystats, calls, function(open) media_open = open end)
	end)
	package.loaded[writer_name], package.loaded[module_name] = previous_writer, previous_module
	if not ok then error(err, 0) end
end

helpers.describe("Linux media key metrics (linux-media-key-metrics)", function()
	Home.it("names the catalogue's media keys and no other key", function()
		with_keystats({}, function(keystats)
			helpers.assert_eq(keystats.media_id(KEY_PLAYPAUSE), "media.play_pause")
			helpers.assert_eq(keystats.media_id(KEY_NEXTSONG), "media.next_track")
			helpers.assert_eq(keystats.media_id(224), "media.brightness_down")
			helpers.assert_nil(keystats.media_id(KEY_A))
			helpers.assert_nil(keystats.media_id("164"))
		end)
	end)

	Home.it("flushes a press and its release under the press's identity, off the heatmap", function()
		with_keystats({}, function(keystats, calls)
			helpers.assert_true(keystats.record_media_press("org.gnome.Rhythmbox", KEY_PLAYPAUSE, DEVICE))
			helpers.assert_true(keystats.record_media_release(KEY_PLAYPAUSE, DEVICE, 320))
			keystats.record_physical_key("org.gnome.Rhythmbox", KEY_A, 1100)
			keystats.flush()
			helpers.assert_eq(#calls.media, 1, "one media batch")
			local batch = calls.media[1]
			helpers.assert_eq(batch.threshold_ms, require("infra.timings").ms("keystats", "hold_threshold_ms"))
			local press, release = batch.events[1], batch.events[2]
			helpers.assert_eq({ press.action, press.media_id, press.capture, press.device, press.app },
				{ "physical_media_press", "media.play_pause", "linux_evdev", DEVICE, "org.gnome.Rhythmbox" })
			helpers.assert_true(press.timestamp:sub(1, 10) == Calendar.capture().date, "the local date leads")
			helpers.assert_true(press.timestamp:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%.%d%d%d$") ~= nil)
			helpers.assert_eq({ release.action, release.hold_ms, release.timestamp, release.device },
				{ "physical_media_release", 320, press.timestamp, DEVICE })
			helpers.assert_nil(press.keycode)
			helpers.assert_nil(press.scancode)
			-- The shared store admits exactly what keystats buffered.
			local store = require("metrics.engine.media.store")
			for index, event in ipairs(batch.events) do store.raw_sql("linux-test", index, event, require("core.text.engine.json").encode) end
			for _, entries in ipairs(calls.scancodes) do
				helpers.assert_nil(entries[KEY_PLAYPAUSE], "a media key never reaches the numeric heatmap")
			end
			helpers.assert_eq(calls.scancodes[1][KEY_A], 1, "an ordinary key still does")
			keystats.flush()
			helpers.assert_eq(#calls.media, 1, "a committed media batch is not replayed")
		end)
	end)

	Home.it("counts nothing without a device identity or a matching press", function()
		with_keystats({}, function(keystats, calls)
			helpers.assert_eq(keystats.record_media_press("app", KEY_PLAYPAUSE, nil), false)
			helpers.assert_eq(keystats.record_media_press("app", KEY_PLAYPAUSE, "0"), false)
			helpers.assert_eq(keystats.record_media_press("app", KEY_A, DEVICE), false, "not a media key")
			helpers.assert_eq(keystats.record_media_release(KEY_NEXTSONG, DEVICE, 10), false, "no press")
			helpers.assert_true(keystats.record_media_press("app", KEY_NEXTSONG, DEVICE))
			helpers.assert_eq(keystats.record_media_release(KEY_NEXTSONG, "9999", 10), false,
				"a release on another device is not this press's")
			keystats.flush()
			helpers.assert_eq(#calls.media, 1)
			helpers.assert_eq(#calls.media[1].events, 1, "only the admitted press")
		end)
	end)

	Home.it("keeps media entries pending while no media store is open", function()
		with_keystats({ media_open = false }, function(keystats, calls, set_media_open)
			helpers.assert_true(keystats.record_media_press("app", KEY_PLAYPAUSE, DEVICE))
			keystats.on_keydown("a", 1200, "app", KEY_A)
			keystats.flush()
			helpers.assert_eq(#calls.media, 0, "nothing is written without a media store")
			set_media_open(true)
			keystats.flush()
			helpers.assert_eq(#calls.media, 1, "the waiting press is written once the store opens")
			helpers.assert_eq(calls.media[1].events[1].media_id, "media.play_pause")
		end)
	end)

	Home.it("retains a refused media batch for the next flush", function()
		with_keystats({}, function(keystats, calls)
			local writer = package.loaded["modules.keystats.sqlite_writer"]
			local start = writer.start_flush
			writer.start_flush = function() return nil end
			helpers.assert_true(keystats.record_media_press("app", KEY_PLAYPAUSE, DEVICE))
			keystats.flush()
			helpers.assert_eq(#calls.media, 0, "a refused dispatch writes nothing")
			writer.start_flush = start
			helpers.assert_true(keystats.record_media_press("app", KEY_NEXTSONG, DEVICE))
			keystats.flush()
			helpers.assert_eq(#calls.media, 1)
			helpers.assert_eq({ calls.media[1].events[1].media_id, calls.media[1].events[2].media_id },
				{ "media.play_pause", "media.next_track" }, "the refused press comes first, then the newer one")
		end)
	end)
end)
