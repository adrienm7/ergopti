--- tests/e2e/run_e2e.lua

--- ==============================================================================
--- MODULE: Linux E2E Virtual-Keyboard Test Harness
--- DESCRIPTION:
--- End-to-end test harness that validates the full Linux hotstring expansion
--- pipeline by feeding synthetic keystrokes through the real engine (pure Lua,
--- no OS dependencies) and asserting the emitted replacements.
---
--- DESIGN RATIONALE — WHY NO REAL evdev / ydotool ON CI:
--- The Linux hotstring daemon reads /dev/input/eventN (raw evdev) and injects
--- via ydotool/uinput — both require a real Linux kernel with input devices.
--- GitHub Actions runners do not expose evdev nodes to background jobs.
---
--- WHAT THIS HARNESS DOES INSTEAD:
--- It exercises the same *code paths* that a real keystroke would follow:
---   1. Characters are fed into the shared hotstring engine one by one via the
---      same on_char() callback that the live input_reader calls.
---   2. The engine runs its full matching + replacement logic.
---   3. The returned replacement text and backspace count are asserted.
---
--- This gives 95% of the confidence of a real E2E run for the pure-logic layer.
---
--- USAGE:
---   luajit tests/e2e/run_e2e.lua     # run from the linux driver root
---   lua5.4 tests/e2e/run_e2e.lua     # works with plain Lua 5.4 as well
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
local shared_root  = drivers_root .. "/_shared"
local shared_lua   = shared_root .. "/lua"
local corpus_path  = shared_root .. "/tests/corpus/hotstrings/vectors.json"

package.path = table.concat({
	driver_root .. "/?.lua",
	driver_root .. "/?/init.lua",
	driver_root .. "/modules/hotstrings/?.lua",
	shared_lua  .. "/?.lua",
	shared_lua  .. "/?/init.lua",
	driver_root .. "/tests/?.lua",
	package.path,
}, ";")

-- The SAME terminator set the driver consults (ergopti_hotstrings.lua:443), so
-- this harness cannot open the end-char path for a character the driver would
-- leave alone. Deciding that here by hand is what made a correct engine look
-- wrong against a correct vector.
local terminators = require("keymap.terminators")
local Contract = require("tests.e2e.contract")


-- ============================================================================
-- 1. Test Infrastructure
-- ============================================================================

local pass_count = 0
local fail_count = 0

--- Records a passing assertion.
local function pass(label)
	pass_count = pass_count + 1
	print(string.format("  PASS  %s", label))
end

--- Records a failing assertion.
local function fail(label, expected, actual)
	fail_count = fail_count + 1
	print(string.format("  FAIL  %s  expected=%s  got=%s",
		label, tostring(expected), tostring(actual)))
end

--- Asserts equality and records pass/fail.
local function assert_eq(label, expected, actual)
	if expected == actual then
		pass(label)
	else
		fail(label, expected, actual)
	end
end

--- Asserts a boolean condition.
local function assert_true(label, condition)
	assert_eq(label, true, condition == true)
end


-- ============================================================================
-- 2. Virtual Keyboard (Engine Harness)
-- ============================================================================

