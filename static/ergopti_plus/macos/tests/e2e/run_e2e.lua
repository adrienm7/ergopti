--- tests/e2e/run_e2e.lua

--- ==============================================================================
--- MODULE: E2E Virtual-Keyboard Test Harness (Hammerspoon)
--- DESCRIPTION:
--- End-to-end test harness that validates the full hotstring expansion pipeline
--- by injecting synthetic keystrokes and asserting the emitted text, using the
--- same stub layer as the unit tests so the suite runs headlessly in CI.
---
--- DESIGN RATIONALE — WHY NO REAL hs.eventtap.keyStroke ON CI:
--- Hammerspoon is a macOS-only application that must be running as a UI process
--- to own an eventtap. GitHub Actions "macos-latest" runners do not expose a
--- Quartz WindowServer session to background jobs, so `hs.eventtap.keyStroke`
--- would silently no-op. The correct production E2E approach (see the companion
--- PLAN document at tests/e2e/PLAN_E2E_REAL_HS.md) requires a macOS machine
--- with an active GUI session and Hammerspoon loaded.
---
--- WHAT THIS HARNESS DOES INSTEAD:
--- It exercises the same *code paths* that a real keystroke would follow:
---   1. Characters are fed into the shared CoreState buffer one by one via the
---      same `process_char` callback that the live eventtap calls.
---   2. The Expander module runs its full matching + replacement logic.
---   3. SyntheticInput returns the exact tagged replacement events from the
---      simulated eventtap callback and posts reserved successors from its owned
---      process FIFO, as production does.
---   4. The harness captures both routes, replays the replacement against a
---      virtual screen, and verifies their immutable transaction provenance.
---   5. Assertions compare emitted text and logical replacement counts against
---      the shared corpus.
---
--- This gives 95% of the confidence of a real E2E run for the pure-logic layer,
--- and the companion PLAN document describes the remaining 5% (real OS injection).
---
--- USAGE:
---   lua5.4 tests/e2e/run_e2e.lua     # run from the hammerspoon driver root
--- ==============================================================================

-- ---------------------------------------------------------------------------
-- Bootstrap: resolve driver root from this file's own path, mirror run.lua.
-- ---------------------------------------------------------------------------
local self_path   = debug.getinfo(1, "S").source:gsub("^@", "")
local driver_root = self_path:match("^(.*)[/\\]tests[/\\]e2e[/\\]run_e2e%.lua$") or "."
driver_root = driver_root:gsub("\\", "/")

if driver_root == "." then
	local sep      = package.config:sub(1, 1)
	local cwd_cmd  = (sep == "\\") and "cd" or "pwd"
	local h        = io.popen(cwd_cmd)
	if h then
		local cwd = h:read("*l") or "."
		h:close()
		driver_root = cwd:gsub("\\", "/"):gsub("/$", "")
	end
end

local drivers_root = driver_root:match("^(.*)/[^/]+$") or driver_root
-- Single shared-tree root for this bootstrap harness; everything below derives
-- from it so a future rename of the _shared/ tree only touches this one literal.
local shared_root  = drivers_root .. "/_shared"
local shared_lua   = shared_root .. "/lua"
local corpus_path  = shared_root .. "/tests/corpus/hotstrings/vectors.json"

package.path = table.concat({
	driver_root .. "/?.lua",
	driver_root .. "/?/init.lua",
	shared_lua  .. "/?.lua",
	shared_lua  .. "/?/init.lua",
	driver_root .. "/tests/?.lua",
	driver_root .. "/tests/?/init.lua",
	driver_root .. "/tests/stubs/?.lua",
	package.path,
}, ";")


-- ---------------------------------------------------------------------------
-- Load helpers + stubs (same pattern as tests/run.lua).
-- ---------------------------------------------------------------------------
local helpers = require("tests.helpers")
local SyntheticStack = require("tests.support.synthetic_input_stack")





-- ======================================
-- ======================================
-- ======= 1/ Test Infrastructure =======
-- ======================================
-- ======================================

local pass_count = 0
local fail_count = 0
-- Vectors the corpus itself declares driver-specific. Counted and printed rather
-- than passed over quietly: a skip nobody sees is indistinguishable from
-- coverage.
local skip_count = 0

