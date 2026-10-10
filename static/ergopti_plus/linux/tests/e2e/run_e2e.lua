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

-- The real daemon main(), one process per scenario (it runs once per
-- process), against a scripted keyboard and a model of the focused field.
-- These pin what no engine-level vector can: the injector's erase arithmetic,
-- the undo, and the order the hook and the daemon see keys in.
-- Startup focus invalidation deliberately forgets the unseen prefix. Positive
-- word-only cases first type a real separator and retain it in the independent
-- screen oracle; an empty modeled field never grants the engine that knowledge.
local DAEMON_SCENARIOS = {
	{ name = "an end-char trigger expands and keeps its terminator", keys = " adn ", screen = " ADN " },
	{ name = "Enter is a terminator", keys = " adn{ENTER}", screen = " ADN\n" },
	{ name = "an auto-expanding trigger fires on its last character", keys = "pk★", screen = "parce que" },
	-- "adn " → "ADN ", and the Backspace removes the REPLAYED space: undo must
	-- count it, or the first character of the replacement stays ("Aadn").
	{ name = "Backspace after an end-char expansion restores the trigger", keys = " adn {BS}", screen = " adn" },
	{ name = "Backspace after an auto expansion restores the trigger", keys = "pk★{BS}", screen = "pk★" },
	-- Backspace edits the buffer instead of wiping it and declaring a word start.
	{ name = "a corrected typo still expands", keys = " adx{BS}n ", screen = " ADN " },
	{ name = "a word-only trigger does not fire mid-word after a Backspace", keys = "xy{BS}adn ", screen = "xadn " },
	{ name = "a word-only trigger does not fire after an arrow key", keys = "x{LEFT}adn ", screen = "xadn " },
	-- Ctrl+Backspace deletes a word, not one character: it neither undoes the
	-- expansion over text that is already gone nor leaves the rest of the word
	-- in the buffer to complete a trigger (modified-backspace-2026-09-25).
	{ name = "Ctrl+Backspace after an expansion deletes a word and undoes nothing",
		keys = "hello adn {CBS}", screen = "hello " },
	{ name = "Ctrl+Backspace drops the whole word from the buffer", keys = "hello adnx{CBS} ", screen = "hello  " },
	-- The same edits with the AI prediction engine loaded, as in the demo
	-- configuration: its cancel on Backspace reset the buffer behind the edit.
	{ name = "with AI loaded, a corrected typo still expands", keys = " adx{BS}n ", screen = " ADN ", llm = true },
	{ name = "with AI loaded, a word-only trigger does not fire mid-word after a Backspace",
		keys = "xy{BS}adn ", screen = "xadn ", llm = true },
	{ name = "with AI loaded, an end-char trigger expands", keys = " adn ", screen = " ADN ", llm = true },
	-- Without luv the daemon's clock counts whole seconds, and two keys typed
	-- together read a second apart whenever that second turns over between
	-- them: the 0.75 s expansion delay then dropped the trigger. This is the
	-- stubbed CI step's clock, where the AI twin above once failed that way.
	{ name = "a trigger typed across a clock second still expands", keys = " ad{TICK}n ", screen = " ADN ",
		clock = "seconds" },
	{ name = "with AI loaded, a corrected typo typed across a clock second still expands",
		keys = " adx{BS}{TICK}n ", screen = " ADN ", llm = true, clock = "seconds" },
	-- Two seconds on that clock is more than one of real pause: the delay holds.
	{ name = "a pause the whole-second clock can prove still expires the trigger", keys = " ad{TICK}{TICK}n ",
		screen = " adn ", clock = "seconds" },
	-- A touchpad reader that fails stops the reader alone: the same module
	-- still runs the tap actions (gesture-pump-keeps-actions).
	{ name = "a failing touchpad pump leaves the tap actions running", keys = "{PUMP}{TAP}",
		screen = "[reader stopped]<select_all>", gesture_pump = "fails" },
	{ name = "an unknown initial suffix does not authorize a word-only trigger",
		keys = "adn ", screen = "adn " },
	{ name = "with AI loaded, an unknown initial suffix does not authorize a word-only trigger",
		keys = "adn ", screen = "adn ", llm = true },
}

