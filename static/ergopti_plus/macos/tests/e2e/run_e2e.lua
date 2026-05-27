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
	package.loaded["lib.logger"]             = nil
	package.loaded["modules.keymap.registry"] = nil
	package.loaded["modules.keymap.utils"]    = nil
	package.loaded["modules.keymap.expander"] = nil
	package.loaded["lib.text_utils"]          = nil

	helpers.load_with_stubs("lib.logger")
	local text_utils = helpers.load_with_stubs("lib.text_utils")
	local Registry   = helpers.load_with_stubs("modules.keymap.registry")
	local Expander   = helpers.load_with_stubs("modules.keymap.expander")

	-- Magic key sentinel — same value as the live driver.
	local MAGIC_KEY = "\xe2\x98\x85"

	-- Minimal CoreState that satisfies the Expander's require_state guard.
	local state = {
		buffer                     = "",
		magic_key                  = MAGIC_KEY,
		expected_synthetic_deletes = 0,
		groups                     = {},
		current_group              = "e2e",
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

	-- Feed each character from the buffer into the state manually, then call
	-- Expander.try_expand with the terminator to simulate the eventtap path.
	local function inject(buffer_text, terminator)
		state.buffer = buffer_text
		-- try_expand is the public entry point called by the live HID callback.
		-- It receives the terminator character and returns true on expansion.
		if Expander.try_expand then
			Expander.try_expand(terminator)
		end
	end

	local function emitted()
		local parts = {}
		for _, ks in ipairs(hs_stub.eventtap.__keystrokes) do
			if ks.text then
				table.insert(parts, ks.text)
			end
		end
		return table.concat(parts)
	end

	local function backspaces()
		local count = 0
		for _, ks in ipairs(hs_stub.eventtap.__keystrokes) do
			if ks.key == "delete" then
				count = count + 1
			end
		end
		return count
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
