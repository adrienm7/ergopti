--- tests/unit/meta/test_fakes_match_adapters.lua

--- ==============================================================================
--- MODULE: A Fake That Drifts Tests Nothing
--- DESCRIPTION:
--- Asserts that every function a real adapter exports also exists on its
--- in-memory double, and that the double answers in the same shapes.
---
--- WHY THIS IS THE MOST IMPORTANT FILE IN tests/fakes:
--- A test double is a claim about a contract, and a claim nobody checks rots
--- silently — the suite keeps passing while the real adapter moves underneath it.
--- This driver has been bitten by exactly that more than once: a bridge test that
--- spoke a protocol the page had never used; a gesture suite green against a
--- recogniser nothing fed; a Hammerspoon stub whose keycodes table lacked the one
--- function the module called, which passed locally and failed in CI because the
--- two ran their files in a different order.
---
--- Each of those was a green test measuring nothing. The fakes exist to let more
--- of the driver be tested without hardware; this is what stops them becoming a
--- second, comfortable reality.
---
--- WHAT IT DELIBERATELY DOES NOT CHECK:
--- Behaviour. A fake shell runner records commands instead of running them, and
--- that difference IS the point. What must not differ is the surface: a module
--- calling a function the fake lacks fails at the call, which is a test failure
--- about the fake rather than about the code under test — the most misleading
--- kind there is.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fakes = helpers.load_module("tests.fakes")

-- Each real adapter and the fake that stands for it. Private helpers (leading
-- underscore) are excluded: they are seams for the real adapter's own tests and
-- carry no contract for a caller.
local PAIRS = {
	{ adapter = "adapters.uinput_writer",   make = function() return Fakes.uinput_writer() end },
	{ adapter = "adapters.evdev_reader",    make = function() return Fakes.evdev_reader() end },
	{ adapter = "adapters.shell_runner",    make = function() return Fakes.shell_runner() end },
	{ adapter = "adapters.storage",         make = function() return Fakes.storage() end },
	{ adapter = "adapters.clipboard",       make = function() return Fakes.clipboard() end },
	{ adapter = "adapters.timer_scheduler", make = function() return Fakes.timer_scheduler() end },
}




-- =================================================================
-- =================================================================
-- ======= 1/ The surface matches ==================================
-- =================================================================
-- =================================================================

helpers.describe("fakes: every adapter function exists on its double", function()

	for _, pair in ipairs(PAIRS) do
		helpers.it(pair.adapter .. " is fully covered by its fake", function()
			local real = helpers.load_module(pair.adapter)
			local fake = pair.make()

			local missing = {}
			local checked = 0
			for name, value in pairs(real) do
				if type(value) == "function" and name:sub(1, 1) ~= "_" then
					checked = checked + 1
					if type(fake[name]) ~= "function" then missing[#missing + 1] = name end
				end
			end

			helpers.assert_true(checked > 0, string.format(
				"no public functions were found on %s — the adapter moved or the scan "
					.. "broke, and either way this check now proves nothing", pair.adapter))
			helpers.assert_eq(#missing, 0, string.format(
				"%s exports %d function(s) the fake does not have: %s. A module calling "
					.. "one of them fails at the call, which reads as a bug in the code "
					.. "under test rather than in the double.",
				pair.adapter, #missing, table.concat(missing, ", ")))
		end)
	end

	helpers.it("covers every adapter a fake claims to stand for", function()
		-- The inverse direction, so a fake cannot invent a port that does not
		-- exist — which would let a module be written against something the driver
		-- has no adapter for and still look tested.
		for _, pair in ipairs(PAIRS) do
			local ok = pcall(require, pair.adapter)
			helpers.assert_true(ok, pair.adapter .. " must be a real module")
		end
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ The answers have the same shape ======================
-- =================================================================
-- =================================================================

helpers.describe("fakes: the shapes callers depend on", function()

	helpers.it("storage round-trips a value and reports absence as the default", function()
		local storage = Fakes.storage()
		helpers.assert_eq(storage.get("nothing", "fallback"), "fallback",
			"an unset key must return the caller's default, not nil — several modules "
				.. "distinguish a stored false from an unset key by exactly this")
		storage.set("k", false)
		helpers.assert_eq(storage.get("k", true), false,
			"and a stored FALSE must survive: it is the value most often mistaken "
				.. "for unset")
	end)

	helpers.it("the uinput fake records order, which is what chords depend on", function()
		local writer = Fakes.uinput_writer()
		writer.open()
		writer.emit(29, 1)
		writer.emit(106, 1)
		writer.emit(106, 0)
		writer.emit(29, 0)
		helpers.assert_eq(#writer.events, 4, "every event is kept")
		helpers.assert_eq(writer.pressed()[1], 29,
			"the modifier goes down first; a chord that releases it before the key "
				.. "it modifies leaves the application seeing a bare keystroke")
	end)

	helpers.it("the evdev fake replays a scripted event list once", function()
		local reader = Fakes.evdev_reader({ events = {
			{ type = 1, code = 30, value = 1 },
			{ type = 1, code = 30, value = 0 },
		} })
		reader.open("/dev/input/event0", reader.KEYBOARD)
		local seen = 0
		helpers.assert_eq(reader.drain(function() seen = seen + 1 end, reader.KEYBOARD), 2)
		helpers.assert_eq(seen, 2)
		helpers.assert_eq(reader.drain(function() seen = seen + 1 end, reader.KEYBOARD), 0,
			"a drained queue stays drained — a fake that replays for ever turns any "
				.. "read loop into an infinite one")
	end)

	helpers.it("the scheduler fires nothing until the test says time passed", function()
		local scheduler = Fakes.timer_scheduler()
		local fired = 0
		scheduler.after(0.5, function() fired = fired + 1 end)
		helpers.assert_eq(fired, 0, "no wall clock is involved")
		helpers.assert_eq(scheduler.advance(0.4), 0, "and nothing fires early")
		helpers.assert_eq(scheduler.advance(0.2), 1, "only once its moment has passed")
		helpers.assert_eq(fired, 1)
	end)

	helpers.it("a repeating timer fires again without looping the advance", function()
		local scheduler = Fakes.timer_scheduler()
		local fired = 0
		scheduler.every(1.0, function() fired = fired + 1 end)
		scheduler.advance(1.0)
		scheduler.advance(1.0)
		helpers.assert_eq(fired, 2,
			"a repeat must re-arm; running it inside the same pass would spin for ever")
	end)

	helpers.it("the shell fake records instead of running", function()
		local shell = Fakes.shell_runner({ answers = { ["xdotool getactivewindow"] = "42" } })
		helpers.assert_eq(shell.exec_line("xdotool getactivewindow"), "42")
		helpers.assert_eq(#shell.commands, 1,
			"what a caller asserts is WHICH command was built; running it for real "
				.. "would touch the developer's session and prove nothing")
	end)

	helpers.it("the clipboard fake restores what it had after a paste", function()
		local clipboard = Fakes.clipboard({ initial = "previous" })
		clipboard.paste_text("injected")
		helpers.assert_eq(clipboard.read(), "previous",
			"the real one saves, sets, pastes and restores, and a user losing their "
				.. "clipboard to an expansion is the defect that path exists to avoid")
	end)

end)