-- These scenarios use the neutral template and explicit acknowledged choices,
-- independently of the recommended-preset runs below. The deferred action
-- replaces a live selection while PRIMARY retains its original bytes.
local TAP_WRAP_SCENARIOS = {
	{ name = "a consumed tap key retires the previous wrap selection", tap_wrap = "accepted",
		keys = "{SELECT}{TAPKEY}{WRAP}", screen = "replacement(",
		receipt = "attempts=1 queued=1 executed=1 reads=1 action=send_text binding=tap_key__number_row_left" },
	{ name = "a new pointer selection can wrap after a consumed tap key", tap_wrap = "reopened",
		keys = "{SELECT}{TAPKEY}{SELECT}{WRAP}", screen = "(fresh)",
		receipt = "attempts=1 queued=1 executed=1 reads=3 action=send_text binding=tap_key__number_row_left" },
	{ name = "an unassigned tap key keeps the ordinary selection wrap", tap_wrap = "unassigned",
		keys = "{SELECT}{TAPKEY}{WRAP}", screen = "(selected)(",
		receipt = "attempts=0 queued=0 executed=0 reads=2 action=none binding=none" },
	{ name = "a modified tap key keeps the ordinary selection wrap", tap_wrap = "modified",
		keys = "{SELECT}{TAPKEY}{WRAP}", screen = "(selected)(",
		receipt = "attempts=0 queued=0 executed=0 reads=2 action=none binding=none" },
	{ name = "a refused tap queue keeps the ordinary selection wrap", tap_wrap = "refused",
		keys = "{SELECT}{TAPKEY}{WRAP}", screen = "(selected)(",
		receipt = "attempts=1 queued=0 executed=0 reads=2 action=none binding=none" },
}

-- A real consumed down owns repeats only while its native epochs and owners
-- remain valid. A refused repeat stays swallowed until release, even if the
-- pause, group or inhibition is restored before the next repeat.
local MAGIC_REPEAT_SCENARIOS = {
	{ name = "a captured assigned source refuses without changing configuration", magic_repeat = "tap-choice", keys = "",
		screen = "", tap_collision_receipt = "choice=false reason=menu.shortcuts.keyboard.magic_editor_reason.explicit_assignment source=KeyJ tap=send_text queued=0 executed=0 bytes=true captured=menu.shortcuts.keyboard.magic_editor_reason.explicit_assignment" },
	{ name = "old conflicting magic intent preserves acknowledged tap priority", magic_repeat = "tap-legacy", keys = "",
		screen = "replacement", tap_collision_receipt = "choice=false reason=menu.shortcuts.keyboard.magic_editor_reason.explicit_assignment source=Backquote tap=send_text queued=1 executed=1 bytes=false captured=nil" },
	{ name = "disabled shortcut delivery releases old conflicting native source", magic_repeat = "tap-off", keys = "",
		screen = "★★★", tap_collision_receipt = "choice=false reason=menu.shortcuts.keyboard.magic_editor_reason.explicit_assignment source=Backquote tap=send_text queued=0 executed=0 bytes=false captured=nil" },
	{ name = "paused conflicting sources produce no automated output", magic_repeat = "tap-paused", keys = "",
		screen = "", tap_collision_receipt = "choice=false reason=menu.shortcuts.keyboard.magic_editor_reason.explicit_assignment source=Backquote tap=send_text queued=0 executed=0 bytes=false captured=nil" },
	{ name = "none releases configured source ownership", magic_repeat = "tap-none", keys = "",
		screen = "★★★", tap_collision_receipt = "choice=true reason=nil source=Backquote tap=none queued=0 executed=0 bytes=false captured=nil" },
	{ name = "modified old conflicting sources preserve the physical chord", magic_repeat = "tap-modified", keys = "",
		screen = "", tap_collision_receipt = "choice=false reason=menu.shortcuts.keyboard.magic_editor_reason.explicit_assignment source=Backquote tap=send_text queued=0 executed=0 bytes=false captured=nil" },
	{ name = "a held physical magic key emits every acknowledged repeat", magic_repeat = "accepted", keys = "",
		screen = "★★★", magic_receipt = "decisions=1 dispatched=3 attempts=3 origins=1 raw=0 chosen=0" },
	{ name = "a refused magic injection retires the held press", magic_repeat = "injection", keys = "",
		screen = "★", magic_receipt = "decisions=1 dispatched=1 attempts=2 origins=1 raw=0 chosen=0" },
	{ name = "an untrusted origin cannot own magic repeats", magic_repeat = "untrusted", keys = "",
		screen = "★", magic_receipt = "decisions=1 dispatched=1 attempts=1 origins=1 raw=0 chosen=0" },
	{ name = "a captured magic source consumes the held answer once", magic_repeat = "capture", keys = "",
		screen = "", magic_receipt = "decisions=1 dispatched=0 attempts=0 origins=1 raw=0 chosen=1" },
	{ name = "a pause retires magic repeats through resume", magic_repeat = "paused", keys = "",
		screen = "★", magic_receipt = "decisions=1 dispatched=1 attempts=1 origins=1 raw=0 chosen=0" },
	{ name = "a group change retires magic repeats through restoration", magic_repeat = "group", keys = "",
		screen = "★", magic_receipt = "decisions=1 dispatched=1 attempts=1 origins=1 raw=0 chosen=0" },
	{ name = "a source choice retires the old held magic key", magic_repeat = "source", keys = "",
		screen = "★", magic_receipt = "decisions=1 dispatched=1 attempts=1 origins=1 raw=0 chosen=0" },
	{ name = "input inhibition retires magic repeats through release", magic_repeat = "inhibited", keys = "",
		screen = "★", magic_receipt = "decisions=1 dispatched=1 attempts=1 origins=1 raw=0 chosen=0" },
	{ name = "an origin epoch change retires magic repeats", magic_repeat = "origin", keys = "",
		screen = "★", magic_receipt = "decisions=1 dispatched=1 attempts=1 origins=2 raw=0 chosen=0" },
	{ name = "an initial compose refusal retires the magic press through recovery", magic_repeat = "compose-first", keys = "",
		screen = "★", magic_receipt = "decisions=1 dispatched=1 attempts=1 origins=1 raw=0 chosen=0" },
	{ name = "a refused compose retirement suppresses magic repeats", magic_repeat = "compose", keys = "",
		screen = "★", magic_receipt = "decisions=1 dispatched=1 attempts=1 origins=1 raw=0 chosen=0" },
}

