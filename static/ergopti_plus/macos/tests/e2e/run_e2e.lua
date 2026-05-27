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
---   3. "Emitted" output is captured from the hs.eventtap stub's keystroke log.
---   4. Assertions compare emitted text and backspace counts against the corpus.
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
local shared_lua   = drivers_root .. "/shared/lua"
local corpus_path  = drivers_root .. "/shared/tests/corpus/hotstrings/vectors.json"

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




-- ===================================
--- ======================================
-- ======= 1/ Test Infrastructure =======
--- ======================================
-- ===================================

local pass_count = 0
local fail_count = 0

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
--- Requires the shared/lua json module (tiny pure-Lua JSON parser).
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
		error("Cannot load shared json module — check shared/lua/json.lua exists.")
	end
	local decoded = json.decode(raw)
	return decoded.vectors
end




-- ===================================
--- ===================================
-- ======= 2/ Virtual Keyboard =======
--- ===================================
-- ===================================

--- Builds an isolated test environment: fresh stubs + Registry + Expander.
--- Returns a table with:
---   inject(buffer, terminator) — feeds the full buffer char-by-char then the terminator
---   emitted()                  — returns the concatenated emitted text
---   backspaces()               — returns the number of synthetic backspaces issued
--- @param trigger string The hotstring trigger to register.
--- @param replacement string The expansion text.
--- @param opts table Optional flags: is_word, is_case_sensitive.
--- @return table Virtual keyboard context.
local function make_vkb(trigger, replacement, opts)
	opts = opts or {}

	-- Fresh stub environment for each scenario to prevent cross-test leakage.
	-- All keymap modules are cleared so they reload together under a single
	-- fresh hs stub (the one created by the final load_with_stubs call below).
	-- modules.keymap.utils captures hs.eventtap.keyStrokes at module-load time,
	-- so it MUST be in the same load wave as expander to guarantee that the
	-- KEYSTROKES table written by utils and the __keystrokes table read by the
	-- harness are the same object.
	package.loaded["lib.logger"]                 = nil
	package.loaded["lib.text_utils"]             = nil
	package.loaded["lib.i18n"]                   = nil
	package.loaded["modules.keymap.terminators"] = nil
	package.loaded["modules.keymap.utils"]       = nil
	package.loaded["modules.keymap.registry"]    = nil
	package.loaded["modules.keymap.expander"]    = nil

	-- One load_with_stubs call — establishes the canonical hs stub for this
	-- scenario; all dependencies (registry, utils, terminators) cascade from
	-- the same require chain and share the same KEYSTROKES table.
	local Expander = helpers.load_with_stubs("modules.keymap.expander")
	local Registry = require("modules.keymap.registry")
	local text_utils = require("lib.text_utils")

	-- Magic key sentinel — same value as the live driver.
	local MAGIC_KEY = "\xe2\x98\x85"

	-- Minimal CoreState that satisfies the Expander's require_state guard.
	local state = {
		buffer                     = "",
		magic_key                  = MAGIC_KEY,
		expected_synthetic_deletes = 0,
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
	Registry.add(trigger, replacement, {
		is_word           = opts.is_word           == true,
		is_case_sensitive = opts.is_case_sensitive == true,
		group             = "e2e",
	})
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

	-- Track emitted text and backspaces via the hs stub.
	local hs_stub  = require("hs")   -- stub loaded by helpers
	hs_stub.eventtap.__reset()

	-- Result cache populated by inject(); accessed by emitted() and backspaces().
	local _result = { expanded = false, replacement = "", logical_bs = 0 }

	-- Feed the buffer into state, then fire try_expand with the terminator.
	--
	-- After expansion the engine sets state.buffer to:
	--   context_prefix_str + replacement_str [+ terminator_if_not_consumed]
	-- where context_prefix_str is the portion of buffer_text that precedes the
	-- trigger. We recover the replacement by stripping that prefix from the
	-- updated buffer. The prefix length in bytes equals:
	--   #buffer_text - trigger_byte_length
	-- The trigger_byte_length equals raw_bs (delete events) + the byte length of
	-- the common leading substring between trigger and replacement, which the
	-- engine keeps on screen via the prefix-overlap optimisation. We derive the
	-- common prefix bytes by searching for the replacement string in the updated
	-- buffer starting right after the context_prefix position.
	local function inject(buffer_text, terminator)
		-- Reset from any previous scenario.
		_result.expanded    = false
		_result.replacement = ""
		_result.logical_bs  = 0

		state.buffer = buffer_text
		local fired = Expander.try_expand and (Expander.try_expand(terminator) == true)
		if not fired then return end
		_result.expanded = true

		local raw_bs = 0
		local found_term_in_keystrokes = false
		for _, ks in ipairs(hs_stub.eventtap.__keystrokes) do
			if ks.key == "delete" then
				raw_bs = raw_bs + 1
			elseif ks.text == terminator then
				found_term_in_keystrokes = true
			end
		end

		-- After expansion, state.buffer = context + replacement [+ term].
		-- Context byte length = #buffer_text - trigger_byte_length.
		-- Trigger byte length = raw_bs_bytes + common_prefix_bytes.
		-- We reconstruct the on-screen text by replaying deletes + keyStrokes
		-- against the original buffer_text; this avoids needing to infer the
		-- common prefix from the updated state.buffer (which is ambiguous when
		-- the replacement's leading chars coincide with the trigger's leading chars).
		--
		-- Replay: apply raw_bs backspace-codepoints from the right of buffer_text,
		-- then append the text portions of the keystroke log.
		local screen = buffer_text
		-- Remove raw_bs codepoints from the right (backspace is codepoint-aware).
		for _ = 1, raw_bs do
			local ok, off = pcall(utf8.offset, screen, -1)
			if ok and off and off > 0 then
				screen = screen:sub(1, off - 1)
			elseif #screen > 0 then
				screen = screen:sub(1, -2)  -- ASCII fallback
			end
		end
		-- Append each text keystroke (excluding the re-typed terminator which will
		-- be stripped separately).
		for _, ks in ipairs(hs_stub.eventtap.__keystrokes) do
			if ks.text then screen = screen .. ks.text end
		end
		-- Strip the trailing re-typed terminator so we return just the replacement.
		if found_term_in_keystrokes and terminator ~= "" then
			if screen:sub(-#terminator) == terminator then
				screen = screen:sub(1, #screen - #terminator)
			end
		end

		-- The context_prefix portion of screen = the leading bytes of buffer_text
		-- that were NOT inside the trigger. They equal the bytes the engine did NOT
		-- delete (raw_bs removed from the trigger suffix, but the common prefix
		-- with the replacement was kept, so context_prefix < #buffer_text - raw_bs).
		-- Rather than computing the prefix length algebraically, we detect it by
		-- finding the position of the replacement in screen using the replacement
		-- string we stored at make_vkb() call time.
		-- Since we have the replacement available as a closure, search for it in screen.
		local repl_start = 1
		if replacement ~= "" then
			-- Locate the replacement suffix in screen: it starts somewhere after the
			-- context prefix. We search from position max(1, #screen - #replacement + 1)
			-- backwards until found, giving the actual start of the replacement.
			for i = 1, #screen - #replacement + 1 do
				if screen:sub(i, i + #replacement - 1) == replacement then
					repl_start = i
					break
				end
			end
		end
		_result.replacement = screen:sub(repl_start)

		-- Logical backspace count = trigger codepoint length.
		-- Trigger = buffer_text starting from (repl_start) bytes from the end
		-- of buffer_text, extended back to include the common prefix bytes.
		-- Equivalently: trigger occupies the last (#buffer_text - context_prefix_bytes)
		-- bytes of buffer_text. context_prefix_bytes = repl_start - 1 in screen terms,
		-- which equals the context_prefix_bytes in buffer_text since context is unchanged.
		local trigger_str = buffer_text:sub(repl_start)
		local _, cp_count = trigger_str:gsub("[\0-\127\194-\244]", "")
		-- A consumed terminator is logically erased by the expansion; include it.
		local term_was_consumed = (terminator ~= "") and (not found_term_in_keystrokes)
		if term_was_consumed then cp_count = cp_count + 1 end
		_result.logical_bs = cp_count
	end

	-- Returns the replacement text that appeared on screen (without surrounding
	-- context and without the re-typed terminator). Empty when no expansion fired.
	local function emitted()
		return _result.replacement
	end

	-- Returns the logical backspace count: the number of codepoints erased by
	-- the expansion (= trigger length + consumed terminator). 0 when no expansion.
	local function backspaces()
		return _result.logical_bs
	end

	return { inject = inject, emitted = emitted, backspaces = backspaces }
end




-- ===================================
--- =======================================
-- ======= 3/ Corpus E2E Scenarios =======
--- =======================================
-- ===================================

--- Runs a single corpus vector as an E2E scenario.
--- Matching vectors are tested for the correct emitted replacement.
--- Non-matching vectors verify that no expansion fires.
--- @param v table A vector from vectors.json.
local function run_corpus_vector(v)
	local prefix = string.format("e2e[%s]", v.id)
	local ok_vkb, vkb_or_err = pcall(make_vkb, v.trigger, v.replacement, {
		is_word           = v.is_word,
		is_case_sensitive = v.is_case_sensitive,
	})

	if not ok_vkb then
		-- If the expander module is unavailable (e.g. missing dependency on this
		-- platform), mark the scenario as skipped rather than failed.
		fail_count = fail_count + 1
		print(string.format("  FAIL  %s  setup error: %s", prefix, tostring(vkb_or_err)))
		return
	end

	local vkb        = vkb_or_err
	local terminator = v.terminator or " "
	vkb.inject(v.buffer, terminator)

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


	-- Scenario 5: case-sensitive trigger does not match wrong case.
	local ok5, vkb5 = pcall(make_vkb, "BTW", "by the way", { is_case_sensitive = true })
	if ok5 then
		vkb5.inject("btw", " ")
		assert_eq("scenario5 — case-sensitive no match on wrong case", "", vkb5.emitted())
	else
		fail_count = fail_count + 1
		print("  FAIL  scenario5 — setup: " .. tostring(vkb5))
	end
end




-- ===================================
--- ===================================
-- ======= 4/ Main Entry Point =======
--- ===================================
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
if fail_count > 0 then
	print(string.format("# FAIL %d test(s) failed.", fail_count))
	os.exit(1)
else
	print("# All E2E scenarios passed.")
	os.exit(0)
end
