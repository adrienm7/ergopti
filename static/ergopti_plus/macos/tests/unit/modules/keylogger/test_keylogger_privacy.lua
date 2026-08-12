--- tests/unit/modules/keylogger/test_keylogger_privacy.lua

--- ==============================================================================
--- MODULE: Keylogger Privacy Invariant Tests
--- DESCRIPTION:
--- Verifies the security guarantee that passwords, API keys, and 2FA codes
--- are never persisted by the keylogger when the correct privacy filters are
--- active. Each test case corresponds to a vector in:
---   static/ergopti_plus/_shared/tests/corpus/security/keylogger_no_persist_vectors.json
---
--- F-HIGH-15 (false-green test): earlier revisions of this file drove a
--- hand-copied push_char() harness that only replicated 4 of the real
--- handle_key()'s 6 guard stages — missing is_paused() and the disabled_apps
--- check entirely, so those two invariants had zero behavioral coverage
--- despite the corpus "passing". This file now loads the real
--- modules.keylogger.init module via tests.helpers.load_with_stubs and drives
--- the actual production handle_key callback (captured off the real
--- hs.eventtap.new() call in M.start()), so every guard — including pause and
--- disabled_apps — is exercised as production code, not a re-implementation.
---
--- FEATURES & RATIONALE:
--- 1. Secure Field Guard: CoreState.is_secure_field=true must prevent any
---    buffer mutation or log entry from being produced (SEC-001 through SEC-003).
--- 2. System Auth Guard: SYSTEM_AUTH_BUNDLE_IDS must block keystrokes typed
---    into macOS SecurityAgent and CoreAuthUI dialogs (SEC-004, SEC-005).
--- 3. Private Browsing Guard: CoreState.is_private_window=true must suppress
---    all keystroke logging (SEC-006).
--- 4. Normal-field invariant: ordinary text IS logged (SEC-007), confirming the
---    guard is not accidentally suppressing all events.
--- 5. Buffer flush on field transition: buffered text from a normal field is
---    flushed before the secure session begins; nothing from the secure session
---    leaks into that flush (SEC-008).
--- 6. Pause guard: script_control.is_paused()=true must block handle_key before
---    any buffer mutation, flushing whatever was already buffered (previously
---    only covered by a source-order string check in test_pause_guard_position.lua).
--- 7. Disabled-apps guard: CoreState.disabled_apps entries must drop keystrokes
---    for the matching bundle/path (previously entirely uncovered).
--- ==============================================================================

local helpers = require("tests.helpers")





-- ============================================
-- ============================================
-- ======= 1/ Real handle_key() Harness =======
-- ============================================
-- ============================================

-- Timings stub shared by every scenario load: returns fixed values so the
-- harness never depends on the real _shared/modules/timings/constants.toml
-- file being reachable from the unit-test cwd (mirrors test_log_manager.lua).
local _TIMINGS_MS = {
	keylogger = {
		max_keystroke_delay_ms = 5000,
		synth_match_delay_ms   = 3,
	},
}

local OWN_PID     = 7001
local FOREIGN_PID = 8002
local SOURCE_PID_PROPERTY = 1
local USER_DATA_PROPERTY = 2