-- Each scenario runs in its own daemon child, started through the shell that
-- io.popen and os.execute hand a command to: /bin/sh on Linux, cmd.exe on
-- Windows. cmd.exe has no `NAME=value command` prefix, no single quotes and no
-- /dev/null, so the same child is spelled once per shell; the child itself
-- needs no POSIX shell, and on Windows it runs the daemon under the suite's
-- Windows test mode, which also gives it an isolated HOME of its own.
local ON_WINDOWS = require("tests.win_compat").is_windows()

--- A value quoted for /bin/sh.
--- @param value string
--- @return string
local function sh_quoted(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- A value quoted for cmd.exe. Between double quotes cmd keeps & | < > ^
--- literal but still expands %NAME% and cannot escape a quote, so a value
--- carrying either is refused rather than sent altered.
--- @param value string
--- @return string
local function cmd_quoted(value)
	value = tostring(value)
	if value:find('[%%"\r\n]') then
		error(string.format("run_e2e: %q cannot cross cmd.exe unaltered", value), 2)
	end
	return '"' .. value .. '"'
end

--- The command that runs one daemon child.
--- @param interpreter string The Lua interpreter running this harness.
--- @param env table Ordered list of { name, value } for the child's environment.
--- @param device string The device file the daemon is pointed at.
--- @param keys string The child's key script.
--- @param quiet boolean True to discard stdout as well as stderr.
--- @return string
local function daemon_child_command(interpreter, env, device, keys, quiet)
	local parts = {}
	if ON_WINDOWS then
		for _, pair in ipairs(env) do
			parts[#parts + 1] = "set " .. cmd_quoted(pair[1] .. "=" .. pair[2]) .. " &"
		end
		parts[#parts + 1] = cmd_quoted((interpreter:gsub("/", "\\")))
		parts[#parts + 1] = "tests/e2e/daemon_keys_child.lua tests/e2e/fixtures/daemon_keys.toml"
		parts[#parts + 1] = cmd_quoted(device)
		parts[#parts + 1] = cmd_quoted(keys)
		parts[#parts + 1] = quiet and ">NUL 2>&1" or "2>NUL"
		return table.concat(parts, " ")
	end
	for _, pair in ipairs(env) do parts[#parts + 1] = pair[1] .. "=" .. sh_quoted(pair[2]) end
	parts[#parts + 1] = sh_quoted(interpreter)
	parts[#parts + 1] = "tests/e2e/daemon_keys_child.lua tests/e2e/fixtures/daemon_keys.toml"
	parts[#parts + 1] = sh_quoted(device)
	parts[#parts + 1] = sh_quoted(keys)
	parts[#parts + 1] = quiet and ">/dev/null 2>&1" or "2>/dev/null"
	return table.concat(parts, " ")
end

do
	print("\n--- Daemon key scenarios (real main(), scripted keyboard) ---")
	local interpreter = arg and arg[-1] or "luajit"
	-- On Windows the child's test mode supplies HOME; on Linux the scenarios
	-- share one scratch HOME, created here.
	local home_env = {}
	local home = nil
	if not ON_WINDOWS then
		home = os.tmpname()
		os.remove(home)
		local made = os.execute("mkdir -p " .. sh_quoted(home))
		if not (made == true or made == 0) then error("run_e2e: cannot create the scratch HOME " .. home) end
		home_env = { { "HOME", home } }
	end
	-- POSIX os.tmpname() creates the file; the Windows one only names it.
	local device = os.tmpname()
	local device_fh = assert(io.open(device, "w"))
	device_fh:close()
	--- Runs every key scenario in one user state.
	--- @param base_env table Ordered { name, value } pairs naming the state's folders.
	--- @param prefix string Label prefix naming the state.
	--- @param scenarios table|nil Explicit neutral scenarios, or the existing typing scenarios.
	local function run_key_scenarios(base_env, prefix, scenarios)
		for _, scenario in ipairs(scenarios or DAEMON_SCENARIOS) do
			local env = {}
			for _, pair in ipairs(base_env) do env[#env + 1] = pair end
			env[#env + 1] = { "ERGOPTI_E2E_LLM", scenario.llm and "1" or "0" }
			env[#env + 1] = { "ERGOPTI_E2E_GESTURE_PUMP", scenario.gesture_pump or "none" }
			env[#env + 1] = { "ERGOPTI_E2E_CLOCK", scenario.clock or "system" }
			env[#env + 1] = { "ERGOPTI_E2E_TAP_WRAP", scenario.tap_wrap or "none" }
			env[#env + 1] = { "ERGOPTI_E2E_MAGIC_REPEAT", scenario.magic_repeat or "none" }
			local command = daemon_child_command(interpreter, env, device, scenario.keys, false)
			local pipe = io.popen(command, "r")
			local output = pipe and pipe:read("*a") or ""
			if pipe then pipe:close() end
			if scenario.tap_collision_receipt then
				local receipt = output:match("TAP_COLLISION ([^\r\n]+)")
				if receipt == scenario.tap_collision_receipt then
					pass(prefix .. scenario.name .. " (exact admission receipt)")
				else
					fail(prefix .. scenario.name .. " (exact admission receipt)", scenario.tap_collision_receipt, receipt or "absent")
				end
			end
			if scenario.receipt then
				local receipt = output:match("TAP_WRAP ([^\r\n]+)")
				if receipt == scenario.receipt then
					pass(prefix .. scenario.name .. " (exact owner receipt)")
				else
					fail(prefix .. scenario.name .. " (exact owner receipt)", scenario.receipt, receipt or "absent")
				end
			end
			if scenario.magic_receipt then
				local receipt = output:match("MAGIC_REPEAT ([^\r\n]+)")
				if receipt == scenario.magic_receipt then
					pass(prefix .. scenario.name .. " (exact repeat receipt)")
				else
					fail(prefix .. scenario.name .. " (exact repeat receipt)", scenario.magic_receipt, receipt or "absent")
				end
			end
			local quoted = output:match("SCREEN (%b\"\")")
			local screen = quoted and (loadstring or load)("return " .. quoted)() or nil
			if screen == scenario.screen then
				pass(prefix .. scenario.name)
			else
				fail(prefix .. scenario.name, string.format("%q", scenario.screen),
					screen and string.format("%q", screen) or ("no SCREEN line: " .. output:sub(-300)))
			end
		end
	end
	run_key_scenarios(home_env, "")
	run_key_scenarios(home_env, "", TAP_WRAP_SCENARIOS)
	run_key_scenarios(home_env, "", MAGIC_REPEAT_SCENARIOS)

	-- hardening-e-presets: the same keys over the recommended preset, committed
	-- by a start-up child through the menu's own composition in a folder tree
	-- of its own. A default change must not silently break a feature the
	-- neutral defaults keep working, nor the other way round (45704357d).
	if not ON_WINDOWS then
		local preset = os.tmpname()
		os.remove(preset)
		local preset_env = {
			{ "HOME", preset },
			{ "XDG_CONFIG_HOME", preset .. "/.config" },
			{ "XDG_STATE_HOME", preset .. "/.local/state" },
			{ "XDG_DATA_HOME", preset .. "/.local/share" },
			{ "XDG_CACHE_HOME", preset .. "/.cache" },
		}
		local made = os.execute("mkdir -p " .. sh_quoted(preset))
		if not (made == true or made == 0) then error("run_e2e: cannot create the preset HOME " .. preset) end
		local parts = {}
		for _, pair in ipairs(preset_env) do parts[#parts + 1] = pair[1] .. "=" .. sh_quoted(pair[2]) end
		parts[#parts + 1] = sh_quoted(interpreter) .. " tests/e2e/startup_child.lua"
		parts[#parts + 1] = sh_quoted(device) .. " restore_recommended " .. sh_quoted(driver_root)
		parts[#parts + 1] = sh_quoted(driver_root .. "/_generated/config_template.toml") .. " 2>&1"
		local pipe = io.popen(table.concat(parts, " "), "r")
		local output = pipe and pipe:read("*a") or ""
		if pipe then pipe:close() end
		if output:find("E2E_FACT restore_committed=true", 1, true) then
			run_key_scenarios(preset_env, "recommended preset: ")
		else
			fail("hardening-e-presets: the recommended preset is committed for the key scenarios",
				"restore_committed=true", output:sub(-300))
		end
		os.execute("rm -rf " .. sh_quoted(preset))
	end

	-- The real tray menu, every module loaded, rows counted without GTK. The
	-- ceiling is generous for a menu people navigate and far below the 103 058
	-- rows the inline action lists once produced (eight seconds of GTK per
	-- rebuild, and a dbusmenu layout no panel can page through).
	local MENU_ROW_CEILING = 3000
	local rows_file = os.tmpname()
	local rows_env = {}
	for _, pair in ipairs(home_env) do rows_env[#rows_env + 1] = pair end
	rows_env[#rows_env + 1] = { "ERGOPTI_E2E_MENU_ROWS", rows_file }
	os.execute(daemon_child_command(interpreter, rows_env, device, "a", true))
	local rows_fh = io.open(rows_file, "r")
	local rows = rows_fh and tonumber(rows_fh:read("*l")) or nil
	if rows_fh then rows_fh:close() end
	os.remove(rows_file)
	if rows and rows > 100 and rows <= MENU_ROW_CEILING then
		pass(string.format("the real tray menu has %d rows (ceiling %d)", rows, MENU_ROW_CEILING))
	else
		fail("the real tray menu stays navigable", string.format("100 < rows <= %d", MENU_ROW_CEILING),
			tostring(rows))
	end

	os.remove(device)
	if home then os.execute("rm -rf " .. sh_quoted(home)) end
end

do
	print("\n--- Installed-driver start-up scenarios (real main(), every module loaded) ---")
	dofile(driver_root .. "/tests/e2e/startup_scenarios.lua").run({
		pass = pass,
		fail = fail,
		skip = function(label) print(string.format("  SKIP  %s", label)) end,
	}, { driver = driver_root, interpreter = arg and arg[-1] or "luajit" })
end

do
	local native_ok = pcall(require, "luv")
	local ffi_ok = pcall(require, "ffi")
	if native_ok and ffi_ok and package.config:sub(1, 1) == "/" then
		local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
		local fixture = driver_root .. "/tests/fixtures/native_file_digest_owners.lua"
		local result = os.execute(quote(assert(arg[-1])) .. " " .. quote(fixture))
		assert_true("linux-digest-owner: updater cancellation preserves a real unrelated digest", result == true or result == 0)
	else
		print("  SKIP  native digest owner isolation requires libuv and LuaJIT FFI")
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