--- Asserts equality and records pass/fail.
--- @param label string Human-readable name for the assertion.
--- @param expected any Expected value.
--- @param actual any Actual value.
local function assert_eq(label, expected, actual)
	if expected == actual then
		pass_count = pass_count + 1
		print(string.format("  PASS  %s", label))
	else
		fail_count = fail_count + 1
		print(string.format("  FAIL  %s  expected=%s  got=%s",
			label, tostring(expected), tostring(actual)))
	end
end

--- Asserts a boolean condition.
--- @param label string Human-readable name for the assertion.
--- @param condition boolean The condition to test.
local function assert_true(label, condition)
	assert_eq(label, true, condition == true)
end


--- Reads and JSON-decodes the shared corpus file.
--- Requires the _shared/lua json module (tiny pure-Lua JSON parser).
--- @return table Array of vector tables.
local function load_corpus()
	local f, err = io.open(corpus_path, "r")
	if not f then
		error(string.format("Cannot open corpus at %s : %s", corpus_path, tostring(err)))
	end
	local raw = f:read("*a")
	f:close()
	-- Use the tiny JSON decoder available in the shared Lua library.
	local ok, json = pcall(require, "json")
	if not ok then
		error("Cannot load shared json module — check _shared/lua/json.lua exists.")
	end
	local decoded = json.decode(raw)
	return decoded.vectors
end





-- ===================================
-- ===================================
-- ======= 2/ Virtual Keyboard =======
-- ===================================
-- ===================================