--- Loads a fresh, fully-wired modules.keylogger.init with every I/O sub-module
--- stubbed in-memory (mirrors the stubbing already established for
--- modules.keylogger.log_manager tests), then starts it and captures both the
--- real handle_key callback (off the hs.eventtap.new() call) and a live
--- reference to the module's private CoreState table (captured via the
--- modules.keylogger.context_tracker.init(core_state, ...) hook — the only
--- place CoreState crosses a stubbable module boundary).
--- @return table session A handle exposing:
---   handle_key(event) — invokes the real production event-tap callback.
---   core_state() — returns the live reference to the module's CoreState.
---   appended — the list of entries persisted via Rotation.append_log (i.e.
---     what actually reached the log on flush/rollover).
---   set_paused(bool) — controls the script_control.is_paused() stub.
---   set_disabled_apps(apps) — delegates to the real M.set_disabled_apps.
---   stop() — flushes the buffer and stops the engine.
local function start_real_keylogger()
	local captured_handle_key = nil
	local captured_core_state = nil
	local appended_entries    = {}

	package.loaded["modules.keylogger.rotation"] = {
		init             = function() end,
		is_initialized   = function() return true end,
		append_log       = function(e) table.insert(appended_entries, e) end,
		read_new_entries = function() return {}, 0 end,
		get_offset       = function() return 0 end,
		get_date         = function() return os.date("%Y-%m-%d") end,
		set_offset       = function() end,
		rollover         = function() end,
	}
	package.loaded["modules.keylogger.sqlite_writer"] = {
		init                  = function() end,
		open_db               = function() return true end,
		close_db              = function() end,
		get_db                = function() return nil end,
		build_inserts         = function() return {} end,
		get_next_event_id     = function() return 0 end,
		set_next_event_id     = function() end,
		persist_next_event_id = function() end,
	}
	package.loaded["modules.keylogger.aggregator"] = {
		init               = function() end,
		walk_typing        = function() end,
		walk_app_switch    = function() end,
		walk_window_switch = function() end,
		walk_system_event  = function() end,
		flush              = function() end,
		get_ngram_ctx       = function() return {} end,
		set_ngram_ctx       = function() end,
		reset_ngram_ctx     = function() end,
	}
	package.loaded["modules.keylogger.export"] = {
		init                    = function() end,
		get_native_app_category = function() return "other" end,
		get_device_short_id     = function() return "abcd" end,
		get_sqlite_path         = function() return "/tmp/test.sqlite" end,
		get_db_rev              = function() return 0 end,
		sync_foreign_data_sql   = function() end,
	}
	package.loaded["infra.i18n"] = { t = function(key) return key end, get = function(key) return key end }
	package.loaded["infra.timings"] = {
		ms  = function(section, key) return (_TIMINGS_MS[section] or {})[key] or 1000 end,
		sec = function(_section, _key) return 1.0 end,
	}

	-- CoreState never crosses a public accessor in init.lua; capture the exact
	-- live reference at the one point it is handed to a stubbable sub-module.
	package.loaded["modules.keylogger.context_tracker"] = {
		init                   = function(core_state, _log_manager) captured_core_state = core_state end,
		update_private_status  = function() end,
		app_watcher_cb         = function() end,
		update_ax_observer     = function() end,
	}
	-- The production engine owns the raw event tap through KeyboardHook. Capture
	-- its onEvent callback at that boundary rather than relying on the retired
	-- direct hs.eventtap.new() ownership in keylogger/init.lua.
	package.loaded["adapters.keyboard_hook"] = {
		start = function(opts) captured_handle_key = opts and opts.onEvent end,
		stop = function() end,
		isRunning = function() return true end,
	}

	-- Force a fresh require of every sub-module that holds its own _state so a
	-- prior scenario's M.init() cannot leak into this one (each is a singleton).
	package.loaded["modules.keylogger.log_manager"] = nil
	package.loaded["modules.keylogger.kc_bridge"]   = nil
	package.loaded["modules.keylogger.watchers"]    = nil

	local hs_overrides = {
		processInfo = { processID = OWN_PID },
		application = {
			watcher = {
				new       = function() return { start = function() end, stop = function() end } end,
				activated = 1,
			},
			frontmostApplication = function()
				return {
					title      = function() return "TestApp" end,
					mainWindow = function() return nil end,
					pid        = function() return 123 end,
					bundleID   = function() return "com.example.TestApp" end,
				}
			end,
		},
		caffeinate = { watcher = { new = function() return { start = function() end, stop = function() end } end } },
		timer = {
			doAfter      = function(_delay, fn) fn() end,
			doEvery      = function() return { start = function() end, stop = function() end } end,
			new          = function() return { start = function() end, stop = function() end } end,
			delayed      = {
				new = function(_delay, fn)
					return {
						start = function(self) fn(); return self end,
						stop = function(self) return self end,
					}
				end,
			},
			secondsSinceEpoch = function() return 1 end,
			-- Must be strictly monotonic: handle_key gates its one-shot
			-- session_start log on `session_start_time == 0`, so a clock stuck at
			-- a constant value (e.g. always 0) re-triggers "session_start" on
			-- every single keystroke instead of once per session.
			absoluteTime = (function()
				-- One millisecond deliberately exercises the production <3 ms race:
				-- speed is not proof that an event is synthetic.
				local KEYSTROKE_STEP_NS = 1 * 1000000
				local t = 0
				return function()
					t = t + KEYSTROKE_STEP_NS
					return t
				end
			end)(),
		},
		fs = {
			attributes = function() return nil end,
			dir        = function() return function() return nil end end,
		},
		keycodes = { currentLayout = function() return "ABC" end },
		execute  = function() return "" end,
	}

	local saved_file_system = package.loaded["adapters.file_system"]
	package.loaded["adapters.file_system"] = {
		write = function() return true end,
		read = function() return nil end,
	}
	local km = helpers.load_with_stubs("modules.keylogger.init", hs_overrides)
	package.loaded["adapters.file_system"] = saved_file_system
	local synthetic_input = require("adapters.synthetic_input")
	local is_paused = false
	local script_control = { is_paused = function() return is_paused end }
	km.start(script_control)

	return {
		handle_key      = function(...) return captured_handle_key(...) end,
		core_state      = function() return captured_core_state end,
		appended        = appended_entries,
		set_paused      = function(v) is_paused = v end,
		set_disabled_apps = km.set_disabled_apps,
		stop            = km.stop,
		-- The two SYNTHETIC routes into the same sink. handle_key was the only
		-- entry point this harness could drive, which is precisely why the context
		-- filters were never checked on the other two.
		notify_synthetic = km.notify_synthetic,
		log_hotstring    = km.log_hotstring,
		new_owned_tag = function(modifiers, key)
			local tx = synthetic_input.begin("test.keylogger-privacy", "replacement")
			local batch = synthetic_input.begin_callback(tx)
			synthetic_input.keyStroke(batch, modifiers or {}, key)
			local _, events = synthetic_input.finish_callback(batch, true)
			synthetic_input.seal(tx)
			return events[1]:getProperty(USER_DATA_PROPERTY)
		end,
	}
