--- tests/unit/meta/test_keyboard_hook_modal_release.lua

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
		}
		package.loaded["adapters.xkb_capture"] = {
			is_ready = function() return true end, reset_state = function() return true end,
			process = function() end, modifier_role = function() end,
		}
		Reader._set_backend({
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