--- Builds an isolated test environment: fresh stubs + Registry + Expander.
--- Returns a table with:
---   inject(buffer, char, mode)  — drives a terminator or auto-expand callback
---   emitted()                  — returns the concatenated emitted text
---   backspaces()               — returns logical codepoints replaced
--- @param trigger string The hotstring trigger to register.
--- @param replacement string The expansion text.
--- @param opts table Per-entry flags exactly as the shared corpus declares them
---   (is_word, auto_expand, is_case_sensitive, is_case_sensitive_strict,
---   final_result).
--- @return table Virtual keyboard context.
local function make_vkb(trigger, replacement, opts)
	opts = opts or {}

	-- Fresh stub environment for each scenario to prevent cross-test leakage.
	-- All keymap modules are cleared so they reload together under a single
	-- fresh hs stub (the one created by the final load_with_stubs call below).
	-- The emission adapters capture Quartz constructors at module-load time, so
	-- they MUST be in the same load wave as Expander.
	package.loaded["infra.logger"]                 = nil
	package.loaded["infra.text_utils"]             = nil
	package.loaded["infra.i18n"]                   = nil
	package.loaded["modules.keymap.terminators"] = nil
	package.loaded["modules.keymap.utils"]       = nil
	package.loaded["modules.keymap.registry"]    = nil
	package.loaded["modules.keymap.expander"]    = nil
	-- Expander delegates deletion to TextSender. It captures `hs` at module load
	-- time too, so it must be reloaded alongside the keymap modules.
	package.loaded["adapters.text_sender"]        = nil
	package.loaded["adapters.clipboard"]          = nil
	-- The terminator is no longer emitted inline by the expander: it is handed to
	-- TerminatorReplay, which holds it until the replacement has provably landed.
	-- That module is stateful (M.init refuses a second call, and it owns the
	-- pending slot), so it belongs in this reload wave for the same reason
	-- utils and text_sender do — a cached instance would keep the FIRST
	-- scenario's CoreState and answer "has the replacement landed?" from a
	-- transaction instance this scenario never created.
	package.loaded["modules.keymap.terminator_replay"] = nil

	-- Observe global FIFO posts before SyntheticInput captures newKeyEvent. A
	-- reserved terminator is deliberately activated in the callback but posted on
	-- a later timer turn, so callback-returned events alone are not the full output.
	package.loaded["tests.stubs.hs"] = nil
	local event_hs = require("tests.stubs.hs")
	event_hs.__reset()
	local posted_events = {}
	local native_new_key_event = event_hs.eventtap.event.newKeyEvent
	event_hs.eventtap.event.newKeyEvent = function(modifiers, key, is_down)
		local event = native_new_key_event(modifiers, key, is_down)
		local native_post = event.post
		event.post = function(self, app)
			posted_events[#posted_events + 1] = { event = self, app = app }
			return native_post(self, app)
		end
		return event
	end

	-- One load_with_stubs call establishes the canonical hs stub for this
	-- scenario; all dependencies cascade from the same require chain and share
	-- the same SyntheticInput ledger.
	local Expander, SyntheticInput = SyntheticStack.load("modules.keymap.expander", {
		eventtap = event_hs.eventtap,
	})
	local Registry = require("modules.keymap.registry")
	local text_utils = require("infra.text_utils")
	-- Required from the SAME load wave as Expander so the harness drives the very
	-- instance the expander armed — a second instance would hold an empty slot.
	local TerminatorReplay = require("modules.keymap.terminator_replay")

	-- Magic key sentinel — same value as the live driver.
	local MAGIC_KEY = "\xe2\x98\x85"

	-- Minimal CoreState that satisfies the Expander's require_state guard.
	local state = {
		buffer                     = "",
		magic_key                  = MAGIC_KEY,
		groups                     = {},
		current_group              = "e2e",
		-- Required by word_boundary_blocks: treat start-of-buffer as a word
		-- boundary so is_word triggers fire correctly when buffer = trigger.
		start_is_word_boundary     = true,
		-- No-op stubs for callbacks invoked by perform_text_replacement after a
		-- successful expansion. The E2E harness does not exercise these paths.
		suppress_rescan            = function() end,
	}

	Registry.init({
		magic_key                  = MAGIC_KEY,
		mappings                   = {},
		mappings_lookup            = {},
		mappings_by_tail_char      = {},
		mappings_by_star_tail_char = {},
		groups                     = {},
		seq_counter                = 0,
		current_group              = "e2e",
		start_is_word_boundary     = true,
	})
	-- Every per-entry flag, driven off a list. Naming a subset is how this harness
	-- came to register `is_case_sensitive_strict` vectors as ordinary ones and then
	-- report that macOS matched a casing the vector says it must not.
	local add_opts = { group = "e2e" }
	for _, flag in ipairs({ "is_word", "auto_expand", "is_case_sensitive",
		"is_case_sensitive_strict", "final_result" }) do
		add_opts[flag] = opts[flag] == true
	end
	Registry.add(trigger, replacement, add_opts)
	Registry.sort_mappings()

	-- Stub LLMBridge — Expander.init requires it but we never call LLM paths.
	local llm_stub = {
		request          = function() end,
		cancel           = function() end,
		set_buffer       = function() end,
		update_preview   = function() end,
		get_llm_enabled  = function() return false end,
		start_timer      = function() end,
	}

	Expander.init(state, Registry, llm_stub)

	-- Result cache populated by inject(); accessed by emitted() and backspaces().
	-- terminator_held records the ORDERING guarantee: true when the terminator was
	-- still pending in the replay gate at the moment the expansion returned, i.e.
	-- it did NOT race ahead of the replacement.
	local _result = {
		expanded = false,
		replacement = "",
		logical_bs = 0,
		terminator_held = false,
		provenance_ok = true,
		callback_replay_pairs = 0,
		posted_replay_pairs = 0,
		remaining_transactions = 0,
	}

	-- Drives one eventtap callback and replays only its returned, tagged events
	-- against a virtual screen. `mode="auto"` means `terminator` is the trigger's
	-- last character and has not reached the application; `mode="terminator"`
	-- means buffer_text already contains the full trigger and the external
	-- terminator is the callback's current physical event.
	local function inject(buffer_text, terminator, mode)
		mode = mode or "terminator"
		-- Reset from any previous scenario.
		_result.expanded        = false
		_result.replacement     = ""
		_result.logical_bs      = 0
		_result.terminator_held = false
		_result.provenance_ok   = true
		_result.callback_replay_pairs = 0
		_result.posted_replay_pairs = 0
		_result.remaining_transactions = 0
		posted_events = {}

		state.buffer = buffer_text
		SyntheticInput.enter_callback()
		local ok_expand, fired_or_err = pcall(Expander.try_expand, terminator)
		if not ok_expand then
			SyntheticInput.abort_callback()
			error(fired_or_err, 0)
		end
		local fired = fired_or_err == true

		-- Record the hold before handing the replacement table off. The replay stays
		-- detached from this collector and must only post from the owned process FIFO
		-- after the replacement transaction has settled.
		local replay_pending = TerminatorReplay.is_pending()
		_result.terminator_held = replay_pending
		local ok_leave, consume, returned_events = pcall(
			SyntheticInput.leave_callback, fired)
		if not ok_leave then
			SyntheticInput.abort_callback()
			error(consume, 0)
		end
		local events = returned_events or {}
		if not fired then
			if consume or #events > 0 then
				_result.replacement = "<unexpected synthetic output on a non-match>"
				_result.provenance_ok = false
			end
			if hs and hs.timer and hs.timer.__fire_all then hs.timer.__fire_all() end
			return
		end

		local replay_activated = true
		if replay_pending then
			local ok_flush, flushed_or_err = pcall(TerminatorReplay.flush_now,
				"e2e harness: emulate post-handoff replay")
			if not ok_flush then
				error(flushed_or_err, 0)
			end
			replay_activated = flushed_or_err == true
		end
		_result.expanded = true
		_result.provenance_ok = consume == true and replay_activated

		-- The recurring FIFO owner is the only authority allowed to post a reserved
		-- successor. Drain bounded run-loop turns instead of assuming one fire_all()
		-- settles every owner, and retain the active count as explicit evidence.
		local drain_turns = 0
		while SyntheticInput.stats().active_transactions ~= 0
			or TerminatorReplay.is_pending() do
			if not (hs and hs.timer and hs.timer.__fire_all) then
				_result.provenance_ok = false
				break
			end
			drain_turns = drain_turns + 1
			if drain_turns > 128 then
				_result.provenance_ok = false
				break
			end
			hs.timer.__fire_all()
		end
		_result.remaining_transactions = SyntheticInput.stats().active_transactions
		if TerminatorReplay.is_pending() then _result.provenance_ok = false end

		-- Validate adjacent down/up phases and group them by immutable generation.
		-- Every callback-returned pair belongs to the registered `e2e` replacement.
		-- A terminator replay in this table would prove the harness reintroduced the
		-- old inline-handoff contract.
		local property = hs.eventtap.event.properties.eventSourceUserData
		local generations = {}
		local metadata_by_event = {}
		if #events == 0 or (#events % 2) ~= 0 then _result.provenance_ok = false end
		for index = 1, #events, 2 do
			local down, up = events[index], events[index + 1]
			local down_meta = down and SyntheticInput.lookup_tag(down:getProperty(property)) or nil
			local up_meta = up and SyntheticInput.lookup_tag(up:getProperty(property)) or nil
			metadata_by_event[index] = down_meta
			metadata_by_event[index + 1] = up_meta
			local pair_ok = down_meta and up_meta
				and down_meta.owned and up_meta.owned
				and down_meta.effect == "replacement" and up_meta.effect == "replacement"
				and down_meta.phase == "down" and up_meta.phase == "up"
				and down_meta.generation == up_meta.generation
				and down_meta.owner == up_meta.owner
				and down_meta.ordinal == up_meta.ordinal
				and down_meta.owner == "e2e"
			if not pair_ok then
				_result.provenance_ok = false
			elseif generations[down_meta.owner]
				and generations[down_meta.owner] ~= down_meta.generation then
				_result.provenance_ok = false
			else
				generations[down_meta.owner] = down_meta.generation
			end
		end

		-- Validate the globally posted successor independently. The exact one-pair
		-- count is part of the contract: activation returns no callback event and the
		-- FIFO later posts one tagged down/up pair.
		local found_terminator_replay = false
		if replay_pending then
			if #posted_events ~= 2 then _result.provenance_ok = false end
		elseif #posted_events ~= 0 then
			_result.provenance_ok = false
		end
		if (#posted_events % 2) ~= 0 then _result.provenance_ok = false end
		for index = 1, #posted_events, 2 do
			local down_record, up_record = posted_events[index], posted_events[index + 1]
			local down = down_record and down_record.event or nil
			local up = up_record and up_record.event or nil
			local down_meta = down and SyntheticInput.lookup_tag(down:getProperty(property)) or nil
			local up_meta = up and SyntheticInput.lookup_tag(up:getProperty(property)) or nil
			local pair_ok = down_meta and up_meta
				and down_meta.owned and up_meta.owned
				and down_meta.effect == "replacement" and up_meta.effect == "replacement"
				and down_meta.phase == "down" and up_meta.phase == "up"
				and down_meta.generation == up_meta.generation
				and down_meta.owner == "terminator_replay"
				and up_meta.owner == "terminator_replay"
				and down_meta.ordinal == up_meta.ordinal
			if not pair_ok then
				_result.provenance_ok = false
			else
				found_terminator_replay = true
				_result.posted_replay_pairs = _result.posted_replay_pairs + 1
			end
		end

		-- Apply only callback-returned replacement keyDown events to the screen. The
		-- globally posted terminator is deliberately excluded so emitted() matches
		-- the corpus replacement contract.
		local screen = buffer_text
		for index, event in ipairs(events) do
			if event.isDown then
				local metadata = metadata_by_event[index]
				if metadata and metadata.owner == "terminator_replay" then
					_result.callback_replay_pairs = _result.callback_replay_pairs + 1
				elseif metadata and metadata.owner == "e2e" then
					if event.key == "delete" then
						local ok_off, off = pcall(utf8.offset, screen, -1)
						if ok_off and off and off > 0 then
							screen = screen:sub(1, off - 1)
						elseif #screen > 0 then
							screen = screen:sub(1, -2)
						end
					elseif type(event.unicode) == "string" and event.unicode ~= "" then
						screen = screen .. event.unicode
					elseif event.key == "return" then
						screen = screen .. "\r"
					elseif event.key == "tab" then
						screen = screen .. "\t"
					end
				end
			end
		end
		if _result.terminator_held and not found_terminator_replay then
			_result.provenance_ok = false
		end

		-- Strip only the input context, never search for the expected replacement.
		-- This keeps the assertion capable of seeing a wrong or partial emission.
		local typed_buffer = mode == "auto" and (buffer_text .. terminator) or buffer_text
		local context_bytes = #typed_buffer - #trigger
		local context = context_bytes >= 0 and typed_buffer:sub(1, context_bytes) or ""
		if context_bytes < 0 or screen:sub(1, #context) ~= context then
			_result.replacement = screen
		else
			_result.replacement = screen:sub(#context + 1)
		end

		-- The corpus defines logical replacement width, not the optimised number of
		-- Backspace events. Read the production terminator policy for the only extra
		-- codepoint a terminator-path expansion can consume.
		local cp_count = text_utils.utf8_len(trigger)
		if mode == "terminator" and Registry.terminator_is_consumed(terminator) then
			cp_count = cp_count + text_utils.utf8_len(terminator)
		end
		_result.logical_bs = cp_count

		if _result.remaining_transactions ~= 0 then
			_result.provenance_ok = false
		end
	end

	-- Returns the replacement text that appeared on screen (without surrounding
	-- context and without the re-typed terminator). Empty when no expansion fired.
	local function emitted()
		if _result.expanded and not _result.provenance_ok then
			return "<invalid synthetic transaction provenance>"
		end
		return _result.replacement
	end

	-- Returns the logical backspace count: the number of codepoints erased by
	-- the expansion (= trigger length + consumed terminator). 0 when no expansion.
	local function backspaces()
		return _result.logical_bs
	end

	--- Returns true when the expansion left its non-consumed terminator pending in
	--- the replay gate instead of emitting it inline — the ordering guarantee that
	--- stops Enter submitting the pre-expansion line.
	local function terminator_held()
		return _result.terminator_held
	end

	--- Returns true only when every emitted phase was an exact owned tag and all
	--- transactions reached a terminal state after callback handoff.
	local function provenance_ok()
		return _result.provenance_ok
	end

	--- Returns how many terminator pairs incorrectly escaped through the callback.
	local function callback_replay_pairs()
		return _result.callback_replay_pairs
	end

	--- Returns how many exact terminator pairs the owned global FIFO posted.
	local function posted_replay_pairs()
		return _result.posted_replay_pairs
	end

	--- Returns the active synthetic transaction count after the bounded drain.
	local function remaining_transactions()
		return _result.remaining_transactions
	end

	return {
		inject          = inject,
		emitted         = emitted,
		backspaces      = backspaces,
		terminator_held = terminator_held,
		provenance_ok   = provenance_ok,
		callback_replay_pairs = callback_replay_pairs,
		posted_replay_pairs = posted_replay_pairs,
		remaining_transactions = remaining_transactions,
	}
end





-- =======================================
-- =======================================
-- ======= 3/ Corpus E2E Scenarios =======
-- =======================================
-- =======================================

--- Runs a single corpus vector as an E2E scenario.
--- Matching vectors are tested for the correct emitted replacement.
--- Non-matching vectors verify that no expansion fires.
--- @param v table A vector from vectors.json.
local function run_corpus_vector(v)
	local prefix = string.format("e2e[%s]", v.id)
	-- A vector may declare that its outcome hangs on a constant the drivers
	-- deliberately do not share — today the rolling-buffer cap, 500 codepoints here
	-- against the shared Lua engine's 256. Replaying it would pin the other
	-- driver's number to this one.
	if v.driver_specific ~= nil then
		skip_count = skip_count + 1
		print(string.format("  SKIP  %s  (driver-specific: %s)", prefix, tostring(v.driver_specific)))
		return
	end
	-- The vector itself IS the flag set.
	local ok_vkb, vkb_or_err = pcall(make_vkb, v.trigger, v.replacement, v)

	if not ok_vkb then
		-- If the expander module is unavailable (e.g. missing dependency on this
		-- platform), mark the scenario as skipped rather than failed.
		fail_count = fail_count + 1
		print(string.format("  FAIL  %s  setup error: %s", prefix, tostring(vkb_or_err)))
		return
	end

	local vkb        = vkb_or_err
	local terminator = v.terminator or " "
	-- inject(text, last_char) means "the buffer already holds `text`, the user now
	-- types `last_char`". An auto_expand trigger fires on its OWN last character,
	-- so the keystroke to simulate is the last character of the buffer — not the
	-- terminator, which arrives afterwards and cannot complete the trigger. Driving
	-- every vector with the terminator sent every one of them down the end-char
	-- path, so the auto path was replayed by nothing here and a conform entry (auto
	-- by construction) could not fire at all.
	--
	-- A vector that declares terminator_consumed is describing the END-CHAR path
	-- whatever its auto_expand says: consumption is what that path does with the
	-- terminator, and there is no terminator to consume on the auto path.
	if v.auto_expand == true and v.terminator_consumed == nil then
		local ok_off, off = pcall(utf8.offset, v.buffer, -1)
		if ok_off and off then
			vkb.inject(v.buffer:sub(1, off - 1), v.buffer:sub(off), "auto")
		else
			vkb.inject(v.buffer, terminator, "terminator")
		end
	else
		vkb.inject(v.buffer, terminator, "terminator")
	end

	if v.expected.matched then
		assert_eq(
			prefix .. " — emitted replacement",
			v.expected.replacement,
			vkb.emitted()
		)
		assert_eq(
			prefix .. " — backspace count",
			v.expected.backspace_count,
			vkb.backspaces()
		)
	else
		-- No expansion expected: emitted text must be empty.
		assert_eq(prefix .. " — no expansion emitted", "", vkb.emitted())
	end
end


--- Runs the five mandatory hand-written E2E scenarios that are independent of
--- the corpus, exercising the virtual keyboard's inject/emitted/backspaces API
--- directly so the harness is self-validating even if the corpus cannot be loaded.
local function run_hardcoded_scenarios()
	print("\n--- Hardcoded E2E scenarios ---")


	-- Scenario 1: basic expansion fires.
	local ok1, vkb1 = pcall(make_vkb, "btw", "by the way", {})
	if ok1 then
		vkb1.inject("btw", " ")
		assert_eq("scenario1 — basic expansion text", "by the way", vkb1.emitted())
		assert_eq("scenario1 — basic expansion backspaces", 3, vkb1.backspaces())
		-- Ordering guarantee (terminator-replay-gate): a non-consumed terminator must
		-- be WITHHELD by the replay gate, never posted inline behind the replacement.
		-- Enter and Tab travel as raw key events while the replacement travels through
		-- the text-input pipeline, so an inline re-type reaches the host first and
		-- submits the pre-expansion line. Asserting the hold here is what keeps this
		-- harness honest about the gate instead of merely tolerating it.
		assert_eq("scenario1 — terminator withheld by the replay gate", true, vkb1.terminator_held())
		assert_eq("scenario1 — callback output carries exact transaction provenance",
			true, vkb1.provenance_ok())
		assert_eq("scenario1 — reserved terminator never returns from the callback",
			0, vkb1.callback_replay_pairs())
		assert_eq("scenario1 — reserved terminator posts once from the global FIFO",
			1, vkb1.posted_replay_pairs())
		assert_eq("scenario1 — all synthetic transactions settle after FIFO replay",
			0, vkb1.remaining_transactions())
	else
		fail_count = fail_count + 1
		print("  FAIL  scenario1 — setup: " .. tostring(vkb1))
	end


	-- Scenario 2: no match when buffer does not end with trigger.
	local ok2, vkb2 = pcall(make_vkb, "btw", "by the way", {})
	if ok2 then
		vkb2.inject("hello", " ")
		assert_eq("scenario2 — non-matching buffer emits nothing", "", vkb2.emitted())
	else
		fail_count = fail_count + 1
		print("  FAIL  scenario2 — setup: " .. tostring(vkb2))
	end


	-- Scenario 3: is_word trigger blocked when preceded by a word character.
	local ok3, vkb3 = pcall(make_vkb, "the", "THE", { is_word = true })
	if ok3 then
		vkb3.inject("othe", " ")
		assert_eq("scenario3 — is_word mid-word blocked", "", vkb3.emitted())
	else
		fail_count = fail_count + 1
		print("  FAIL  scenario3 — setup: " .. tostring(vkb3))
	end


	-- Scenario 4: is_word trigger fires at start-of-buffer.
	local ok4, vkb4 = pcall(make_vkb, "the", "THE", { is_word = true })
	if ok4 then
		vkb4.inject("the", " ")
		assert_eq("scenario4 — is_word start-of-buffer fires", "THE", vkb4.emitted())
		assert_eq("scenario4 — is_word start-of-buffer backspaces", 3, vkb4.backspaces())
	else
		fail_count = fail_count + 1
		print("  FAIL  scenario4 — setup: " .. tostring(vkb4))
	end


	-- Scenario 5: a STRICT trigger does not match a different case. is_case_sensitive
	-- alone would not be enough — on its own it selects literal registration and the
	-- comparison still folds.
	local ok5, vkb5 = pcall(make_vkb, "BTW", "by the way",
		{ is_case_sensitive = true, is_case_sensitive_strict = true, auto_expand = true })
	if ok5 then
		vkb5.inject("btw", " ")
		assert_eq("scenario5 — case-sensitive no match on wrong case", "", vkb5.emitted())
	else
		fail_count = fail_count + 1
		print("  FAIL  scenario5 — setup: " .. tostring(vkb5))
	end
end





-- ===================================
-- ===================================
-- ======= 4/ Main Entry Point =======
-- ===================================
-- ===================================

print("=== Hammerspoon E2E virtual-keyboard harness ===\n")

-- Run the five hardcoded scenarios first — they self-validate the harness.
run_hardcoded_scenarios()

-- Run every vector from the shared corpus.
print("\n--- Shared corpus vectors ---")
local ok_corpus, corpus_or_err = pcall(load_corpus)
if not ok_corpus then
	print(string.format("WARNING: could not load corpus (%s) — skipping corpus vectors.",
		tostring(corpus_or_err)))
else
	for _, v in ipairs(corpus_or_err) do
		run_corpus_vector(v)
	end
end

-- Final summary.
local total = pass_count + fail_count
print(string.format("\n1..%d", total))
print(string.format("# pass %d / %d", pass_count, total))
if skip_count > 0 then
	print(string.format("# skip %d driver-specific vector(s)", skip_count))
end
if fail_count > 0 then
	print(string.format("# FAIL %d test(s) failed.", fail_count))
	os.exit(1)
else
	print("# All E2E scenarios passed.")
	os.exit(0)
end