end

--- Builds a fake hs.eventtap keyDown event carrying exactly one character.
--- @param char string The composed character this keystroke produces.
--- @param keycode number|nil The physical keycode (defaults to 0 — ordinary letter).
--- @return table A minimal event object satisfying handle_key's getters.
local function fake_key_event(char, keycode, source_pid, flags, user_data)
	return {
		getType       = function() return 10 end, -- keyDown
		getKeyCode    = function() return keycode or 0 end,
		getFlags      = function() return flags or {} end,
		getCharacters = function(_raw) return char end,
		getProperty   = function(_self, property)
			if property == USER_DATA_PROPERTY then return user_data or 0 end
			helpers.assert_eq(property, SOURCE_PID_PROPERTY,
				"production may read eventSourceUnixProcessID only as diagnostics")
			return source_pid or FOREIGN_PID
		end,
	}
end

--- Types `text` through the real handle_key(), one keyDown event per character,
--- then stops the engine (flushing any remaining buffer) and returns every
--- entry that reached Rotation.append_log — i.e. what actually got persisted.
--- @param overrides table|nil CoreState field overrides applied before typing
--- (is_secure_field, is_private_window, active_app_bundle, disabled_apps).
--- @param text string The characters to type.
--- @return table appended_entries Entries persisted via Rotation.append_log.
local function type_through_real_pipeline(overrides, text)
	local session = start_real_keylogger()
	local state = session.core_state()

	if overrides then
		if overrides.is_secure_field   ~= nil then state.is_secure_field   = overrides.is_secure_field   end
		if overrides.is_private_window ~= nil then state.is_private_window = overrides.is_private_window end
		if overrides.active_app_bundle ~= nil then state.active_app_bundle = overrides.active_app_bundle end
		if overrides.disabled_apps     ~= nil then session.set_disabled_apps(overrides.disabled_apps)     end
	end

	for char in text:gmatch(".") do
		session.handle_key(fake_key_event(char))
	end

	session.stop()
	return session.appended
end