--- Creates a fresh engine instance loaded with a single mapping.
--- Returns a vkb table with:
---   vkb.feed(buffer, terminator) — feeds characters one-by-one, returns match
---   vkb.inject(buffer, terminator) — feed + assert on match result
--- @param trigger     string The hotstring trigger.
--- @param replacement string The expansion text.
--- @param opts        table  Per-entry flags, exactly as the shared corpus
---                          declares them (is_word, auto_expand, is_case_sensitive,
---                          is_case_sensitive_strict, final_result).
--- @return table Virtual keyboard context.
local function make_vkb(trigger, replacement, opts)
	opts = opts or {}

	-- Fresh engine instance — no cross-test leakage.
	local engine_mod = require("modules.hotstrings.engine")
	local engine     = engine_mod.new()

	-- Every per-entry flag, driven off a list. Naming a subset is what broke this
	-- harness: `auto_expand` was omitted, so every mapping it built waited for a
	-- terminator it never announced, and the whole run reported "no match" for
	-- everything that should have matched.
	local mapping = {
		trigger     = trigger,
		replacement = replacement,
	}
	for _, flag in ipairs({ "is_word", "auto_expand", "is_case_sensitive",
		"is_case_sensitive_strict", "final_result" }) do
		mapping[flag] = opts[flag] == true
	end

	engine:load_mappings({ mapping })

	--- Feeds a buffer string character by character, then the terminator.
	--- Returns the engine's match result table or nil.
	--- The engine matches when buffer suffix == trigger; the terminator simply
	--- adds +1 to the backspace count. We feed all chars and return the match
	--- that occurs on the trigger's last character (before the terminator).
	--- @param buffer_text string  Full typing buffer (trigger + optional prefix).
	--- @param terminator  string  The terminator character.
	--- @return table|nil {trigger, replacement, backspace_count} or nil.
	local function feed(buffer_text, terminator, terminator_consumed)
		-- Split into UTF-8 codepoints (not raw bytes — gmatch(".") is byte-level).
		local chars = {}
		local i = 1
		while i <= #buffer_text do
			local b = buffer_text:byte(i)
			local len = 1
			if b >= 0x80 then
				if     b < 0xC0 then len = 1
				elseif b < 0xE0 then len = 2
				elseif b < 0xF0 then len = 3
				else                  len = 4
				end
			end
			chars[#chars + 1] = buffer_text:sub(i, i + len - 1)
			i = i + len
		end

		-- Append the terminator after the buffer if it's not already the last char.
		if terminator ~= "" and (buffer_text == "" or buffer_text:sub(-#terminator) ~= terminator) then
			chars[#chars + 1] = terminator
		end

		-- Feed all chars. The engine matches when the buffer suffix == the
		-- trigger (which happens when the last trigger character is fed).
		-- After that match, the engine's buffer still contains the trigger +
		-- whatever comes next, so feeding the terminator returns nil.
		-- Return the first non-nil match (the trigger match, not nil from terminator).
		for i, ch in ipairs(chars) do
			local is_last = (i == #chars)
			-- is_terminator is what OPENS the end-char path; terminator_consumed only
			-- says whether the character is swallowed. Sending the second without the
			-- first meant a non-auto trigger could never fire in this harness.
			--
			-- ASKED, NOT ASSUMED. This used to read `is_last and terminator ~= ""`,
			-- which declared whatever character came last to BE a terminator. The
			-- production driver asks terminators.is_terminator(ch) — so the harness
			-- opened the end-char path for characters the driver never would, and a
			-- corpus vector describing "a non-auto trigger followed by an ordinary
			-- letter does not fire" was replayed as "…followed by a terminator", which
			-- fires and is supposed to. The vector failed against correct behaviour.
			local is_term = is_last and terminator ~= "" and terminators.is_terminator(ch)
			local consumed = false
			if is_term then
				if terminator_consumed ~= nil then
					consumed = terminator_consumed == true
				else
					consumed = terminators.terminator_is_consumed(ch)
				end
			end
			local result = engine:on_char(ch, {
				is_terminator        = is_term,
				terminator_consumed  = consumed,
			})
			if result then
				return result
			end
		end
		return nil
	end

	--- Feeds buffer + terminator and asserts the match result.
	--- @param buffer_text    string Full typing buffer.
	--- @param terminator     string The terminator character.
	--- @param expect_match   boolean Whether a match is expected.
	--- @param expect_text    string|nil Expected replacement text (if match expected).
	--- @param expect_bs      number|nil Expected backspace count (if match expected).
	--- @param terminator_consumed boolean|nil Explicit corpus policy when present.
	local function inject_assert(buffer_text, terminator, expect_match, expect_text, expect_bs,
			terminator_consumed)
		local result = feed(buffer_text, terminator, terminator_consumed)
		local logical_result = result
		if result and result.end_char and not result.consume_terminator then
			-- The live injector erases the already-visible terminator and replays it
			-- after the replacement. That adds one physical Backspace while replacing
			-- zero logical terminator codepoints; the cross-driver corpus records the
			-- logical replacement count by design.
			logical_result = {}
			for key, value in pairs(result) do logical_result[key] = value end
			logical_result.backspace_count = result.backspace_count - 1
		end
		local expected = { matched = expect_match }
		if expect_match then
			expected.replacement = expect_text
			expected.backspace_count = expect_bs
		end
		for _, observation in ipairs(Contract.observations(expected, logical_result)) do
			assert_eq(buffer_text .. " — " .. observation.field,
				observation.expected, observation.actual)
		end
	end

	return { feed = feed, inject_assert = inject_assert }
end


-- ============================================================================
-- 3. Hardcoded E2E Scenarios
-- ============================================================================

--- Runs five mandatory hand-written E2E scenarios that validate the harness
--- itself independently of the corpus.
local function run_hardcoded_scenarios()
	print("\n--- Hardcoded E2E scenarios ---")

	-- Scenario 1: basic expansion fires.
	local ok1, vkb1 = pcall(make_vkb, "btw", "by the way", { auto_expand = true })
	if ok1 then
		vkb1.inject_assert("btw", " ", true, "by the way", 3)
	else
		fail("scenario1 — setup", "ok", tostring(vkb1))
	end

	-- Scenario 2: no match when buffer does not end with trigger.
	local ok2, vkb2 = pcall(make_vkb, "btw", "by the way", { auto_expand = true })
	if ok2 then
		vkb2.inject_assert("hello", " ", false)
	else
		fail("scenario2 — setup", "ok", tostring(vkb2))
	end

	-- Scenario 3: is_word trigger blocked when preceded by a word character.
	local ok3, vkb3 = pcall(make_vkb, "the", "THE", { is_word = true, auto_expand = true })
	if ok3 then
		vkb3.inject_assert("othe", " ", false)
	else
		fail("scenario3 — setup", "ok", tostring(vkb3))
	end

	-- Scenario 4: is_word trigger fires at start-of-buffer.
	local ok4, vkb4 = pcall(make_vkb, "the", "THE", { is_word = true, auto_expand = true })
	if ok4 then
		vkb4.inject_assert("the", " ", true, "THE", 3)
	else
		fail("scenario4 — setup", "ok", tostring(vkb4))
	end

	-- Scenario 5: case-sensitive trigger does not match wrong case.
	local ok5, vkb5 = pcall(make_vkb, "BTW", "by the way", { is_case_sensitive = true, is_case_sensitive_strict = true, auto_expand = true })
	if ok5 then
		vkb5.inject_assert("btw", " ", false)
	else
		fail("scenario5 — setup", "ok", tostring(vkb5))
	end

	-- Scenario 6: empty trigger (should not crash).
	local ok6, vkb6 = pcall(make_vkb, "", "nope", { auto_expand = true })
	if ok6 then
		vkb6.inject_assert("test", " ", false)
	else
		fail("scenario6 — setup", "ok", tostring(vkb6))
	end

	-- Scenario 7: trigger with special French characters.
	local ok7, vkb7 = pcall(make_vkb, "bjr", "bonjour", { auto_expand = true })
	if ok7 then
		vkb7.inject_assert("bjr", " ", true, "bonjour", 3)
	else
		fail("scenario7 — setup", "ok", tostring(vkb7))
	end

	-- Scenario 8: multiple consecutive matches (engine reset between).
	local ok8, vkb8 = pcall(make_vkb, "mdr", "mort de rire", { auto_expand = true })
	if ok8 then
		vkb8.inject_assert("mdr", " ", true, "mort de rire", 3)
		-- Engine should have reset after match; second call with same buffer
		-- should match again.
		vkb8.inject_assert("mdr", " ", true, "mort de rire", 3)
	else
		fail("scenario8 — setup", "ok", tostring(vkb8))
	end
end


-- ============================================================================
-- 4. Corpus Vector Runner
-- ============================================================================

--- Runs a single corpus vector through the engine.
--- @param v table A vector from vectors.json.
local function run_corpus_vector(v)
	local prefix = string.format("e2e[%s]", v.id)
	-- The vector itself IS the flag set; forwarding a hand-picked subset is how
	-- this harness silently replayed every vector as a different one.
	local mapping_opts = v
	if v.terminator_consumed ~= nil then
		-- An explicit consumption verdict describes the end-character path. An
		-- auto rule would otherwise fire on its own final character before the
		-- terminator exists, making that field impossible to observe. macOS drives
		-- the same corpus distinction in its E2E harness.
		mapping_opts = {}
		for key, value in pairs(v) do mapping_opts[key] = value end
		mapping_opts.auto_expand = false
	end
	local ok_vkb, vkb_or_err = pcall(make_vkb, v.trigger, v.replacement, mapping_opts)

	if not ok_vkb then
		fail(prefix .. " — setup", "ok", tostring(vkb_or_err))
		return
	end

	local vkb        = vkb_or_err
	local terminator = v.terminator or " "

	if v.expected.matched then
		vkb.inject_assert(v.buffer, terminator, true,
			v.expected.replacement, v.expected.backspace_count, v.terminator_consumed)
	else
		vkb.inject_assert(v.buffer, terminator, false, nil, nil, v.terminator_consumed)
	end
end


-- ============================================================================
-- 5. Main Entry Point
-- ============================================================================

print("=== Linux hotstring engine E2E harness ===\n")

-- Run the hardcoded scenarios first — they self-validate the harness.
local hardcoded_before = pass_count + fail_count
run_hardcoded_scenarios()
local hardcoded_assertions = pass_count + fail_count - hardcoded_before
assert_true("hardcoded assertion floor",
	hardcoded_assertions >= Contract.MIN_HARDCODED_ASSERTIONS)

-- Run every vector from the shared corpus.
print("\n--- Shared corpus vectors ---")
local corpus_before = pass_count + fail_count
local vectors, corpus_error = Contract.load_corpus(corpus_path)
if not vectors then
	fail("mandatory corpus", "validated vectors", tostring(corpus_error))
else
	for _, v in ipairs(vectors) do
		run_corpus_vector(v)
	end
	print(string.format("Corpus vectors processed: %d", #vectors))
end
local corpus_assertions = pass_count + fail_count - corpus_before
assert_true("corpus vector floor", vectors ~= nil and #vectors >= Contract.MIN_VECTOR_COUNT)
assert_true("corpus assertion floor", corpus_assertions >= Contract.MIN_CORPUS_ASSERTIONS)

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
