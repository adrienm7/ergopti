--- tests/unit/platform/input/synthetic_input/test_clipboard_transient_hint.lua

--- ==============================================================================
--- MODULE: Transient Clipboard Hint
--- DESCRIPTION:
--- Klipper, CopyQ and GPaste leave out of their history an item offered with
--- x-kde-passwordManagerHint = secret. wl-copy, xclip and xsel offer one type
--- per write, so the daemon's paste payloads go through the multi-format owner
--- once the boot has armed the hint; unarmed, or with no owner on the session,
--- the session writer is used as before. Controlled shell and owner, no GUI.
--- ==============================================================================

local helpers = require("tests.helpers")
local ClipboardTargets = require("tests.support.adapters.synthetic_input.clipboard_targets")

local function with_paste(body, options)
	options = options or {}
	local names = { "clipboard.adapters.clipboard", "clipboard.adapters.owner", "core.process.adapters.shell_runner",
		"core.ui.engine.display_server", "core.logger.engine.shim" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local s = { value = "original", writer = {}, owner = {}, probes = 0, infos = {} }
	local shell = {}
	function shell.has_command() return true end
	function shell.exec_checked(command)
		if ClipboardTargets.is_listing(command) then return true, ClipboardTargets.TEXT_ONLY end
		return true, s.value
	end
	function shell.with_exact_stdin(_, value)
		s.pending = value
		return "writer-command"
	end
	function shell.run(command)
		assert(command == "writer-command", "only the session writer runs through the shell here")
		s.value = s.pending
		s.writer[#s.writer + 1] = s.pending
		return true
	end
	package.loaded["core.process.adapters.shell_runner"] = shell
	package.loaded["clipboard.adapters.owner"] = {
		available = function() s.probes = s.probes + 1; return options.owner ~= false end,
		write = function(targets)
			s.owner[#s.owner + 1] = targets
			s.value = targets[1].data
			return true
		end,
	}
	package.loaded["core.ui.engine.display_server"] = { is_wayland = function() return false end,
		is_x11 = function() return true end, kind = function() return "x11" end }
	local logger = helpers.make_logger_stub()
	logger.info = function(_, fmt) s.infos[#s.infos + 1] = fmt end
	package.loaded["core.logger.engine.shim"] = logger
	local ok, detail = xpcall(function()
		s.clipboard = helpers.load_module("clipboard.adapters.clipboard")
		s.channel = { emit = function() return true end }
		s.paste = function(text)
			return s.clipboard.paste_text(text, s.channel, function() end, nil)
		end
		body(s)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(detail, 0) end
end

helpers.describe("Linux clipboard: transient hint on pasted payloads", function()
	helpers.it("offers an armed paste payload with its text targets and the hint", function()
		with_paste(function(s)
			s.clipboard.arm_transient_hint()
			helpers.assert_true(s.paste("expansion ✓"))
			helpers.assert_eq(#s.owner, 1, "the payload goes through the multi-format owner")
			local names, hint = {}, nil
			for _, target in ipairs(s.owner[1]) do
				names[#names + 1] = target.name
				if target.name == "x-kde-passwordManagerHint" then hint = target.data
				else helpers.assert_eq(target.data, "expansion ✓") end
			end
			helpers.assert_eq(names, { "text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT",
				"x-kde-passwordManagerHint" })
			helpers.assert_eq(hint, "secret")
			helpers.assert_eq(s.writer, { "original" }, "the user's text is restored through the session writer")
			helpers.assert_eq(s.value, "original")
		end)
	end)

	helpers.it("probes the owner once per process", function()
		with_paste(function(s)
			s.clipboard.arm_transient_hint()
			helpers.assert_true(s.paste("one"))
			helpers.assert_true(s.paste("two"))
			helpers.assert_eq(s.probes, 1)
			helpers.assert_eq(#s.owner, 2)
		end)
	end)

	helpers.it("keeps the session writer, and says so once, where no owner runs", function()
		with_paste(function(s)
			s.clipboard.arm_transient_hint()
			helpers.assert_true(s.paste("one"))
			helpers.assert_true(s.paste("two"))
			helpers.assert_eq(#s.owner, 0)
			helpers.assert_eq(s.writer, { "one", "original", "two", "original" })
			helpers.assert_eq(#s.infos, 1)
		end, { owner = false })
	end)

	helpers.it("leaves an unarmed process on the session writer without probing", function()
		with_paste(function(s)
			helpers.assert_true(s.paste("payload"))
			helpers.assert_eq(s.probes, 0)
			helpers.assert_eq(#s.owner, 0)
			helpers.assert_eq(s.writer, { "payload", "original" })
		end)
	end)

	helpers.it("refuses a second arming", function()
		with_paste(function(s)
			s.clipboard.arm_transient_hint()
			helpers.assert_eq((pcall(s.clipboard.arm_transient_hint)), false)
		end)
	end)

	helpers.it("never marks the generic write, which the user keeps", function()
		with_paste(function(s)
			s.clipboard.arm_transient_hint()
			helpers.assert_true(s.clipboard.write("copied for the user"))
			helpers.assert_eq(#s.owner, 0)
			helpers.assert_eq(s.writer, { "copied for the user" })
		end)
	end)
end)