--- Counts how many "typing" entries are present in a set of appended log entries.
--- @param entries table Entries returned by type_through_real_pipeline.
--- @return number count The number of typing-type entries.
local function count_typing_entries(entries)
	local count = 0
	for _, e in ipairs(entries) do
		if e.type == "typing" then count = count + 1 end
	end
	return count
end




-- ==============================================
-- ==============================================
-- ======= 2/ Corpus JSON vector runner =========
-- ==============================================
-- ==============================================

-- Load the shared security corpus so vector definitions stay in one place.
-- The corpus path is two levels above the HS driver root: _shared/ lives at
-- static/ergopti_plus/_shared/ while we are under static/ergopti_plus/macos/.
local _corpus_path = helpers.shared("tests/corpus/security/keylogger_no_persist_vectors.json")

--- Reads and JSON-decodes the corpus file.
--- @return table|nil corpus, string|nil err
local function load_corpus()
	local fh = io.open(_corpus_path, "r")
	if not fh then
		return nil, "cannot open corpus at " .. _corpus_path
	end
	local raw = fh:read("*a")
	fh:close()
	-- Reuse the hs.json.decode stub that the test harness provides
	helpers.load_with_stubs("infra.logger")
	local ok, decoded = pcall(require("hs").json.decode, raw)
	if not ok then return nil, "JSON parse error: " .. tostring(decoded) end
	return decoded, nil
end

local _corpus, _corpus_err = load_corpus()

helpers.describe("corpus: keylogger_no_persist_vectors.json — guard invariants", function()

	helpers.it("corpus file loaded successfully", function()
		helpers.assert_true(_corpus ~= nil,
			"failed to load corpus: " .. tostring(_corpus_err))
		helpers.assert_true(type(_corpus.vectors) == "table",
			"corpus.vectors must be a table")
	end)

	if not _corpus then return end

	for _, vec in ipairs(_corpus.vectors) do
		local id  = vec.id  or "?"
		local inp = vec.input or {}
		local exp = vec.expected or {}

		-- Skip AHK-only vectors (no Hammerspoon equivalent)
		if inp.driver == "autohotkey" then goto next_vec end

		-- Skip sequence vectors — SEC-008 has a multi-step input handled by the
		-- dedicated inline test below; the corpus entry serves as documentation only
		if type(inp.sequence) == "table" then goto next_vec end

		do
			local vec_id  = id
			local vec_inp = inp
			local vec_exp = exp

			helpers.it(string.format("%s — %s", vec_id, vec.description or ""), function()
				local overrides = {
					is_secure_field   = vec_inp.is_secure_field,
					is_private_window = vec_inp.is_private_window,
					active_app_bundle = vec_inp.active_app_bundle,
				}
				local text    = vec_inp.text or ""
				local entries = type_through_real_pipeline(overrides, text)
				local typing  = count_typing_entries(entries)

				if vec_exp.events_persisted == 0 then
					helpers.assert_eq(typing, 0,
						string.format("%s: expected 0 typing entries but got %d", vec_id, typing))
				else
					-- events_persisted > 0 means the text SHOULD enter the buffer
					helpers.assert_true(typing > 0,
						string.format("%s: expected a typing entry but none was persisted", vec_id))
				end
			end)
		end

		::next_vec::
	end
end)




-- ==========================================================
-- ==========================================================
-- ======= 3/ SEC-001 to SEC-003: Secure Field Guard ========
-- ==========================================================
-- ==========================================================

helpers.describe("SEC-001..003 — secure field guard", function()

	helpers.it("SEC-001: password characters never reach the log when is_secure_field=true", function()
		local entries = type_through_real_pipeline({ is_secure_field = true }, "password123")
		helpers.assert_eq(count_typing_entries(entries), 0)
	end)

	helpers.it("SEC-002: API key never reaches the log when field is secure", function()
		local entries = type_through_real_pipeline({ is_secure_field = true }, "sk-abc123XYZ987")
		helpers.assert_eq(count_typing_entries(entries), 0)
	end)

	helpers.it("SEC-003: 2FA / TOTP code never reaches the log when field is secure", function()
		local entries = type_through_real_pipeline({ is_secure_field = true }, "847291")
		helpers.assert_eq(count_typing_entries(entries), 0)
	end)

end)





