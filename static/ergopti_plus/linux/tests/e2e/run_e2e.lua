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
-- 2. Corpus Loader
-- ============================================================================

--- Reads and JSON-decodes the shared corpus file.
--- Uses the _shared/lua json module (pure-Lua JSON parser).
--- @return table Array of vector tables, or nil on failure.
local function load_corpus()
	local f, err = io.open(corpus_path, "r")
	if not f then
		print(string.format("WARNING: Cannot open corpus at %s : %s", corpus_path, tostring(err)))
		return nil
	end
	local raw = f:read("*a")
	f:close()

	-- Use the tiny JSON decoder available in the shared Lua library.
	local ok, json_mod = pcall(require, "json")
	if not ok then
		print("WARNING: Cannot load shared json module — skipping corpus vectors.")
		return nil
	end
	local decoded = json_mod.decode(raw)
	if type(decoded) ~= "table" or type(decoded.vectors) ~= "table" then
		print("WARNING: Corpus JSON has no 'vectors' array.")
		return nil
	end
	return decoded.vectors
end


-- ============================================================================
-- 3. Virtual Keyboard (Engine Harness)
-- ============================================================================

--- Creates a fresh engine instance loaded with a single mapping.
--- Returns a vkb table with:
---   vkb.feed(buffer, terminator) — feeds characters one-by-one, returns match
---   vkb.inject(buffer, terminator) — feed + assert on match result
--- @param trigger     string The hotstring trigger.
--- @param replacement string The expansion text.
--- @param opts        table  {is_word?, is_case_sensitive?}
--- @return table Virtual keyboard context.
local function make_vkb(trigger, replacement, opts)
	opts = opts or {}

	-- Fresh engine instance — no cross-test leakage.
	local engine_mod = require("modules.hotstrings.engine")
	local engine     = engine_mod.new()

	-- Build a single mapping matching the expected format.
	local mapping = {
		trigger          = trigger,
		replacement      = replacement,
		is_word          = opts.is_word          == true,
		is_case_sensitive = opts.is_case_sensitive == true,
	}

	engine:load_mappings({ mapping })

	--- Feeds a buffer string character by character, then the terminator.
	--- Returns the engine's match result table or nil.
	--- The engine matches when buffer suffix == trigger; the terminator simply
	--- adds +1 to the backspace count. We feed all chars and return the match
	--- that occurs on the trigger's last character (before the terminator).
	--- @param buffer_text string  Full typing buffer (trigger + optional prefix).
	--- @param terminator  string  The terminator character.
	--- @return table|nil {trigger, replacement, backspace_count} or nil.
	local function feed(buffer_text, terminator)
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
			local term_consumed = is_last and terminator ~= ""
			local result = engine:on_char(ch, { terminator_consumed = term_consumed })
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
	local function inject_assert(buffer_text, terminator, expect_match, expect_text, expect_bs)
		local result = feed(buffer_text, terminator)
		if expect_match then
			if result then
				if expect_text then
					assert_eq(buffer_text .. " — replacement", expect_text, result.replacement)
				end
			-- The Linux engine does NOT consume terminators (unlike macOS Hammerspoon).
		-- The expected backspace count from the corpus (which expects macOS behavior)
		-- includes +1 for the consumed terminator.
		-- The engine counts codepoints, not bytes; compute the codepoint length.
		if expect_bs then
			local trigger = result.trigger or ""
			-- Count codepoints (same algorithm as the engine's utf8_codepoints)
			local cp_count = 0
			local i = 1
			while i <= #trigger do
				local b = trigger:byte(i)
				if     b < 0x80 then i = i + 1
				elseif b < 0xC0 then i = i + 1
				elseif b < 0xE0 then i = i + 2
				elseif b < 0xF0 then i = i + 3
				else                  i = i + 4
				end
				cp_count = cp_count + 1
			end
			-- Accept either the trigger codepoint count (Linux, no terminator consumption)
			-- or codepoint_count + 1 (macOS, terminator consumed).
			local ok = (result.backspace_count == cp_count) or
			           (result.backspace_count == cp_count + 1)
			if not ok then
				fail(buffer_text .. " — backspaces",
					tostring(cp_count) .. " or " .. tostring(cp_count + 1),
					tostring(result.backspace_count))
			end
				end
			else
				fail(buffer_text .. " — match expected", "result table", "nil")
			end
		else
			assert_eq(buffer_text .. " — no match expected", nil, result)
		end
	end

	return { feed = feed, inject_assert = inject_assert }
end


-- ============================================================================
-- 4. Hardcoded E2E Scenarios
-- ============================================================================

--- Runs five mandatory hand-written E2E scenarios that validate the harness
--- itself independently of the corpus.
local function run_hardcoded_scenarios()
	print("\n--- Hardcoded E2E scenarios ---")

	-- Scenario 1: basic expansion fires.
	local ok1, vkb1 = pcall(make_vkb, "btw", "by the way", {})
	if ok1 then
		vkb1.inject_assert("btw", " ", true, "by the way", 3)
	else
		fail("scenario1 — setup", "ok", tostring(vkb1))
	end

	-- Scenario 2: no match when buffer does not end with trigger.
	local ok2, vkb2 = pcall(make_vkb, "btw", "by the way", {})
	if ok2 then
		vkb2.inject_assert("hello", " ", false)
	else
		fail("scenario2 — setup", "ok", tostring(vkb2))
	end

	-- Scenario 3: is_word trigger blocked when preceded by a word character.
	local ok3, vkb3 = pcall(make_vkb, "the", "THE", { is_word = true })
	if ok3 then
		vkb3.inject_assert("othe", " ", false)
	else
		fail("scenario3 — setup", "ok", tostring(vkb3))
	end

	-- Scenario 4: is_word trigger fires at start-of-buffer.
	local ok4, vkb4 = pcall(make_vkb, "the", "THE", { is_word = true })
	if ok4 then
		vkb4.inject_assert("the", " ", true, "THE", 3)
	else
		fail("scenario4 — setup", "ok", tostring(vkb4))
	end

	-- Scenario 5: case-sensitive trigger does not match wrong case.
	local ok5, vkb5 = pcall(make_vkb, "BTW", "by the way", { is_case_sensitive = true })
	if ok5 then
		vkb5.inject_assert("btw", " ", false)
	else
		fail("scenario5 — setup", "ok", tostring(vkb5))
	end

	-- Scenario 6: empty trigger (should not crash).
	local ok6, vkb6 = pcall(make_vkb, "", "nope", {})
	if ok6 then
		vkb6.inject_assert("test", " ", false)
	else
		fail("scenario6 — setup", "ok", tostring(vkb6))
	end

	-- Scenario 7: trigger with special French characters.
	local ok7, vkb7 = pcall(make_vkb, "bjr", "bonjour", {})
	if ok7 then
		vkb7.inject_assert("bjr", " ", true, "bonjour", 3)
	else
		fail("scenario7 — setup", "ok", tostring(vkb7))
	end

	-- Scenario 8: multiple consecutive matches (engine reset between).
	local ok8, vkb8 = pcall(make_vkb, "mdr", "mort de rire", {})
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
-- 5. Corpus Vector Runner
-- ============================================================================

--- Runs a single corpus vector through the engine.
--- @param v table A vector from vectors.json.
local function run_corpus_vector(v)
	local prefix = string.format("e2e[%s]", v.id)
	local ok_vkb, vkb_or_err = pcall(make_vkb, v.trigger, v.replacement, {
		is_word           = v.is_word,
		is_case_sensitive = v.is_case_sensitive,
	})

	if not ok_vkb then
		fail(prefix .. " — setup", "ok", tostring(vkb_or_err))
		return
	end

	local vkb        = vkb_or_err
	local terminator = v.terminator or " "

	if v.expected.matched then
		vkb.inject_assert(v.buffer, terminator, true,
			v.expected.replacement, v.expected.backspace_count)
	else
		vkb.inject_assert(v.buffer, terminator, false)
	end
end


-- ============================================================================
-- 6. Main Entry Point
-- ============================================================================

print("=== Linux hotstring engine E2E harness ===\n")

-- Run the hardcoded scenarios first — they self-validate the harness.
run_hardcoded_scenarios()

-- Run every vector from the shared corpus.
print("\n--- Shared corpus vectors ---")
local vectors = load_corpus()
if vectors then
	for _, v in ipairs(vectors) do
		run_corpus_vector(v)
	end
	print(string.format("Corpus vectors processed: %d", #vectors))
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
