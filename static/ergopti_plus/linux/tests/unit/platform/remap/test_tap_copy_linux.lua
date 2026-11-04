--- tests/unit/platform/remap/test_tap_copy_linux.lua

--- ==============================================================================
--- MODULE: Tap-Hold Copy (Linux)
--- DESCRIPTION:
--- Drives the Linux copy owner over a fake clipboard counter and clock, and
--- the X11 counter read over a fake shell: the copy is checked against the
--- counter read before Ctrl+C, sent again once when it did not move, the user
--- is warned when it never did, and a session without a counter is said once.
--- ==============================================================================

local helpers = require("tests.helpers")
local TapCopy = require("platform.remap.tap_copy")

--- @param options table|nil { reason = string, copies = { [n] = true }, copy_on_send = boolean }
local function world(options)
	options = options or {}
	local w = { counter = 1000, sends = 0, warnings = 0, logs = {}, timers = {}, now = 0, focus = "field-a" }
	w.owner = TapCopy.new({
		verify_ms = 300,
		read_counter = function()
			if options.reason then return nil, options.reason end
			return w.counter
		end,
		capture_destination = function() return w.focus end,
		destination_current = function(destination)
			if w.reenter then w.owner:activity() end
			return destination == w.focus
		end,
		send_copy = function()
			w.sends = w.sends + 1
			if options.copies and options.copies[w.sends] then w.counter = w.counter + 1 end
			return true
		end,
		after = function(delay_ms, callback)
			local timer = { at = w.now + delay_ms, callback = callback }
			w.timers[#w.timers + 1] = timer
			return timer
		end,
		cancel = function(timer) timer.cancelled = true end,
		log = function(level, fmt, ...) w.logs[#w.logs + 1] = { level = level, text = string.format(fmt, ...) } end,
		warn_user = function() w.warnings = w.warnings + 1 end,
	})
	function w.advance(ms)
		w.now = w.now + ms
		local pending = w.timers
		w.timers = {}
		for _, timer in ipairs(pending) do
			if not timer.cancelled then
				if timer.at <= w.now then timer.callback() else w.timers[#w.timers + 1] = timer end
			end
		end
	end
	function w.tap()
		w.owner:run("tap_hold__left_shift", function()
			if options.copy_on_send then w.counter = w.counter + 1 end
		end)
	end
	return w
end

helpers.describe("Linux tap-hold copy (tap-copy-verified)", function()
	helpers.it("does not retry after focus or physical activity changes (tap-copy-context)", function()
		for _, change in ipairs({
			function(w) w.focus = "field-b" end,
			function(w) w.owner:activity() end,
			function(w) w.reenter = true end,
			function(w) w.focus = nil end,
		}) do
			local w = world()
			w.tap()
			change(w)
			w.advance(300)
			helpers.assert_eq(w.sends, 0)
			helpers.assert_eq(w.warnings, 0)
			helpers.assert_true(w.logs[1].text:find("original context is no longer proven", 1, true) ~= nil)
		end
	end)
	helpers.it("a Ctrl+C that moved the counter is verified (tap-copy-verified)", function()
		local w = world({ copy_on_send = true })
		w.tap()
		w.advance(300)
		helpers.assert_eq(w.sends, 0)
		helpers.assert_eq(w.warnings, 0)
		helpers.assert_eq(w.logs[1].level, "debug")
	end)

	helpers.it("a Ctrl+C that landed on the retry is logged, not warned (tap-copy-verified)", function()
		local w = world({ copies = { [1] = true } })
		w.tap()
		w.advance(300)
		helpers.assert_eq(w.sends, 1)
		w.advance(300)
		helpers.assert_eq(w.warnings, 0)
		helpers.assert_eq(w.logs[1].level, "warn")
	end)

	helpers.it("a Ctrl+C that never landed warns the user (tap-copy-verified)", function()
		local w = world()
		w.tap()
		w.advance(300)
		w.advance(300)
		helpers.assert_eq(w.sends, 1)
		helpers.assert_eq(w.warnings, 1)
	end)

	helpers.it("a session without a counter is said once and never warned (tap-copy-verified)", function()
		local w = world({ reason = "unsupported" })
		w.tap()
		w.tap()
		w.advance(1000)
		helpers.assert_eq(#w.logs, 1)
		helpers.assert_eq(w.logs[1].level, "info")
		helpers.assert_eq(w.warnings, 0)
		helpers.assert_eq(w.sends, 0)
	end)

	helpers.it("pause abandons the pending check (tap-copy-verified)", function()
		local w = world()
		w.tap()
		w.owner:stop()
		w.advance(1000)
		helpers.assert_eq(w.sends, 0)
		helpers.assert_eq(w.warnings, 0)
	end)
end)

helpers.describe("X11 clipboard change counter (tap-copy-verified)", function()
	--- Loads the clipboard adapter over a fake shell and display.
	local function with_adapter(display, reply, body)
		local names = { clipboard = "adapters.clipboard", shell = "adapters.shell_runner", display = "infra.display_server" }
		local previous = {}
		for key, name in pairs(names) do previous[key] = package.loaded[name] end
		local shell = { commands = {} }
		function shell.has_command() return true end
		function shell.exec_checked(command)
			shell.commands[#shell.commands + 1] = command
			return reply.ok, reply.output or "", reply.ok and nil or "failed"
		end
		package.loaded[names.shell] = shell
		package.loaded[names.display] = {
			UNKNOWN = "unknown",
			is_wayland = function() return display == "wayland" end,
			is_x11 = function() return display == "x11" end,
			kind = function() return display end,
		}
		package.loaded[names.clipboard] = nil
		local ok, err = pcall(function() body(require(names.clipboard), shell) end)
		for key, name in pairs(names) do package.loaded[name] = previous[key] end
		package.loaded[names.clipboard] = nil
		helpers.assert_true(ok, tostring(err))
	end

	helpers.it("reads the owner's TIMESTAMP as raw little-endian bytes (tap-copy-verified)", function()
		with_adapter("x11", { ok = true, output = string.char(0x10, 0x27, 0x00, 0x00) }, function(Clipboard, shell)
			helpers.assert_eq(Clipboard.change_counter(), 10000)
			helpers.assert_true(shell.commands[1]:find("-t TIMESTAMP", 1, true) ~= nil, "asks for the TIMESTAMP target")
		end)
	end)

	helpers.it("reads a decimal TIMESTAMP too (tap-copy-verified)", function()
		with_adapter("x11", { ok = true, output = "123456\n" }, function(Clipboard)
			helpers.assert_eq(Clipboard.change_counter(), 123456)
		end)
	end)

	helpers.it("an owner that does not answer is unreadable, not a counter (tap-copy-verified)", function()
		with_adapter("x11", { ok = false }, function(Clipboard)
			local counter, reason = Clipboard.change_counter()
			helpers.assert_eq(counter, nil)
			helpers.assert_eq(reason, "unreadable")
		end)
	end)

	helpers.it("Wayland has no counter (tap-copy-verified)", function()
		with_adapter("wayland", { ok = true, output = "1" }, function(Clipboard, shell)
			local counter, reason = Clipboard.change_counter()
			helpers.assert_eq(counter, nil)
			helpers.assert_eq(reason, "unsupported")
			helpers.assert_eq(#shell.commands, 0, "no command is run where none could answer")
		end)
	end)
end)