-- ===============================================================
-- ===============================================================
-- ======= 4/ SEC-004 to SEC-005: System Auth Dialog Guard =======
-- ===============================================================
-- ===============================================================

helpers.describe("SEC-004..005 — system auth dialog guard", function()

	helpers.it("SEC-004: keystrokes in SecurityAgent are dropped unconditionally", function()
		local entries = type_through_real_pipeline({
			active_app_bundle = "com.apple.SecurityAgent",
			is_secure_field   = false,
		}, "adminpassword")
		helpers.assert_eq(count_typing_entries(entries), 0)
	end)

	helpers.it("SEC-005: keystrokes in CoreAuthUI are dropped unconditionally", function()
		local entries = type_through_real_pipeline({
			active_app_bundle = "com.apple.CoreAuthUI",
			is_secure_field   = false,
		}, "pin1234")
		helpers.assert_eq(count_typing_entries(entries), 0)
	end)

end)




-- ===========================================================
-- ===========================================================
-- ======= 5/ SEC-006: Private Browsing Guard ================
-- ===========================================================
-- ===========================================================

helpers.describe("SEC-006 — private browsing guard", function()

	helpers.it("SEC-006: keystrokes are dropped when is_private_window=true", function()
		local entries = type_through_real_pipeline({
			is_private_window = true,
			is_secure_field   = false,
		}, "hello world")
		helpers.assert_eq(count_typing_entries(entries), 0)
	end)

end)





-- ============================================================
-- ============================================================
-- ======= 6/ SEC-007: Normal Field — Events Are Logged =======
-- ============================================================
-- ============================================================

helpers.describe("SEC-007 — normal field: events ARE logged", function()

	helpers.it("SEC-007: ordinary text populates the log when no privacy guard is active", function()
		local text    = "hello world"
		local entries = type_through_real_pipeline({}, text)
		-- Exactly one typing entry, carrying the full typed text
		helpers.assert_eq(count_typing_entries(entries), 1)
		local typing_entry = nil
		for _, e in ipairs(entries) do if e.type == "typing" then typing_entry = e end end
		helpers.assert_true(typing_entry ~= nil, "a typing entry must be present")
		helpers.assert_eq(typing_entry.text, text)
	end)

end)




-- ==============================================================
-- ==============================================================
-- ======= 7/ SEC-008: Buffer Flush on Field Transition =========
-- ==============================================================
-- ==============================================================

helpers.describe("SEC-008 — field transition: normal text flushed, secure text never logged", function()

	helpers.it("SEC-008: normal text is flushed before transition; secure text never reaches the log", function()
		local session = start_real_keylogger()
		local state = session.core_state()

		-- Phase 1: user types a username in a normal field. Deliberately free of
		-- '.', '?', '!' — handle_key flushes on sentence-ending punctuation, which
		-- would otherwise split this single burst into multiple typing entries
		-- and defeat the "exactly one entry" assertion below.
		local username = "myusername123"
		for char in username:gmatch(".") do
			session.handle_key(fake_key_event(char))
		end

		-- Phase 2: field transitions to secure — a real app would flush here.
		-- context_tracker normally does this on every app switch/AX transition;
		-- we drive the exact same LogManager.flush_buffer() call the production
		-- field-transition path uses, via M.stop()+M.start() being overkill —
		-- instead call flush_buffer through the log_manager module directly,
		-- exactly like ContextTracker would on a field transition.
		require("modules.keylogger.log_manager").flush_buffer()
		state.is_secure_field = true

		-- Phase 3: user types password in the secure field — must not enter the log
		for char in ("mysecretpassword"):gmatch(".") do
			session.handle_key(fake_key_event(char))
		end

		session.stop()

		local typing_entries = {}
		for _, e in ipairs(session.appended) do
			if e.type == "typing" then table.insert(typing_entries, e) end
		end

		helpers.assert_eq(#typing_entries, 1,
			"exactly one typing entry must be persisted — the flushed normal-field text")
		helpers.assert_eq(typing_entries[1].text, username)
		-- Nothing from the secure session leaked into any entry
		for _, e in ipairs(typing_entries) do
			helpers.assert_true(not e.text:find("mysecretpassword", 1, true),
				"secure-field text must never appear in a persisted typing entry")
		end
	end)

end)




