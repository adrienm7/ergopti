--- tests/unit/meta/test_injector_commands.lua

--- ==============================================================================
--- MODULE: Injector — the events it puts on the wire
--- DESCRIPTION:
--- The exact evdev events an injection emits, recorded from the uinput channel.
---
--- WHY THIS FILE CHANGED SHAPE:
--- It used to assert the shape of shell commands: that backspaces went out in one
--- `ydotool key` invocation, that the replacement was passed after `--`, and that
--- an embedded apostrophe was escaped with the POSIX close-escape-reopen idiom.
--- Every one of those was a real concern, and every one has been DELETED rather
--- than fixed — there is no shell on this path any more. The injector writes
--- struct input_event to the driver's own uinput device, the same one the
--- keyboard hook re-emits through, so there is nothing left to quote and nothing
--- left to spawn.
---
--- What replaces them is stricter, not weaker. A command string can be asserted
--- without ever being run; these cases assert the events themselves, in order,
--- which is exactly what the application receives.
---
--- The property the old file existed for is carried over and strengthened:
--- user-authored replacement text must not be able to do anything but appear as
--- text. It cannot, because it never becomes a command — and that is asserted
--- against os.execute and io.popen directly rather than against a seam.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A recording uinput channel.
--- @return table channel, table events Ordered "code:value" strings.
local function recorder()
	local events = {}
	return {
		is_open = function() return true end,
		emit = function(code, value)
			events[#events + 1] = string.format("%d:%d", code, value)
			return true
		end,
	}, events
end

--- Loads the injector with a recorder and a layout that can type `chars`.
--- @param chars string Characters the stub layout knows, keycodes from 200 up.
--- @return table injector, table events, table code_of
local function with_recorder(chars)
	local layout_table, code_of = {}, {}
	local code = 200
	for i = 1, #(chars or "") do
		local char = (chars):sub(i, i)
		layout_table[char] = { keycode = code, level = 1, mods = {} }
		code_of[char] = code
		code = code + 1
	end

	local layout = helpers.load_module("adapters.keyboard_layout")
	layout._set_table_for_test(layout_table)
	package.loaded["adapters.keyboard_layout"] = layout

	-- The stub has to still be in force when the injector reads it, and on CI it
	-- has not always been: this file has gone red as a block, under LuaJIT only,
	-- on a commit that also went green — nine assertions failing at once because
	-- the setup silently lost, not because nine behaviours changed. Asserting the
	-- setup here names the cause on the spot instead of leaving that to be
	-- reconstructed from a wall of downstream failures.
	if (chars or "") ~= "" then
		helpers.assert_true(layout.is_ready(),
			"the stub layout was installed and then lost before the test ran — "
				.. "adapters.keyboard_layout.refresh() clears the table when no keymap "
				.. "is available, which is every CI runner")
	end

	local injector = helpers.load_module("modules.hotstrings.injector")
	local channel, events = recorder()
	injector._set_uinput(channel)
	return injector, events, code_of
end





-- =================================================================
-- =================================================================
-- ======= 1/ Erasing the trigger ==================================
-- =================================================================
-- =================================================================

helpers.describe("injector: the erase phase", function()

	helpers.it("emits exactly one down/up pair per backspace", function()
		local injector, events = with_recorder("")
		injector.inject(3, "")
		helpers.assert_eq(table.concat(events, " "), "14:1 14:0 14:1 14:0 14:1 14:0",
			"three presses and three releases, in order; a missing release leaves "
				.. "Backspace held and the application deletes until it is let go")
	end)

	helpers.it("emits nothing for a zero count", function()
		local injector, events = with_recorder("")
		injector.inject(0, "")
		helpers.assert_eq(#events, 0, "there is nothing to erase")
	end)

	helpers.it("emits nothing for a negative count", function()
		local injector, events = with_recorder("")
		injector.inject(-2, "")
		helpers.assert_eq(#events, 0,
			"a negative count is a bug upstream, and pressing Backspace is not the "
				.. "way to report it")
	end)

	helpers.it("takes the Backspace keycode from the shared constants", function()
		local injector, events = with_recorder("")
		local codes = helpers.load_module("infra.evdev_codes")
		injector.inject(1, "")
		helpers.assert_eq(events[1], codes.KEY_BACKSPACE .. ":1",
			"one number in one place; a second literal 14 in the injector is how the "
				.. "erase and the key it names drift apart")
		helpers.assert_eq(codes.KEY_BACKSPACE, 14, "and it is still 14")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 2/ Typing the replacement ===============================
-- =================================================================
-- =================================================================

helpers.describe("injector: the type phase", function()

	helpers.it("types each character as a press and a release", function()
		local injector, events, code_of = with_recorder("abc")
		injector.inject(0, "cab")
		helpers.assert_eq(table.concat(events, " "), string.format(
			"%d:1 %d:0 %d:1 %d:0 %d:1 %d:0",
			code_of.c, code_of.c, code_of.a, code_of.a, code_of.b, code_of.b),
			"in typing order, with every key released before the next is pressed")
	end)

	helpers.it("erases before it types", function()
		local injector, events, code_of = with_recorder("a")
		injector.inject(2, "a")
		helpers.assert_eq(table.concat(events, " "), string.format(
			"14:1 14:0 14:1 14:0 %d:1 %d:0", code_of.a, code_of.a),
			"typing first would delete the replacement's own tail")
	end)

	helpers.it("wraps the modifier around the key, not around the string", function()
		local layout = helpers.load_module("adapters.keyboard_layout")
		layout._set_table_for_test({
			A = { keycode = 30, level = 2, mods = { "shift" } },
			b = { keycode = 48, level = 1, mods = {} },
		})
		package.loaded["adapters.keyboard_layout"] = layout
		local injector = helpers.load_module("modules.hotstrings.injector")
		local channel, events = recorder()
		injector._set_uinput(channel)

		injector.inject(0, "Ab")
		local codes = helpers.load_module("infra.evdev_codes")
		helpers.assert_eq(table.concat(events, " "), string.format(
			"%d:1 30:1 30:0 %d:0 48:1 48:0", codes.KEY_LEFTSHIFT, codes.KEY_LEFTSHIFT),
			"Shift is released before the next character; a modifier left held turns "
				.. "every keystroke after it into a shortcut")
	end)

	helpers.it("emits nothing at all for a non-string replacement", function()
		local injector, events = with_recorder("abc")
		injector.inject(2, nil)
		helpers.assert_eq(#events, 0,
			"the guard runs before the erase, so a malformed call cannot delete the "
				.. "user's text and then fail to replace it")
	end)

	helpers.it("emits nothing for a non-numeric count", function()
		local injector, events = with_recorder("abc")
		injector.inject("2", "abc")
		helpers.assert_eq(#events, 0, "both arguments are validated, not just the first")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 3/ There is no shell left to escape into ================
-- =================================================================
-- =================================================================

helpers.describe("injector: replacement text is data, not a command", function()

	helpers.it("spawns no process while injecting", function()
		local injector, _, code_of = with_recorder("abc")

		-- Observed at os.execute and io.popen rather than through a seam: a test
		-- that watches the seam passes on an implementation that bypasses it.
		local real_execute, real_popen = os.execute, io.popen
		local spawned = {}
		os.execute = function(cmd) spawned[#spawned + 1] = tostring(cmd) ; return true end
		io.popen = function(cmd) spawned[#spawned + 1] = tostring(cmd) ; return nil end

		-- The inter-phase pause is allowed to spawn, and only on a runtime with
		-- neither FFI nor luv — which is the developer's plain Lua, never the
		-- daemon. Asserted as "nothing but a bare sleep" rather than "nothing at
		-- all" so the case stays honest on both interpreters instead of passing on
		-- one and failing on the other.
		injector._set_nanosleep_for_test(false)
		local ok, err = pcall(injector.inject, 3, "abc")
		injector._set_nanosleep_for_test(nil)

		os.execute, io.popen = real_execute, real_popen
		if not ok then error(err, 0) end

		for _, cmd in ipairs(spawned) do
			helpers.assert_true(cmd:match("^sleep [%d%.]+$") ~= nil,
				"an injection must not shell out. Replacement text is user-authored, "
					.. "so a command line is arbitrary code execution waiting for one "
					.. "call site to forget the quoting. Spawned: " .. cmd)
		end
		helpers.assert_true(code_of.a ~= nil, "and the layout stub was actually in use")
	end)

	helpers.it("carries a shell metacharacter through as an ordinary keystroke", function()
		local injector, events, code_of = with_recorder("$`&;")
		injector.inject(0, "$`&;")
		helpers.assert_eq(table.concat(events, " "), string.format(
			"%d:1 %d:0 %d:1 %d:0 %d:1 %d:0 %d:1 %d:0",
			code_of["$"], code_of["$"], code_of["`"], code_of["`"],
			code_of["&"], code_of["&"], code_of[";"], code_of[";"]),
			"four keystrokes and no interpretation — the characters that used to need "
				.. "escaping are now just keys")
	end)

	helpers.it("types an apostrophe like any other character", function()
		local injector, events, code_of = with_recorder("l'ami")
		injector.inject(0, "l'ami")
		helpers.assert_eq(#events, 10, "five characters, ten events")
		helpers.assert_eq(events[3], code_of["'"] .. ":1",
			"the quote that used to need the close-escape-reopen idiom is a keystroke")
	end)

end)
