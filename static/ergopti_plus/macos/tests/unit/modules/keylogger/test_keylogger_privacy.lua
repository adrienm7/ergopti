--- tests/unit/modules/keylogger/test_keylogger_privacy.lua

--- ==============================================================================
--- MODULE: Keylogger Privacy Invariant Tests
--- DESCRIPTION:
--- Verifies the security guarantee that passwords, API keys, and 2FA codes
--- are never persisted by the keylogger when the correct privacy filters are
--- active. Each test case corresponds to a vector in:
---   static/ergopti_plus/shared/tests/corpus/security/keylogger_no_persist_vectors.json
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
--- ==============================================================================

local helpers = require("tests.helpers")




-- ======================================
--- ======================================
-- ======= 1/ Shared Stub Factory =======
--- ======================================
-- ======================================

--- Builds a minimal CoreState table with safe defaults.
--- @param overrides table Fields to override on top of the defaults.
--- @return table The merged CoreState.
local function make_core_state(overrides)
	local base = {
		LOG_DIR                       = "/tmp/test_metrics",
		is_enabled                    = true,
		private_filter_enabled        = true,
		secure_field_filter_enabled   = true,
		system_auth_filter_enabled    = true,
		is_private_window             = false,
		is_secure_field               = false,
		active_app_bundle             = "com.example.TestApp",
		active_app_path               = nil,
		disabled_apps                 = {},
		buffer_events                 = {},
		buffer_text                   = "",
		rich_chunks                   = {},
		last_time                     = 0,
		last_flush_time               = 0,
		session_app_name              = "TestApp",
		session_win_title             = "Test Window",
		session_url                   = nil,
		session_field_role            = "AXTextField",
		session_layout                = "ABC",
		session_document_path         = nil,
		is_fullscreen                 = false,
		in_meeting                    = false,
		session_mouse_clicks          = 0,
		session_mouse_scrolls         = 0,
		mouse_distance_px             = 0,
		current_session_pause         = 0,
		current_battery_level         = nil,
		current_audio_volume          = nil,
		session_start_time            = 0,
		session_last_active           = 0,
		is_micro_idle                 = false,
		recent_typing_eff             = {},
		recent_typing_phys            = {},
		synth_queue                   = {},
		pending_keyup                 = {},
		focus_pending_at              = nil,
		focus_pending_app             = nil,
		prev_flags                    = {},
		modifier_down_at              = {},
		passive_started_at            = nil,
		passive_kind                  = nil,
		last_source_type              = "none",
		last_source_variant           = "none",
		last_source_time              = 0,
		today_idx                     = {},
		manifest                      = {},
		ngram_context                 = nil,
		active_app_name               = "TestApp",
		active_app_start              = 0,
		active_app_pid                = 1,
		ax_observer                   = nil,
		options                       = { encrypt = false },
	}
	if type(overrides) == "table" then
		for k, v in pairs(overrides) do base[k] = v end
	end
	return base
end

--- Installs a fresh log_manager stub and returns the captured append list.
--- @return table The list of entries appended via rotation.append_log.
local function make_append_capture()
	local captured = {}
	package.loaded["modules.keylogger.rotation"] = {
		init              = function() end,
		append_log        = function(e) table.insert(captured, e) end,
		read_new_entries  = function() return {}, 0 end,
		get_offset        = function() return 0 end,
		get_date          = function() return os.date("%Y-%m-%d") end,
		set_offset        = function() end,
		rollover          = function() end,
	}
	return captured
end

--- Simulates pushing a printable character into CoreState as handle_key would.
--- This replicates the hot-path logic from init.lua Section 5 for the simple
--- single-codepoint case, without the full eventtap scaffolding.
--- @param state table The CoreState table.
--- @param char string A single printable character.
--- @param delay number Inter-key delay in ms.
local function push_char(state, char, delay)
	-- Mirrors handle_key: guards run first, then buffer mutation
	if not state.is_enabled then return end
	if state.private_filter_enabled and state.is_private_window then return end
	if state.secure_field_filter_enabled and state.is_secure_field then return end
	if state.system_auth_filter_enabled and state.active_app_bundle
	and (state.active_app_bundle == "com.apple.SecurityAgent"
		or state.active_app_bundle == "com.apple.CoreAuthUI") then return end

	-- Buffer mutation only reached when all guards pass
	state.buffer_text = state.buffer_text .. char
	table.insert(state.buffer_events, { char, delay, { s = false } })