-- ==================================================================
-- ==================================================================
-- ======= 8/ Filter Toggle Integrity — Disabled Guards ==============
-- ==================================================================
-- ==================================================================

helpers.describe("filter toggles — disabling a guard allows logging to resume", function()

	helpers.it("turning OFF secure_field_filter allows keystrokes in secure fields (user opt-out)", function()
		local session = start_real_keylogger()
		local state = session.core_state()
		state.is_secure_field             = true
		state.secure_field_filter_enabled  = false -- user disabled the guard
		session.handle_key(fake_key_event("a"))
		session.stop()
		helpers.assert_eq(count_typing_entries(session.appended), 1)
	end)

	helpers.it("turning OFF system_auth_filter allows logging in auth dialogs (user opt-out)", function()
		local session = start_real_keylogger()
		local state = session.core_state()
		state.active_app_bundle          = "com.apple.SecurityAgent"
		state.system_auth_filter_enabled = false -- user disabled the guard
		session.handle_key(fake_key_event("x"))
		session.stop()
		helpers.assert_eq(count_typing_entries(session.appended), 1)
	end)

	helpers.it("turning OFF private_filter allows logging in private windows (user opt-out)", function()
		local session = start_real_keylogger()
		local state = session.core_state()
		state.is_private_window  = true
		state.private_filter_enabled = false -- user disabled the guard
		session.handle_key(fake_key_event("y"))
		session.stop()
		helpers.assert_eq(count_typing_entries(session.appended), 1)
	end)

end)




-- ======================================================================
-- ======================================================================
-- ======= 9/ Pause Guard — Previously Uncovered (F-HIGH-15) ===========
-- ======================================================================
-- ======================================================================

