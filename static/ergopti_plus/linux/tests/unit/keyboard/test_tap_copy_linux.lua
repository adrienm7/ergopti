--- tests/unit/keyboard/test_tap_copy_linux.lua

--- ==============================================================================
--- MODULE: Tap-Hold Copy (Linux)
--- DESCRIPTION:
--- Drives the Linux copy owner over a fake clipboard counter and clock, and
--- the X11 counter read over a fake shell: the copy is checked against the
--- counter read before Ctrl+C, sent again once when it did not move, the user
--- is warned when it never did, and a session without a counter is said once.
--- ==============================================================================

local helpers = require("tests.helpers")
local TapCopy = require("keyboard.engine.tap_copy")

--- @param options table|nil { reason = string, copies = { [n] = true }, copy_on_send = boolean }
local function world(options)
	options = options or {}
	local w = { counter = 1000, sends = 0, warnings = 0, logs = {}, timers = {}, now = 0, destination = "field-a" }
	w.owner = TapCopy.new({
		verify_ms = 300,
		capture_destination = function()
			if w.on_capture then w.on_capture() end
			local captured = w.destination
			if captured == nil then return nil end
			return { current = function()
				if w.on_check then w.on_check() end
				if w.current_error then error("focus check failed") end
				return captured == w.destination
			end }
		end,
		read_counter = function()
			if options.reason then return nil, options.reason end
			return w.counter
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
		end, function() return w.source_current ~= false end)
	end
	return w
end

helpers.describe("Linux tap-hold copy (tap-copy-verified)", function()
	helpers.it("does not retry after physical activity (tap-copy-context)", function()
		local w = world()
		w.tap()
		w.owner:activity()
		w.advance(300)
		helpers.assert_eq(w.sends, 0)
		helpers.assert_eq(w.warnings, 0)
		helpers.assert_true(w.logs[1].text:find("original context is no longer proven", 1, true) ~= nil)
	end)

	helpers.it("does not retry after physical activity during the focus proof", function()
		local w = world()
		w.tap()
		w.on_check = function() w.on_check = nil; w.owner:activity() end
		w.advance(300)
		helpers.assert_eq(w.sends, 0)
		helpers.assert_eq(w.warnings, 0)
		helpers.assert_true(w.logs[1].text:find("original context is no longer proven", 1, true) ~= nil)
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

	helpers.it("does not retry Ctrl+C after the focused field changes", function()
		local w = world()
		w.tap()
		w.destination = "field-b"
		w.advance(300)
		helpers.assert_eq(w.sends, 0, "a newer selection must not be copied")
	end)

	helpers.it("does not retry when the original destination is unknown", function()
		local w = world()
		w.destination = nil
		w.tap()
		w.destination = "field-b"
		w.advance(300)
		helpers.assert_eq(w.sends, 0)
	end)

	helpers.it("still sends the first copy when destination capture raises", function()
		local w = world()
		local initial = 0
		w.on_capture = function() error("focus unavailable") end
		w.owner:run("tap_hold", function() initial = initial + 1 end, function() return true end)
		helpers.assert_eq(initial, 1)
		w.advance(300)
		helpers.assert_eq(w.sends, 0)
	end)

	helpers.it("refuses the first copy if its source retires during destination capture", function()
		local w = world()
		local initial = 0
		w.on_capture = function() w.source_current = false end
		local accepted = w.owner:run("tap_hold", function() initial = initial + 1 end,
			function() return w.source_current ~= false end)
		helpers.assert_eq(accepted, false)
		helpers.assert_eq(initial, 0)
		w.advance(1000); helpers.assert_eq(w.sends, 0)
	end)

	helpers.it("does not retry after the original remap is replaced", function()
		local w = world()
		w.tap()
		w.source_current = false
		w.advance(300)
		helpers.assert_eq(w.sends, 0)
	end)

	helpers.it("does not retry if the focus proof raises", function()
		local w = world()
		w.tap()
		w.current_error = true
		w.advance(300)
		helpers.assert_eq(w.sends, 0)
	end)

	helpers.it("does not use an owner replaced during the focus check", function()
		local w = world()
		w.tap()
		w.on_check = function() w.on_check = nil; w.owner:stop() end
		w.advance(300)
		helpers.assert_eq(w.sends, 0)
	end)

	helpers.it("retires an old retry before capturing a new destination", function()
		local w = world()
		w.tap()
		local old_callback = w.timers[1].callback
		w.destination = "field-b"
		w.on_capture = function() w.on_capture = nil; old_callback() end
		w.tap()
		helpers.assert_eq(w.sends, 0, "the older retry cannot borrow the newer destination")
	end)

	helpers.it("cannot reuse a replaced operation with the same destination and source", function()
		local callbacks, retries, owner, replace, warnings = {}, 0, nil, false, 0
		local source = function() return true end
		local destination = { current = function()
			if replace then
				replace = false
				owner:stop()
				owner:run("new", function() end, source)
			end
			return true
		end }
		owner = TapCopy.new({ verify_ms = 300, read_counter = function() return 5 end,
			capture_destination = function() return destination end,
			send_copy = function() retries = retries + 1; return true end,
			after = function(_, fn) callbacks[#callbacks + 1] = fn; return {} end,
			cancel = function() end, log = function() end, warn_user = function() warnings = warnings + 1 end })
		owner:run("old", function() end, source)
		replace = true
		callbacks[1]()
		helpers.assert_eq(retries, 0, "old operation cannot borrow the new one's identical proof")
		helpers.assert_eq(warnings, 0, "a superseded retry cannot warn for the new operation")
		callbacks[2]()
		helpers.assert_eq(retries, 1, "the new operation retains its own retry")
	end)

	helpers.it("does not warn for a retired sender that raises after replacement", function()
		local callbacks, warnings, owner, sends = {}, 0, nil, 0
		local source = function() return true end
		local destination = { current = function() return true end }
		owner = TapCopy.new({ verify_ms = 300, read_counter = function() return 5 end,
			capture_destination = function() return destination end,
			send_copy = function()
				sends = sends + 1
				if sends == 1 then owner:stop(); owner:run("new", function() end, source); error("retired") end
				return true
			end,
			after = function(_, fn) callbacks[#callbacks + 1] = fn; return {} end,
			cancel = function() end, log = function() end, warn_user = function() warnings = warnings + 1 end })
		owner:run("old", function() end, source)
		callbacks[1]()
		helpers.assert_eq(warnings, 0)
		callbacks[2]()
		helpers.assert_eq(sends, 2)
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

	for _, unsupported in ipairs({ false, true }) do
		helpers.it("propagates an explicit first-copy refusal: unsupported=" .. tostring(unsupported), function()
			local w = world(unsupported and { reason = "unsupported" } or nil)
			local calls = 0
			local accepted = w.owner:run("tap_hold", function() calls = calls + 1; return false end, function() return true end)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(calls, 1)
			w.advance(1000)
			helpers.assert_eq(w.sends, 0)
		end)
	end

	helpers.it("a newer unsupported copy cancels the previous retry", function()
		local options = {}
		local w = world(options)
		w.tap()
		options.reason = "unsupported"
		w.tap()
		w.advance(300)
		helpers.assert_eq(w.sends, 0)
		helpers.assert_eq(w.warnings, 0)
	end)

	helpers.it("a failed newer copy cancels the previous retry", function()
		local w = world()
		w.tap()
		local ok = pcall(function()
			w.owner:run("new copy", function() error("send failed") end)
		end)
		helpers.assert_eq(ok, false)
		w.advance(300)
		helpers.assert_eq(w.sends, 0)
		helpers.assert_eq(w.warnings, 0)
	end)
end)

helpers.describe("X11 clipboard change counter (tap-copy-verified)", function()
	--- Loads the clipboard adapter over a fake shell and display.
	local function with_adapter(display, reply, body)
		local names = { clipboard = "clipboard.adapters.clipboard", shell = "core.process.adapters.shell_runner", display = "core.ui.engine.display_server" }
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

	--- Runs body with a fresh Wayland counter module, restored afterwards.
	local function with_counter(body)
		local name = "clipboard.adapters.wayland_selection_counter"
		local previous = package.loaded[name]
		package.loaded[name] = nil
		local Counter = require(name)
		local ok, err = pcall(body, Counter)
		Counter.stop()
		package.loaded[name] = previous
		helpers.assert_true(ok, tostring(err))
	end

	--- A fake owned process whose output and exit the test drives.
	local function fake_process()
		local fake = { started = 0 }
		function fake.start(executable, args, options, callback)
			fake.started = fake.started + 1
			fake.executable, fake.args, fake.options, fake.callback = executable, args, options, callback
			fake.running = true
			return { started = true, is_running = function() return fake.running end,
				cancel = function() fake.cancelled = true fake.running = false end }
		end
		return fake
	end

	helpers.it("Wayland without a clipboard watch has no counter (tap-copy-verified)", function()
		with_counter(function()
			with_adapter("wayland", { ok = true, output = "1" }, function(Clipboard, shell)
				local counter, reason = Clipboard.change_counter()
				helpers.assert_eq(counter, nil)
				helpers.assert_eq(reason, "unsupported")
				helpers.assert_eq(#shell.commands, 0, "no command is run where none could answer")
			end)
		end)
	end)

	helpers.it("Wayland counts the selection changes wl-paste --watch reports (wayland-copy-counter)", function()
		with_counter(function(Counter)
			local fake = fake_process()
			helpers.assert_eq(Counter.start({ start_process = fake.start, has_command = function() return true end }), true)
			helpers.assert_eq(fake.executable, "wl-paste")
			helpers.assert_eq(fake.args[1], "--watch")
			helpers.assert_true(fake.args[#fake.args]:find("cat >/dev/null", 1, true) ~= nil,
				"the offered content is drained to /dev/null, never kept")
			with_adapter("wayland", { ok = true }, function(Clipboard, shell)
				fake.options.on_output("\n", "stdout")
				local before = Clipboard.change_counter()
				fake.options.on_output("\n", "stdout")
				fake.options.on_output("ignored\n", "stderr")
				helpers.assert_eq(Clipboard.change_counter(), before + 1, "a copy moves the counter by one")
				helpers.assert_eq(#shell.commands, 0)
				fake.running = false
				fake.callback()
				local counter, reason = Clipboard.change_counter()
				helpers.assert_eq(counter, nil, "a watcher the compositor refused gives no counter")
				helpers.assert_eq(reason, "unsupported")
			end)
			helpers.assert_true(not pcall(Counter.start, { start_process = fake.start, has_command = function() return true end }),
				"a second start is refused")
			Counter.stop()
			helpers.assert_eq(fake.cancelled, true, "stop ends the watcher")
		end)
	end)

	helpers.it("Wayland without wl-paste starts no watcher (wayland-copy-counter)", function()
		with_counter(function(Counter)
			local fake = fake_process()
			helpers.assert_eq(Counter.start({ start_process = fake.start, has_command = function() return false end }), false)
			helpers.assert_eq(fake.started, 0)
			helpers.assert_eq(select(2, Counter.read()), "unsupported")
		end)
	end)

	helpers.it("X11 without xclip reads the owner's TIMESTAMP through libX11 (x11-native-copy-counter)", function()
		local name = "clipboard.adapters.x11_selection_stamp"
		local previous = package.loaded[name]
		local asked = nil
		package.loaded[name] = { read = function(timeout_s) asked = timeout_s return 4242 end }
		local ok, err = pcall(with_adapter, "x11", { ok = true, output = "1" }, function(Clipboard, shell)
			shell.has_command = function(binary) return binary ~= "xclip" end
			helpers.assert_eq(Clipboard.change_counter(), 4242)
			helpers.assert_eq(#shell.commands, 0, "no xclip command without xclip")
			helpers.assert_true(type(asked) == "number" and asked > 0, "the read is bounded")
		end)
		package.loaded[name] = previous
		helpers.assert_true(ok, tostring(err))
	end)
end)
