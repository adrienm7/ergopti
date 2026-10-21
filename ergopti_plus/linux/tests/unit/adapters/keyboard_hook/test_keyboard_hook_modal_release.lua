--- tests/unit/adapters/keyboard_hook/test_keyboard_hook_modal_release.lua

--- ==============================================================================
--- MODULE: A Dialog Gets The Keyboard
--- DESCRIPTION:
--- Tray dialogs (zenity) run inside a menu callback and block the event loop,
--- which is the only path from the grabbed keyboard to the desktop. Nothing
--- could be typed into them: not an API key, not a delay. The hook now hands
--- the keyboard back for the dialog's lifetime and takes it again afterwards,
--- releasing the virtual keys it held and forgetting what was typed meanwhile.
--- ==============================================================================

local helpers = require("tests.helpers")

local EV_KEY = 1
local KEY_A = 30

helpers.describe("keyboard_hook.while_released: a dialog runs with the keyboard released", function()

	helpers.it("releases held keys, ungrabs, runs the dialog, then grabs back", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local Reader = require("adapters.evdev_reader")
		local trail = {}
		local originals = { grab = Reader.grab, ungrab = Reader.ungrab }
		Reader.ungrab = function(slot) trail[#trail + 1] = "ungrab"; return originals.ungrab(slot) end
		Reader.grab = function(slot) trail[#trail + 1] = "grab"; return originals.grab(slot) end
		local returned, desynced = nil, false
		kh._test_drive({ { type = EV_KEY, code = KEY_A, value = 1 } }, {
			onChar = function()
				returned = kh.while_released(function()
					trail[#trail + 1] = "dialog"
					return "typed value"
				end)
			end,
			onDesync = function() desynced = true end,
			onEmitRaw = function(code, value)
				trail[#trail + 1] = string.format("emit %d:%d", code, value)
				return true
			end,
		}, true)
		Reader.grab, Reader.ungrab = originals.grab, originals.ungrab

		local text = table.concat(trail, ", ")
		local function at(entry)
			for index, value in ipairs(trail) do if value == entry then return index end end
			return nil
		end
		helpers.assert_eq(returned, "typed value", "the dialog's answer reaches the caller")
		helpers.assert_true(at("emit 30:0") and at("emit 30:0") < at("ungrab"),
			"the A the daemon forwarded is released before the desktop takes the keyboard: " .. text)
		helpers.assert_true(at("ungrab") < at("dialog") and at("dialog") < at("grab"),
			"the dialog runs between the release and the new grab: " .. text)
		helpers.assert_true(desynced, "text typed before the dialog no longer describes the caret")
	end)

	helpers.it("runs the dialog directly when nothing is grabbed", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		helpers.assert_eq(kh.while_released(function() return 42 end), 42)
	end)

	helpers.it("takes the keyboard back even when the dialog raises", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local Reader = require("adapters.evdev_reader")
		local grabbed = 0
		local original = Reader.grab
		Reader.grab = function(slot) grabbed = grabbed + 1; return original(slot) end
		local raised
		kh._test_drive({ { type = EV_KEY, code = KEY_A, value = 1 } }, {
			onChar = function()
				local before = grabbed
				local ok, err = pcall(kh.while_released, function() error("dialog failed", 0) end)
				raised = not ok and err == "dialog failed" and grabbed == before + 1
			end,
			onEmitRaw = function() return true end,
		}, true)
		Reader.grab = original
		helpers.assert_true(raised, "the error propagates after the keyboard is grabbed again")
	end)

end)

helpers.describe("keyboard_hook.while_released: native refusal never blocks a grabbed keyboard", function()
	local function run_refusal(port, replacement, dialog_error)
		local Hook = helpers.load_module("adapters.keyboard_hook")
		local Reader = require("adapters.evdev_reader")
		local original = port and Reader[port]
		local observed = { dialog = false, stages = {} }
		Hook._test_drive({ { type = EV_KEY, code = KEY_A, value = 1 } }, {
			onChar = function()
				local slot = "keyboard:/dev/input/test"
				assert(Reader.grab(slot))
				if port then Reader[port] = function(...) return replacement(original, ...) end end
				observed.called, observed.result, observed.error = pcall(Hook.while_released, function()
					observed.dialog = true
					if dialog_error then error("modal failure", 0) end
					return "modal result"
				end, { observer = function(stage) observed.stages[#observed.stages + 1] = stage end })
				observed.open = Reader.is_open(slot)
				observed.grabbed = Reader.is_grabbed(slot)
				observed.running = Hook.isRunning()
				if port then Reader[port] = original end
			end,
			onEmitRaw = function(_, value) return not (port == nil and value == 0) end,
		}, true)
		if port then Reader[port] = original end
		return observed
	end

	for _, mode in ipairs({ "refuses", "throws" }) do
		helpers.it("does not enter a modal when native ungrab " .. mode, function()
			local result = run_refusal("ungrab", function()
				if mode == "throws" then error("controlled ungrab failure", 0) end
				return false
			end)
			helpers.assert_eq(result.dialog, false)
			helpers.assert_eq(result.open, false, "emergency close settles the remaining grab")
			helpers.assert_eq(result.running, false)
			helpers.assert_eq(table.concat(result.stages), "refused")
		end)
	end

	helpers.it("does not enter a modal when retiring the forwarded key fails", function()
		local result = run_refusal()
		helpers.assert_eq(result.dialog, false)
		helpers.assert_eq(result.open, false)
		helpers.assert_eq(result.running, false)
	end)

	for _, port in ipairs({ "grab", "pressed_keys" }) do
		helpers.it("closes every modal grab when restoration " .. port .. " raises", function()
			local result = run_refusal(port, function(original, ...)
				if port == "grab" then assert(original(...)) end
				error("controlled restoration failure", 0)
			end)
			helpers.assert_true(result.dialog)
			helpers.assert_eq(result.open, false, "an acquired grab cannot escape the restoration failure")
			helpers.assert_eq(result.running, false)
			helpers.assert_eq(table.concat(result.stages), "refused")
		end)
	end

	helpers.it("preserves a dialog exception after a refused regrab", function()
		local result = run_refusal("grab", function() return false end, true)
		helpers.assert_eq(result.called, false)
		helpers.assert_eq(result.result, "modal failure")
		helpers.assert_eq(result.open, false)
	end)

	helpers.it("closes the entire cohort when its second keyboard raises after regrab", function()
		local Reader = helpers.load_module("adapters.evdev_reader")
		local paths = { os.tmpname(), os.tmpname() }
		for _, path in ipairs(paths) do local file = assert(io.open(path, "w")); file:close() end
		local saved_finder = package.loaded["modules.hotstrings.device_finder"]
		local saved_xkb = package.loaded["adapters.xkb_capture"]
		package.loaded["modules.hotstrings.device_finder"] = {
			find_devices = function() return paths, {} end,
			is_key_device = function() return true end,
			-- Controlled keyboard sources have no REL/ABS axes.
			is_interceptable_key_device = function() return true end,
			is_interceptable_event_mask = require("tests.support.evdev_capabilities_fixture").policy,
		}
		package.loaded["adapters.xkb_capture"] = {
			is_ready = function() return true end, reset_state = function() return true end,
			process = function() end, modifier_role = function() end,
		}
		Reader._set_backend({
			read_event_bits = require("tests.support.evdev_capabilities_fixture").key_bits,
			open = function(path) return path end, close = function() return true end,
			ioctl = function() return true end, read = function() end, poll = function() return false end,
			read_bits = function(_, _, count) return string.rep("\0", count) end,
		})
		local Hook = helpers.load_module("adapters.keyboard_hook")
		local original_grab = Reader.grab
		local ok, failure = pcall(function()
			Hook.start({ intercept = true, onEmitRaw = function() return true end })
			assert(Hook.isRunning())
			Reader.grab = function(slot)
				local acknowledged = original_grab(slot)
				if slot == "keyboard:" .. paths[2] then error("controlled second-source failure", 0) end
				return acknowledged
			end
			local result = Hook.while_released(function() return "completed" end)
			helpers.assert_eq(result, "completed")
			for _, path in ipairs(paths) do
				helpers.assert_eq(Reader.is_open("keyboard:" .. path), false,
					"restoring an earlier source cannot leave its keyboard grabbed")
			end
			helpers.assert_eq(Hook.isRunning(), false)
		end)
		Reader.grab = original_grab
		pcall(Hook.stop); Reader._reset_backend()
		package.loaded["modules.hotstrings.device_finder"] = saved_finder
		package.loaded["adapters.xkb_capture"] = saved_xkb
		for _, path in ipairs(paths) do os.remove(path) end
		if not ok then error(failure, 0) end
	end)
end)


helpers.describe("keyboard_hook.while_released: acknowledged modal observer", function()
	helpers.it("brackets only the real callback after native restoration and preserves results", function()
		local Hook = helpers.load_module("adapters.keyboard_hook")
		local trail, returned, receipt = {}, nil, nil
		Hook._test_drive({ { type = EV_KEY, code = KEY_A, value = 1 } }, {
			onChar = function()
				returned = Hook.while_released(function() return "yes" end, {
					observer = function(stage, result)
						trail[#trail + 1] = stage
						if stage == "after" then receipt = result end
					end,
				})
			end,
			onDesync = function() trail[#trail + 1] = "daemon reset" end,
			onEmitRaw = function() return true end,
		}, true)
		helpers.assert_eq(returned, "yes")
		helpers.assert_eq(table.concat(trail, "|"), "before|daemon reset|after",
			"an observer cannot swallow the existing daemon reset")
		helpers.assert_true(receipt and receipt.ok == true)
	end)
end)

helpers.describe("keyboard_hook.while_released: running observe dialogs", function()
	-- Drive start/pump and the shipped Reader with encoded queues. Only the
	-- kernel/XKB ports are controlled; no intercepted native rights are issued.
	local function with_observe(options, check)
		local InputEvent = require("infra.input_event")
		local Reader
		local names = { "modules.hotstrings.device_finder", "adapters.xkb_capture",
			"adapters.window_info", "adapters.keyboard_hook", "adapters.evdev_reader" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local ctx = { paths = {}, queues = {}, held = {}, chars = {}, stages = {},
			grabs = 0, ungrabs = 0, emitted = 0, desynced = 0, timestamp = 0 }
		for _ = 1, options.sources or 1 do
			local path = os.tmpname()
			local file = assert(io.open(path, "w")); file:close()
			ctx.paths[#ctx.paths + 1] = path
			ctx.queues[path] = {}
		end
		function ctx.push(source, code, value)
			local queue = ctx.queues[ctx.paths[source]]
			ctx.timestamp = ctx.timestamp + 1000
			queue[#queue + 1] = InputEvent.encode(EV_KEY, code, value, InputEvent.native_size(), ctx.timestamp)
		end
		package.loaded[names[1]] = {
			find_devices = function() return ctx.paths, {} end,
			is_key_device = function() return true end,
		}
		package.loaded[names[2]] = {
			is_ready = function() return true end, reset_state = function() return true end,
			modifier_role = function() end, cancel_compose = function() return true end,
			process = function(code, value)
				local char = value ~= 0 and ({ [30] = "a", [48] = "b", [46] = "c" })[code] or nil
				return char, char
			end,
		}
		package.loaded[names[3]] = { getFocused = function() return { appId = "audit-editor" } end }
		-- Cold-load Hook before installing controlled kernel ports. Its original
		-- Reader identity is retained, so observe must explicitly avoid the native
		-- interception transaction even when the production loader is trusted.
		package.loaded["adapters.evdev_reader"] = nil
		local Hook = helpers.load_module("adapters.keyboard_hook")
		Reader = require("adapters.evdev_reader")
		Reader._set_backend({
			read_event_bits = require("tests.support.evdev_capabilities_fixture").key_bits,
			open = function(path) return path end, close = function() return true end,
			ioctl = function() return true end,
			read = function(path) return table.remove(ctx.queues[path], 1) end,
			poll = function(path) return #ctx.queues[path] > 0 end,
			read_bits = function(path, request, count)
				if request % 0x100 == Reader.EVIOCGLED_NR or not ctx.held[path] then
					return string.rep("\0", count)
				end
				local code = ctx.held[path]
				local index = math.floor(code / 8)
				return string.rep("\0", index) .. string.char(2 ^ (code % 8))
					.. string.rep("\0", count - index - 1)
			end,
		})
		ctx.hook, ctx.reader = Hook, Reader
		local original_grab, original_ungrab = Reader.grab, Reader.ungrab
		Reader.grab = function(...) ctx.grabs = ctx.grabs + 1; return original_grab(...) end
		Reader.ungrab = function(...) ctx.ungrabs = ctx.ungrabs + 1; return original_ungrab(...) end
		ctx.observer = function(stage, receipt)
			ctx.stages[#ctx.stages + 1] = stage
			ctx.receipt = receipt
		end
		local ok, failure = pcall(function()
			assert(Hook.start({ intercept = false,
				onChar = function(char)
					ctx.chars[#ctx.chars + 1] = char
					if options.onChar then options.onChar(ctx, char) end
				end,
				onDesync = function()
					ctx.desynced = ctx.desynced + 1
					if options.onDesync then options.onDesync(ctx) end
				end,
				onEmitRaw = function() ctx.emitted = ctx.emitted + 1; return true end,
			}) == true, "controlled observe source must start")
			check(ctx, require("ui.modal"))
		end)
		pcall(Hook.stop)
		Reader.grab, Reader.ungrab = original_grab, original_ungrab
		Reader._reset_backend()
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		for _, path in ipairs(ctx.paths) do os.remove(path) end
		if not ok then error(failure, 0) end
	end

	helpers.it("discards dialog input and resumes observe without any grab or synthetic output", function()
		with_observe({}, function(ctx, Modal)
			local first, middle, last = Modal.run(function()
				ctx.push(1, 48, 1); ctx.push(1, 48, 0)
				return "answer", nil, 17
			end, { observer = ctx.observer })
			ctx.hook.pump()
			helpers.assert_eq(ctx.chars, {}, "dialog text never reaches global consumers")
			helpers.assert_eq({ first, middle, last }, { "answer", nil, 17 })
			helpers.assert_eq(ctx.desynced, 1)
			helpers.assert_eq(ctx.stages, { "before", "after" })
			helpers.assert_eq(ctx.receipt.ok, true)
			helpers.assert_eq({ ctx.grabs, ctx.ungrabs, ctx.emitted }, { 0, 0, 0 })
			helpers.assert_eq(ctx.hook.get_mode(), "observe")
			ctx.push(1, 46, 1); ctx.hook.pump()
			helpers.assert_eq(ctx.chars, { "c" }, "fresh input resumes after restoration")
		end)
	end)

	helpers.it("also discards the other keyboard's already prefetched modal input", function()
		local invoked = false
		with_observe({ sources = 2, onChar = function(ctx)
			if invoked then return end
			invoked = true
			ctx.hook.while_released(function() ctx.push(2, 46, 1) end)
		end }, function(ctx)
			ctx.push(1, 30, 1); ctx.push(2, 48, 1)
			ctx.hook.pump()
			helpers.assert_eq(invoked, true)
			helpers.assert_eq(ctx.chars, { "a" }, "both prefetched and queued peer input are discarded")
			helpers.assert_eq(ctx.desynced, 1)
			helpers.assert_eq({ ctx.grabs, ctx.ungrabs }, { 0, 0 })
		end)
	end)

	helpers.it("consumes a dialog key still held until release instead of replaying its repeats", function()
		with_observe({}, function(ctx, Modal)
			Modal.run(function()
				ctx.push(1, 48, 1)
				ctx.held[ctx.paths[1]] = 48
			end)
			ctx.push(1, 48, 2); ctx.push(1, 48, 0); ctx.push(1, 46, 1)
			ctx.held[ctx.paths[1]] = nil
			ctx.hook.pump()
			helpers.assert_eq(ctx.chars, { "c" }, "the closing key belongs to the dialog through its UP")
			helpers.assert_eq(ctx.desynced, 1)
			helpers.assert_eq(ctx.emitted, 0)
		end)
	end)

	helpers.it("restores and invalidates observe state before propagating a dialog exception", function()
		with_observe({}, function(ctx, Modal)
			local ok, reason = pcall(Modal.run, function()
				ctx.push(1, 48, 1)
				error("observe dialog failed", 0)
			end, { observer = ctx.observer })
			ctx.hook.pump()
			helpers.assert_eq(ok, false)
			helpers.assert_eq(reason, "observe dialog failed")
			helpers.assert_eq(ctx.chars, {})
			helpers.assert_eq(ctx.desynced, 1)
			helpers.assert_eq(ctx.stages, { "before", "after" })
			helpers.assert_eq(ctx.receipt.ok, false)
			helpers.assert_eq(ctx.hook.isRunning(), true)
		end)
	end)

	for _, mode in ipairs({ "refuses", "throws" }) do
		helpers.it("closes observe sources when native state restoration " .. mode, function()
			with_observe({}, function(ctx, Modal)
				local original = ctx.reader.pressed_keys
				local ok, result = pcall(Modal.run, function()
					ctx.reader.pressed_keys = function()
						if mode == "throws" then error("controlled query failure", 0) end
						return nil, "controlled query refusal"
					end
					return "entered"
				end, { observer = ctx.observer })
				ctx.reader.pressed_keys = original
				helpers.assert_eq(ok, true)
				helpers.assert_eq(result, "entered")
				helpers.assert_eq(ctx.hook.isRunning(), false)
				helpers.assert_eq(ctx.reader.is_open("keyboard:" .. ctx.paths[1]), false)
				helpers.assert_eq(ctx.stages, { "refused" })
				helpers.assert_eq(ctx.receipt.ok, false)
				helpers.assert_eq(ctx.desynced, 0)
				helpers.assert_eq({ ctx.grabs, ctx.ungrabs }, { 0, 0 })
			end)
		end)
	end


	helpers.it("preserves the dialog exception when observe restoration also fails", function()
		with_observe({}, function(ctx, Modal)
			local original = ctx.reader.pressed_keys
			local ok, reason = pcall(Modal.run, function()
				ctx.reader.pressed_keys = function() return nil, "query refused" end
				error("original dialog error", 0)
			end, { observer = ctx.observer })
			ctx.reader.pressed_keys = original
			helpers.assert_eq(ok, false)
			helpers.assert_eq(reason, "original dialog error")
			helpers.assert_eq(ctx.hook.isRunning(), false)
			helpers.assert_eq(ctx.reader.is_open("keyboard:" .. ctx.paths[1]), false)
			helpers.assert_eq(ctx.stages, { "refused" })
			helpers.assert_eq(ctx.receipt.ok, false)
		end)
	end)

	helpers.it("does not acknowledge a successful observe resume when the desync consumer fails", function()
		with_observe({ onDesync = function() error("consumer refused", 0) end }, function(ctx, Modal)
			Modal.run(function() return "entered" end, { observer = ctx.observer })
			helpers.assert_eq(ctx.hook.isRunning(), false)
			helpers.assert_eq(ctx.reader.is_open("keyboard:" .. ctx.paths[1]), false)
			helpers.assert_eq(ctx.stages, { "before", "after" })
			helpers.assert_eq(ctx.receipt.ok, false)
			helpers.assert_eq(ctx.desynced, 1)
			helpers.assert_eq({ ctx.grabs, ctx.ungrabs }, { 0, 0 })
		end)
	end)

	helpers.it("keeps a stopped hook direct without native work or observer acknowledgements", function()
		local Hook = helpers.load_module("adapters.keyboard_hook")
		local observed = false
		local first, middle, last = Hook.while_released(function() return "direct", nil, 9 end,
			{ observer = function() observed = true end })
		helpers.assert_eq({ first, middle, last }, { "direct", nil, 9 })
		helpers.assert_eq(observed, false)
		local ok, reason = pcall(Hook.while_released, function() error("stopped dialog failed", 0) end)
		helpers.assert_eq(ok, false)
		helpers.assert_eq(reason, "stopped dialog failed")
	end)
end)
