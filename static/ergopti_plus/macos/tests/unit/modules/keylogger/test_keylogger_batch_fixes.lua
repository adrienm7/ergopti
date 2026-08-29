--- tests/unit/modules/keylogger/test_keylogger_batch_fixes.lua

--- ==============================================================================
--- MODULE: Regressions — four keylogger defects on the ingest and drain paths
--- DESCRIPTION:
--- 1. karabiner_press events were written to the log and dropped on ingest: the
---    system-event walker had branches for manifest_increment, focus_first_key,
---    modifier_hold and karabiner_release, and none for the press. With the
---    shipped tap/hold defaults the keys the bridge owns — Return, Backspace,
---    Tab, Delete — are also suppressed on the typing path, so they vanished
---    from the keycode heatmap entirely.
--- 2. kc_bridge is a fourth keylogger writer and carried NEITHER guard: no pause
---    predicate and no privacy predicate anywhere in the file, so physical key
---    press/release kept reaching today.log while a password field had focus.
--- 3. The three flush sites that RETURN early (two mouse branches, the shortcut
---    branch) never re-seeded the delay baseline that flush_buffer zeroes, so the
---    next real keystroke recorded a zero-millisecond gap.
--- 4. The app-category lookup ran a running-application scan plus an Info.plist
---    read per app, per ingest tick, inside the open SQLite write transaction.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("aggregator: a Karabiner press reaches the keycode heatmap", function()

	helpers.it("credits kc_ngram for a karabiner_press event", function()
		package.loaded["modules.keylogger.aggregator.events"] = nil
		local Events = helpers.load_with_stubs("modules.keylogger.aggregator.events")
		local S      = require("modules.keylogger.aggregator.state")
		local C      = require("modules.keylogger.aggregator.core")

		S.initialized = true
		S.device_id   = "dev-heatmap"
		C.reset_batch()

		Events.walk_system_event({
			timestamp = "2026-07-29 10:00:00.000",
			action    = "karabiner_press",
			keycode   = 36,
			app       = "TestApp",
		})

		local found = false
		for _, row in pairs(S.agg_batch.kc_ngram or {}) do
			if row.keycode == 36 and (row.count or 0) > 0 then found = true end
		end
		helpers.assert_true(found,
			"the bridge logs the press and the walker must credit it; without a branch the "
			.. "event is written and then silently dropped, and these keycodes have no other "
			.. "route into the heatmap")
	end)

	helpers.it("keeps app and keycode components distinct across ambiguous spellings", function()
		package.loaded["modules.keylogger.aggregator.events"] = nil
		local Events = helpers.load_with_stubs("modules.keylogger.aggregator.events")
		local S      = require("modules.keylogger.aggregator.state")
		local C      = require("modules.keylogger.aggregator.core")

		S.initialized = true
		S.device_id   = "dev-heatmap"
		C.reset_batch()
		for _, event in ipairs({
			{ app = "VLC", keycode = 12 },
			{ app = "VLC1", keycode = 2 },
		}) do
			Events.walk_system_event({
				timestamp = "2026-08-26 10:00:00.000",
				action = "karabiner_press",
				app = event.app,
				keycode = event.keycode,
			})
		end

		local rows = {}
		for _, row in pairs(S.agg_batch.kc_ngram or {}) do
			rows[row.app .. ":" .. tostring(row.keycode)] = row.count
		end
		helpers.assert_eq(rows, { ["VLC:12"] = 1, ["VLC1:2"] = 1 },
			"the 0x01 component sentinel must prevent app/keycode concatenation collisions")
	end)

end)

helpers.describe("kc_bridge: the physical-key writers respect pause and privacy", function()

	helpers.it("consults a guard before persisting", function()
		local src = helpers.read_driver_source("log_karabiner_press")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the kc_bridge source must be readable or this asserts nothing")
		local code = src:gsub("%-%-[^\n]*", "")
		helpers.assert_true(code:find("may_persist()", 1, true) ~= nil,
			"this is a fourth writer into the same sink and it had neither a pause guard nor a "
			.. "privacy guard, so key events reached the log while a password field had focus")
	end)

	helpers.it("still advances its bookkeeping when the guard refuses", function()
		local src = helpers.read_driver_source("may_persist")
		local at  = src:find("local function may_persist", 1, true)
		helpers.assert_not_nil(at, "the guard must exist")
		local doc = src:sub(math.max(1, at - 700), at)
		helpers.assert_true(doc:find("offset", 1, true) ~= nil,
			"refusing to persist must not stop the file offset advancing, or the skipped lines "
			.. "come back as a backlog the moment logging resumes")
	end)

end)

helpers.describe("keylogger: an early-returning flush re-seeds the delay baseline", function()

	helpers.it("every flush that returns also assigns last_time", function()
		local src = helpers.read_driver_source("session_mouse_scrolls")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the keylogger source must be readable or this asserts nothing")
		-- Anchored on the branch's own increment, not the bare field name: the
		-- state-table initialiser mentions it hundreds of lines earlier and a
		-- window from there reaches nothing.
		local at = src:find("CoreState.session_mouse_scrolls = CoreState.session_mouse_scrolls + 1", 1, true)
		helpers.assert_not_nil(at, "the scroll branch must exist")
		local block = src:sub(at, at + 500)
		helpers.assert_true(block:find("CoreState.last_time = now", 1, true) ~= nil,
			"flush_buffer zeroes the baseline and this branch returns before the keystroke "
			.. "path assigns it, so the next keystroke measures its delay against zero")
	end)

end)

helpers.describe("export: the app category is resolved once per app, not per tick", function()

	helpers.it("caches the resolved category", function()
		local src = helpers.read_driver_source("get_native_app_category")
		local code = src:gsub("%-%-[^\n]*", "")
		helpers.assert_true(code:find("_category_cache", 1, true) ~= nil,
			"the lookup runs a running-application scan plus an Info.plist read, per app, per "
			.. "ingest tick, inside the open SQLite write transaction")
	end)

end)
