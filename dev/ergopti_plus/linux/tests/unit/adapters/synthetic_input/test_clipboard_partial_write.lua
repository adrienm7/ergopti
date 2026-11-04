--- tests/unit/adapters/synthetic_input/test_clipboard_partial_write.lua

--- ==============================================================================
--- MODULE: Clipboard Partial Setter Restoration
--- DESCRIPTION:
--- A clipboard owner can publish before its launcher reports failure. Preserve
--- the saved text on rejected paste and file-selection preparation, without
--- emitting a chord or claiming a refused restoration succeeded.
--- ==============================================================================

local helpers = require("tests.helpers")
-- Resolve transitive constructors before publishing controlled desktop ports.
require("adapters.clipboard")

local function with_session(options, body)
	local names = { "adapters.clipboard", "adapters.shell_runner", "infra.display_server",
		"adapters.keyboard_layout", "logger.shim" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local state = { current = "saved", writes = {}, wire = {}, waits = {} }
	local pending
	package.loaded["adapters.shell_runner"] = {
		has_command = function() return true end,
		exec_checked = function() return true, state.current end,
		with_exact_stdin = function(_, text) pending = text; return "controlled clipboard setter" end,
		run = function()
			local text = pending
			state.writes[#state.writes + 1] = text
			if #state.writes == 1 and options.fault then
				if not options.before_mutation then state.current = text end
				if options.fault == "throw" then error("setter exited after ownership transfer", 0) end
				return false
			end
			if #state.writes == 2 and options.restore_fault then
				if options.restore_fault == "throw" then error("restore setter refused", 0) end
				return false
			end
			state.current = text
			return true
		end,
	}
	package.loaded["infra.display_server"] = {
		is_wayland = function() return false end, is_x11 = function() return true end,
		kind = function() return "x11" end,
	}
	package.loaded["adapters.keyboard_layout"] = { shortcut_keycode = function() return 47 end }
	package.loaded["logger.shim"] = helpers.make_logger_stub()
	package.loaded["adapters.clipboard"] = nil
	local ok, detail = xpcall(function()
		local clipboard = require("adapters.clipboard")
		function state.call(kind)
			local function wait(ms) state.waits[#state.waits + 1] = ms end
			if kind == "paste" then
				return clipboard.paste_text("replacement", {
					emit = function(code, value) state.wire[#state.wire + 1] = { code, value }; return true end,
				}, wait)
			end
			local accepted, _, reason = clipboard.read_selection_uri_list(function(chord)
				state.wire[#state.wire + 1] = chord
				state.current = "file:///owned/selection"
				return true
			end, wait)
			return accepted, reason
		end
		body(state)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(detail, 0) end
end

helpers.describe("clipboard partial setter restoration", function()
	for _, kind in ipairs({ "paste", "uri-list" }) do
		for _, fault in ipairs({ "false", "throw" }) do
			helpers.it("restores " .. kind .. " after a setter " .. fault .. " beyond mutation", function()
				with_session({ fault = fault }, function(state)
					local accepted, reason = state.call(kind)
					helpers.assert_eq(accepted, false)
					if kind == "paste" then helpers.assert_nil(reason)
					else helpers.assert_eq(reason, "clipboard_probe_write_failed") end
					helpers.assert_eq(state.current, "saved")
					helpers.assert_eq(#state.writes, 2)
					helpers.assert_eq(state.writes[2], "saved")
					helpers.assert_eq(#state.wire, 0)
					helpers.assert_eq(#state.waits, 0)
				end)
			end)
		end
		for _, fault in ipairs({ "false", "throw" }) do
			helpers.it("reports refused " .. kind .. " restoration after a partial setter: " .. fault, function()
				with_session({ fault = "false", restore_fault = fault }, function(state)
					local accepted, reason = state.call(kind)
					helpers.assert_eq(accepted, false)
					helpers.assert_eq(reason, kind == "paste" and "clipboard restoration failed" or "clipboard_restore_failed")
					helpers.assert_eq(#state.writes, 2)
					helpers.assert_eq(state.writes[2], "saved")
					helpers.assert_true(state.current ~= "saved")
					helpers.assert_eq(#state.wire, 0)
					helpers.assert_eq(#state.waits, 0)
				end)
			end)
		end
		helpers.it("preserves " .. kind .. " when its initial setter failed before mutation", function()
			with_session({ fault = "false", before_mutation = true }, function(state)
				helpers.assert_eq(state.call(kind), false)
				helpers.assert_eq(state.current, "saved")
				helpers.assert_eq(#state.writes, 2)
				helpers.assert_eq(#state.wire, 0)
			end)
		end)
		helpers.it("retains healthy " .. kind .. " delivery and original clipboard", function()
			with_session({}, function(state)
				helpers.assert_eq(state.call(kind), true)
				helpers.assert_eq(state.current, "saved")
				helpers.assert_eq(#state.writes, 2)
				helpers.assert_eq(#state.wire, kind == "paste" and 4 or 1)
				helpers.assert_eq(#state.waits, kind == "paste" and 2 or 1)
			end)
		end)
	end
end)
