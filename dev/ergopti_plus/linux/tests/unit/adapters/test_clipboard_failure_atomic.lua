--- tests/unit/adapters/test_clipboard_failure_atomic.lua

--- ============================================================================
--- MODULE: Clipboard Snapshot Failure Atomicity
--- DESCRIPTION:
--- Proves that an unreadable clipboard is not mistaken for an empty clipboard.
--- The paste fallback must obtain a valid snapshot before it writes replacement
--- text or emits Ctrl+V, otherwise it can erase irreplaceable copied content.
--- ============================================================================

local helpers = require("tests.helpers")

local function with_clipboard(read_ok, read_value, body)
	local names = {
		clipboard = "adapters.clipboard",
		shell = "adapters.shell_runner",
		display = "infra.display_server",
	}
	local previous = {}
	for key, name in pairs(names) do previous[key] = package.loaded[name] end

	local shell = { writes = {} }
	function shell.has_command() return true end
	function shell.exec() return read_ok and read_value or "" end
	function shell.exec_checked()
		return read_ok, read_ok and read_value or "", read_ok and nil or "clipboard read failed"
	end
	function shell.with_exact_stdin(command, text)
		shell.writes[#shell.writes + 1] = { command = command, text = text }
		return command
	end
	function shell.run() return true end

	package.loaded[names.shell] = shell
	package.loaded[names.display] = {
		UNKNOWN = "unknown",
		is_wayland = function() return false end,
		is_x11 = function() return true end,
		kind = function() return "x11" end,
	}
	package.loaded[names.clipboard] = nil

	local ok, err = pcall(function()
		body(require(names.clipboard), shell)
	end)

	for key, name in pairs(names) do package.loaded[name] = previous[key] end
	helpers.assert_true(ok, "clipboard transaction probe must not throw: " .. tostring(err))
end

local function channel()
	local fake = { emitted = {} }
	function fake.emit(code, value)
		fake.emitted[#fake.emitted + 1] = { code = code, value = value }
		return true
	end
	return fake
end

helpers.describe("clipboard paste snapshot", function()
	helpers.it("aborts before mutation when snapshot read fails (lnx-062)", function()
		with_clipboard(false, nil, function(clipboard, shell)
			local uinput = channel()
			local sleeps = 0
			local result = clipboard.paste_text("replacement", uinput, function() sleeps = sleeps + 1 end)

			helpers.assert_eq(result, false, "an unavailable snapshot must abort the paste")
			helpers.assert_eq(#shell.writes, 0, "failure must write neither replacement nor restoration")
			helpers.assert_eq(#uinput.emitted, 0, "failure must not emit the paste chord")
			helpers.assert_eq(sleeps, 0, "failure must return before any settle delay")
		end)
	end)

	helpers.it("preserves a genuinely empty clipboard (lnx-062)", function()
		with_clipboard(true, "", function(clipboard, shell)
			local uinput = channel()
			local result = clipboard.paste_text("replacement", uinput, function() end)

			helpers.assert_eq(result, true, "a successful empty snapshot is valid")
			helpers.assert_eq(#shell.writes, 2, "the replacement and empty restoration must both be written")
			helpers.assert_eq(shell.writes[2].text, "", "restore must preserve the original empty state")
			helpers.assert_eq(#uinput.emitted, 4, "one complete Ctrl+V chord must be emitted")
		end)
	end)

	helpers.it("restores the clipboard and balances the chord when any emit fails (lnx-004)", function()
		for fail_at = 1, 4 do
			with_clipboard(true, "saved", function(clipboard, shell)
				local calls = 0
				local held = {}
				local raw = {
					is_open = function() return true end,
					emit = function(code, value)
						calls = calls + 1
						if calls == fail_at then return false end
						held[code] = value == 1 or nil
						return true
					end,
				}
				local Transaction = helpers.load_module("modules.hotstrings.output_transaction")
				local tx = Transaction.new(raw)
				local pasted = clipboard.paste_text("replacement", tx.channel(), function() end)
				if not pasted then tx.fail("paste chord failed", "clipboard") end
				local result = tx.finish()

				helpers.assert_true(not pasted,
					"failed chord event " .. fail_at .. " must reject delivery")
				helpers.assert_true(not result.ok,
					"failed chord event " .. fail_at .. " must reject transaction commit")
				helpers.assert_eq(held, {},
					"failed chord event " .. fail_at .. " must leave no synthetic key down")
				helpers.assert_eq(#shell.writes, 2,
					"replacement write and original clipboard restoration must both occur")
				helpers.assert_eq(shell.writes[2].text, "saved",
					"the original clipboard must survive chord event " .. fail_at)
			end)
		end
	end)

	helpers.it("treats an emitter exception like a failed chord and still restores", function()
		with_clipboard(true, "saved", function(clipboard, shell)
			local Transaction = helpers.load_module("modules.hotstrings.output_transaction")
			local tx = Transaction.new({
				is_open = function() return true end,
				emit = function() error("wire exploded") end,
			})
			local pasted = clipboard.paste_text("replacement", tx.channel(), function() end)
			local result = tx.finish()

			helpers.assert_true(not pasted, "an emitter exception must reject delivery")
			helpers.assert_true(not result.ok, "an emitter exception must reject commit")
			helpers.assert_eq(shell.writes[2].text, "saved",
				"the exception path must restore the original clipboard")
		end)
	end)

	helpers.it("restores after a timing exception once replacement text was staged", function()
		with_clipboard(true, "saved", function(clipboard, shell)
			local pasted = clipboard.paste_text("replacement", channel(), function()
				error("timer failed")
			end)

			helpers.assert_true(not pasted, "a timing exception must reject delivery")
			helpers.assert_eq(#shell.writes, 2,
				"the original clipboard must be restored after a post-write exception")
			helpers.assert_eq(shell.writes[2].text, "saved",
				"the timing exception path must restore the saved clipboard")
		end)
	end)
end)