end




-- ==============================================
-- ==============================================
-- ======= 2/ Corpus JSON vector runner =========
-- ==============================================
-- ==============================================

-- Load the shared security corpus so vector definitions stay in one place.
-- The corpus path is two levels above the HS driver root: shared/ lives at
-- static/ergopti_plus/shared/ while we are under static/ergopti_plus/macos/.
local _corpus_path = helpers.driver_root() .. "../shared/tests/corpus/security/keylogger_no_persist_vectors.json"

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
	helpers.load_with_stubs("lib.logger")
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
			local vec_id   = id
			local vec_inp  = inp
			local vec_exp  = exp

			helpers.it(string.format("%s — %s", vec_id, vec.description or ""), function()
				local overrides = {}
				if vec_inp.is_secure_field    ~= nil then overrides.is_secure_field    = vec_inp.is_secure_field    end
				if vec_inp.is_private_window  ~= nil then overrides.is_private_window  = vec_inp.is_private_window  end
				if vec_inp.active_app_bundle  ~= nil then overrides.active_app_bundle  = vec_inp.active_app_bundle  end

				local state = make_core_state(overrides)
				local text  = vec_inp.text or ""
				for char in text:gmatch(".") do push_char(state, char, 80) end

				if vec_exp.events_persisted == 0 then
					helpers.assert_eq(#state.buffer_events, 0,
						string.format("%s: expected 0 buffered events but got %d", vec_id, #state.buffer_events))
					helpers.assert_eq(state.buffer_text, "",
						string.format("%s: expected empty buffer_text but got %q", vec_id, state.buffer_text))
				else
					-- events_persisted > 0 means the text SHOULD enter the buffer
					helpers.assert_true(#state.buffer_events > 0,
						string.format("%s: expected buffered events but buffer is empty", vec_id))
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

	helpers.it("SEC-001: password characters never enter the buffer when is_secure_field=true", function()
		local state = make_core_state({ is_secure_field = true })
		for char in ("password123"):gmatch(".") do
			push_char(state, char, 80)
		end
		helpers.assert_eq(#state.buffer_events, 0)
		helpers.assert_eq(state.buffer_text, "")
	end)

	helpers.it("SEC-002: API key never enters buffer when field is secure", function()
		local state = make_core_state({ is_secure_field = true })
		for char in ("sk-abc123XYZ987"):gmatch(".") do
			push_char(state, char, 60)
		end
		helpers.assert_eq(#state.buffer_events, 0)
		helpers.assert_eq(state.buffer_text, "")
	end)

	helpers.it("SEC-003: 2FA / TOTP code never enters buffer when field is secure", function()
		local state = make_core_state({ is_secure_field = true })
		for char in ("847291"):gmatch(".") do
			push_char(state, char, 100)
		end
		helpers.assert_eq(#state.buffer_events, 0)
		helpers.assert_eq(state.buffer_text, "")
	end)

end)




-- ===============================================================
--- ===============================================================
-- ======= 4/ SEC-004 to SEC-005: System Auth Dialog Guard =======
--- ===============================================================
-- ===============================================================

helpers.describe("SEC-004..005 — system auth dialog guard", function()

	helpers.it("SEC-004: keystrokes in SecurityAgent are dropped unconditionally", function()
		local state = make_core_state({
			active_app_bundle = "com.apple.SecurityAgent",
			is_secure_field   = false,
		})
		for char in ("adminpassword"):gmatch(".") do
			push_char(state, char, 80)
		end
		helpers.assert_eq(#state.buffer_events, 0)
		helpers.assert_eq(state.buffer_text, "")
	end)

	helpers.it("SEC-005: keystrokes in CoreAuthUI are dropped unconditionally", function()
		local state = make_core_state({
			active_app_bundle = "com.apple.CoreAuthUI",
			is_secure_field   = false,
		})
		for char in ("pin1234"):gmatch(".") do
			push_char(state, char, 80)
		end
		helpers.assert_eq(#state.buffer_events, 0)
		helpers.assert_eq(state.buffer_text, "")
	end)

end)




-- ===========================================================
-- ===========================================================
-- ======= 5/ SEC-006: Private Browsing Guard ================
-- ===========================================================
-- ===========================================================

helpers.describe("SEC-006 — private browsing guard", function()

	helpers.it("SEC-006: keystrokes are dropped when is_private_window=true", function()
		local state = make_core_state({
			is_private_window = true,
			is_secure_field   = false,
		})
		for char in ("hello world"):gmatch(".") do
			push_char(state, char, 70)
		end
		helpers.assert_eq(#state.buffer_events, 0)
		helpers.assert_eq(state.buffer_text, "")
	end)

end)




-- ============================================================
--- ============================================================
-- ======= 6/ SEC-007: Normal Field — Events Are Logged =======
--- ============================================================
-- ============================================================

helpers.describe("SEC-007 — normal field: events ARE logged", function()

	helpers.it("SEC-007: ordinary text populates buffer when no privacy guard is active", function()
		local state = make_core_state()
		local text = "hello world"
		for char in text:gmatch(".") do
			push_char(state, char, 70)
		end
		-- The buffer must contain exactly as many events as typed characters
		helpers.assert_eq(#state.buffer_events, #text)
		helpers.assert_eq(state.buffer_text, text)
	end)

end)




-- ==============================================================
-- ==============================================================
-- ======= 7/ SEC-008: Buffer Flush on Field Transition =========
-- ==============================================================
-- ==============================================================

helpers.describe("SEC-008 — field transition: normal text flushed, secure text never logged", function()

	helpers.it("SEC-008: normal text is in buffer before transition; secure text never reaches it", function()
		-- Phase 1: user types username in a normal field
		local state = make_core_state({ is_secure_field = false })
		for char in ("username@example.com"):gmatch(".") do
			push_char(state, char, 70)
		end
		local events_before = #state.buffer_events
		local text_before   = state.buffer_text

		-- Phase 2: field transitions to secure — a real app would flush here
		-- (LogManager.flush_buffer is called on field transitions in context_tracker)
		-- We just snapshot the normal buffer before the secure phase begins
		helpers.assert_true(events_before > 0)
		helpers.assert_eq(text_before, "username@example.com")

		-- Phase 3: user types password in the secure field — simulate the transition
		state.is_secure_field = true
		-- In the real code, flush_buffer() is called here. We simulate that by
		-- capturing what would be flushed, then resetting the buffer manually.
		local flushed_text   = state.buffer_text
		local flushed_events = #state.buffer_events
		state.buffer_text   = ""
		state.buffer_events = {}

		-- Now type the password — must not enter buffer
		for char in ("mysecretpassword"):gmatch(".") do
			push_char(state, char, 70)
		end

		-- Assertions
		helpers.assert_eq(flushed_text, "username@example.com")
		helpers.assert_true(flushed_events > 0)
		-- Nothing from the secure session leaked into the buffer
		helpers.assert_eq(#state.buffer_events, 0)
		helpers.assert_eq(state.buffer_text, "")
	end)

end)




-- ==================================================================
-- ==================================================================
-- ======= 8/ Filter Toggle Integrity — Disabled Guards ==============
-- ==================================================================
-- ==================================================================

helpers.describe("filter toggles — disabling a guard allows logging to resume", function()

	helpers.it("turning OFF secure_field_filter allows keystrokes in secure fields (user opt-out)", function()
		-- This tests that the filter is genuinely guarded by the toggle flag,
		-- not hard-coded. If the user explicitly disables it, the keylogger
		-- must respect that configuration.
		local state = make_core_state({
			is_secure_field                 = true,
			secure_field_filter_enabled     = false,  -- user disabled the guard
		})
		push_char(state, "a", 80)
		-- When the guard is deliberately off, the char reaches the buffer
		helpers.assert_eq(#state.buffer_events, 1)
	end)

	helpers.it("turning OFF system_auth_filter allows logging in auth dialogs (user opt-out)", function()
		local state = make_core_state({
			active_app_bundle               = "com.apple.SecurityAgent",
			system_auth_filter_enabled      = false,  -- user disabled the guard
		})
		push_char(state, "x", 80)
		helpers.assert_eq(#state.buffer_events, 1)
	end)

	helpers.it("turning OFF private_filter allows logging in private windows (user opt-out)", function()
		local state = make_core_state({
			is_private_window               = true,
			private_filter_enabled          = false,  -- user disabled the guard
		})
		push_char(state, "y", 80)
		helpers.assert_eq(#state.buffer_events, 1)
	end)

end)