helpers.describe("pause guard — script_control.is_paused() blocks handle_key (F-HIGH-15)", function()

	helpers.it("keystrokes typed while paused never reach the log", function()
		local session = start_real_keylogger()
		session.set_paused(true)
		session.handle_key(fake_key_event("s"))
		session.handle_key(fake_key_event("e"))
		session.handle_key(fake_key_event("c"))
		session.stop()
		helpers.assert_eq(count_typing_entries(session.appended), 0,
			"handle_key must drop every keystroke while script_control.is_paused() is true")
	end)

	helpers.it("pausing mid-session flushes the already-buffered text but blocks anything typed after", function()
		local session = start_real_keylogger()
		session.handle_key(fake_key_event("h"))
		session.handle_key(fake_key_event("i"))

		session.set_paused(true)
		session.handle_key(fake_key_event("z")) -- must not reach the buffer

		session.stop()

		local typing_entries = {}
		for _, e in ipairs(session.appended) do
			if e.type == "typing" then table.insert(typing_entries, e) end
		end
		helpers.assert_eq(#typing_entries, 1,
			"exactly one typing entry: the pre-pause buffer, flushed by the pause guard itself")
		helpers.assert_eq(typing_entries[1].text, "hi",
			"the flushed entry must contain only the pre-pause text — 'z' must never appear")
	end)

	helpers.it("resuming from pause allows logging again", function()
		local session = start_real_keylogger()
		session.set_paused(true)
		session.handle_key(fake_key_event("q")) -- dropped while paused
		session.set_paused(false)
		session.handle_key(fake_key_event("r")) -- must be logged now
		session.stop()

		local typing_entries = {}
		for _, e in ipairs(session.appended) do
			if e.type == "typing" then table.insert(typing_entries, e) end
		end
		helpers.assert_eq(#typing_entries, 1)
		helpers.assert_eq(typing_entries[1].text, "r",
			"only the post-resume keystroke must appear — the paused 'q' must never leak in")
	end)

end)





-- ==========================================================================
-- ==========================================================================
-- ======= 10/ Disabled-apps Guard — Previously Uncovered (F-HIGH-15) =======
-- ==========================================================================
-- ==========================================================================

helpers.describe("disabled-apps guard — CoreState.disabled_apps blocks matching apps (F-HIGH-15)", function()

	helpers.it("keystrokes in a bundleID-disabled app never reach the log", function()
		local entries = type_through_real_pipeline({
			active_app_bundle = "com.example.TestApp",
			disabled_apps     = { { bundleID = "com.example.TestApp" } },
		}, "secretnote")
		helpers.assert_eq(count_typing_entries(entries), 0,
			"a bundleID match in CoreState.disabled_apps must drop every keystroke")
	end)

	helpers.it("keystrokes in a non-disabled app are unaffected by an unrelated disabled_apps entry", function()
		local entries = type_through_real_pipeline({
			active_app_bundle = "com.example.TestApp",
			disabled_apps     = { { bundleID = "com.other.App" } },
		}, "hello")
		helpers.assert_eq(count_typing_entries(entries), 1,
			"disabled_apps must only match its own bundleID/appPath — other apps keep logging")
	end)

	helpers.it("an empty disabled_apps list logs normally (no accidental blanket block)", function()
		local entries = type_through_real_pipeline({
			active_app_bundle = "com.example.TestApp",
			disabled_apps     = {},
		}, "hello")
		helpers.assert_eq(count_typing_entries(entries), 1)
	end)

end)





-- ==================================================================
-- ==================================================================
-- ======= 6/ The synthetic routes obey the same four filters =======
-- ==================================================================
-- ==================================================================

helpers.describe("synthetic echo provenance - only explicit owned tags are filtered", function()

	helpers.it("keeps private tagged AB echoes out after a 1 ms foreign mismatch", function()
		local session = start_real_keylogger()
		local state   = session.core_state()
		local tag_a = session.new_owned_tag({}, "a")
		local tag_b = session.new_owned_tag({}, "b")

		session.handle_key(fake_key_event("x", 0, FOREIGN_PID))
		helpers.assert_eq(state.buffer_text, "x", "the physical x must traverse the human path")

		session.handle_key(fake_key_event("A", 0, OWN_PID, nil, tag_a))
		session.handle_key(fake_key_event("B", 0, OWN_PID, nil, tag_b))
		helpers.assert_eq(state.buffer_text, "x",
			"explicitly tagged private echoes must never be persisted as physical text")
		session.stop()
	end)

	helpers.it("does not use exact character equality as synthetic identity", function()
		local session = start_real_keylogger()
		local state   = session.core_state()
		local owned_tag = session.new_owned_tag({}, "a")

		session.handle_key(fake_key_event("A", 0, FOREIGN_PID))
		helpers.assert_eq(state.buffer_text, "A", "the physical A must be recorded normally")

		session.handle_key(fake_key_event("A", 0, OWN_PID, nil, owned_tag))
		helpers.assert_eq(state.buffer_text, "A", "the own echo must be discarded")
		session.stop()
	end)

	helpers.it("requires an owned tag before filtering Backspace", function()
		local session = start_real_keylogger()
		local state   = session.core_state()
		local owned_tag = session.new_owned_tag({}, "delete")

		session.handle_key(fake_key_event("x", 0, FOREIGN_PID))
		session.handle_key(fake_key_event("", 51, FOREIGN_PID))
		local after_physical = state.buffer_text
		session.handle_key(fake_key_event("", 51, OWN_PID, nil, owned_tag))
		helpers.assert_eq(state.buffer_text, after_physical,
			"a tagged Backspace echo must not edit the human buffer a second time")
		session.stop()
	end)

	helpers.it("logs foreign Cmd+V but never a Cmd+V emitted by this process", function()
		local foreign = start_real_keylogger()
		foreign.handle_key(fake_key_event("v", 9, FOREIGN_PID, { cmd = true }))
		foreign.stop()
		local foreign_shortcuts = 0
		for _, entry in ipairs(foreign.appended) do
			if entry.type == "shortcut" then foreign_shortcuts = foreign_shortcuts + 1 end
		end
		helpers.assert_eq(foreign_shortcuts, 1, "a physical Cmd+V must remain user telemetry")

		local own = start_real_keylogger()
		local owned_tag = own.new_owned_tag({ "cmd" }, "v")
		own.handle_key(fake_key_event("v", 9, OWN_PID, { cmd = true }, owned_tag))
		own.stop()
		local own_shortcuts = 0
		for _, entry in ipairs(own.appended) do
			if entry.type == "shortcut" then own_shortcuts = own_shortcuts + 1 end
		end
		helpers.assert_eq(own_shortcuts, 0,
			"a Hammerspoon-emitted Cmd+V is synthetic even if tap callback order changed")
	end)

end)


--- Drives a SYNTHETIC expansion (not a keystroke) through the real engine under a
--- given context, and returns everything that reached the persistence layer.
---
--- handle_key was the only entry point the harness above could drive, and it is
--- the only one that ever applied the context filters. notify_synthetic and
--- log_hotstring are independent routes into the identical sink and gated solely
--- on is_enabled, so an expansion fired inside a password manager, a system-auth
--- prompt or an explicitly disabled app was persisted in full.
--- @param overrides table CoreState field overrides describing the context.
--- @param secret string The payload the expansion emits.
--- @return table appended Entries that reached Rotation.append_log.
local function expand_through_real_pipeline(overrides, secret)
	local session = start_real_keylogger()
	local state   = session.core_state()

	if overrides.is_secure_field   ~= nil then state.is_secure_field   = overrides.is_secure_field   end
	if overrides.is_private_window ~= nil then state.is_private_window = overrides.is_private_window end
	if overrides.active_app_bundle ~= nil then state.active_app_bundle = overrides.active_app_bundle end
	if overrides.disabled_apps     ~= nil then session.set_disabled_apps(overrides.disabled_apps)     end

	session.notify_synthetic(secret, "hotstring", 0, nil, secret)
	session.log_hotstring("trg", secret, "auto")
	session.stop()
	return session.appended
end

--- Asserts the payload appears nowhere in what was persisted.
--- @param entries table Appended entries.
--- @param secret string The payload that must be absent.
--- @param context_label string Which filter was under test, for the message.
local function assert_secret_absent(entries, secret, context_label)
	for _, e in ipairs(entries) do
		for _, field in ipairs({ "rich_text", "events_json", "tag", "replacement", "trigger", "text" }) do
			local v = e[field]
			if type(v) == "string" then
				helpers.assert_true(v:find(secret, 1, true) == nil,
					context_label .. ": the expansion payload reached the persisted '" .. field
					.. "' field — the synthetic route must honour the same filter as a keystroke")
			end
		end
	end
end

helpers.describe("context filters apply to synthetic expansions, not only to keystrokes", function()

	local SECRET = "ZZEXPANSIONSECRETZZ"

	helpers.it("a private window silences notify_synthetic and log_hotstring", function()
		local entries = expand_through_real_pipeline({ is_private_window = true }, SECRET)
		assert_secret_absent(entries, SECRET, "private window")
	end)

	helpers.it("a secure field silences them", function()
		local entries = expand_through_real_pipeline({ is_secure_field = true }, SECRET)
		assert_secret_absent(entries, SECRET, "secure field")
	end)

	helpers.it("a system-auth dialog silences them", function()
		local entries = expand_through_real_pipeline({ active_app_bundle = "com.apple.SecurityAgent" }, SECRET)
		assert_secret_absent(entries, SECRET, "system-auth dialog")
	end)

	helpers.it("a user-disabled app silences them", function()
		local entries = expand_through_real_pipeline({
			active_app_bundle = "com.example.Excluded",
			disabled_apps     = { { bundleID = "com.example.Excluded" } },
		}, SECRET)
		assert_secret_absent(entries, SECRET, "disabled app")
	end)

	helpers.it("an ordinary context still records the expansion (the filters are not a blanket block)", function()
		local entries = expand_through_real_pipeline({ active_app_bundle = "com.example.Allowed" }, SECRET)
		local found = false
		for _, e in ipairs(entries) do
			for _, field in ipairs({ "rich_text", "events_json", "tag", "replacement" }) do
				if type(e[field]) == "string" and e[field]:find(SECRET, 1, true) then found = true end
			end
		end
		helpers.assert_true(found,
			"without this case every assertion above would pass against a keylogger that "
			.. "records nothing at all")
	end)

end)
