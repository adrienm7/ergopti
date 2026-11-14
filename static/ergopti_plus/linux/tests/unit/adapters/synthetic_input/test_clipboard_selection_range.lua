--- tests/unit/adapters/synthetic_input/test_clipboard_selection_range.lua

--- ==============================================================================
--- MODULE: Clipboard Selection Range Recheck
--- DESCRIPTION:
--- A case or wrap transform copies one selection and pastes its replacement
--- later. When the application moves its selection in between, inside the same
--- field, the paste must not replace the new range (LCP-003). PRIMARY follows
--- the live selection, so the adapter rechecks it right before the paste
--- whenever it published the copied range.
--- ==============================================================================

local helpers = require("tests.helpers")
local ClipboardTargets = require("tests.support.adapters.synthetic_input.clipboard_targets")

--- Runs one transform against a session whose CLIPBOARD and PRIMARY differ.
--- @param kind string "x11" or "wayland"
--- @param options table primary (initial PRIMARY, false when unreadable),
---   on_settle (called at each wait with the session).
--- @param body function body(clipboard, session, emit, sleep_ms)
local function with_session(kind, options, body)
	local names = { "adapters.clipboard", "core.process.adapters.shell_runner", "infra.display_server" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local session = { clipboard = "saved", primary = options.primary, writes = {}, combos = {}, pending = nil }
	local shell = {}
	function shell.has_command() return true end
	function shell.exec_checked(command)
		if ClipboardTargets.is_listing(command) then return true, ClipboardTargets.TEXT_ONLY, nil end
		if command:find("primary", 1, true) then
			if session.primary == false then return false, "", "no PRIMARY owner" end
			return true, session.primary, nil
		end
		return true, session.clipboard, nil
	end
	function shell.with_exact_stdin(command, text)
		session.pending = text
		return command
	end
	function shell.run()
		session.writes[#session.writes + 1] = session.pending
		session.clipboard = session.pending
		return true
	end
	package.loaded["core.process.adapters.shell_runner"] = shell
	package.loaded["infra.display_server"] = {
		UNKNOWN = "unknown",
		is_wayland = function() return kind == "wayland" end,
		is_x11 = function() return kind == "x11" end,
		kind = function() return kind end,
	}
	package.loaded["adapters.clipboard"] = nil
	local function emit(combo)
		session.combos[#session.combos + 1] = combo
		-- The application copies what it has selected.
		if combo == "ctrl+c" then session.clipboard = session.selected end
		return true
	end
	local function sleep_ms(ms)
		if options.on_settle then options.on_settle(session, ms) end
		return true
	end
	session.selected = options.selected or "source"
	local ok, err = pcall(body, require("adapters.clipboard"), session, emit, sleep_ms)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end

local function has_combo(session, name)
	for _, combo in ipairs(session.combos) do if combo == name then return true end end
	return false
end

helpers.describe("clipboard selection range recheck (LCP-003)", function()
	for _, kind in ipairs({ "x11", "wayland" }) do
		helpers.it("replaces an unchanged range (" .. kind .. ")", function()
			with_session(kind, { primary = "source" }, function(clipboard, session, emit, sleep_ms)
				local ok, reason = clipboard.transform_selection(string.upper, emit, sleep_ms)
				helpers.assert_true(ok, tostring(reason))
				helpers.assert_true(has_combo(session, "ctrl+v"))
				helpers.assert_eq(session.clipboard, "saved", "the clipboard is restored")
			end)
		end)

		helpers.it("does not paste over a range changed before the paste (" .. kind .. ")", function()
			local settle = function(session, ms)
				-- The application selects another range in the same field.
				if ms == 30 then session.primary, session.selected = "other-range", "other-range" end
			end
			with_session(kind, { primary = "source", on_settle = settle }, function(clipboard, session, emit, sleep_ms)
				local ok, reason = clipboard.transform_selection(string.upper, emit, sleep_ms)
				helpers.assert_eq(ok, false)
				helpers.assert_eq(reason, "selection_changed")
				helpers.assert_eq(has_combo(session, "ctrl+v"), false, "no payload may reach the new range")
				helpers.assert_eq(session.clipboard, "saved", "the clipboard is still restored")
			end)
		end)

		helpers.it("refuses when PRIMARY becomes unreadable before the paste (" .. kind .. ")", function()
			local settle = function(session, ms) if ms == 30 then session.primary = false end end
			with_session(kind, { primary = "source", on_settle = settle }, function(clipboard, session, emit, sleep_ms)
				local ok, reason = clipboard.transform_selection(string.upper, emit, sleep_ms)
				helpers.assert_eq({ ok, reason }, { false, "selection_changed" })
				helpers.assert_eq(has_combo(session, "ctrl+v"), false)
				helpers.assert_eq(session.clipboard, "saved")
			end)
		end)

		helpers.it("keeps the field-only check when PRIMARY does not publish the range (" .. kind .. ")", function()
			for _, primary in ipairs({ false, "unrelated" }) do
				with_session(kind, { primary = primary }, function(clipboard, session, emit, sleep_ms)
					local ok, reason = clipboard.transform_selection(string.upper, emit, sleep_ms)
					helpers.assert_true(ok, tostring(reason))
					helpers.assert_true(has_combo(session, "ctrl+v"))
					helpers.assert_eq(session.clipboard, "saved")
				end)
			end
		end)
	end
end)
