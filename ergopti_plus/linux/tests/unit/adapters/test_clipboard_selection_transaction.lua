--- tests/unit/adapters/test_clipboard_selection_transaction.lua

--- ==============================================================================
--- MODULE: Clipboard Selection Transaction
--- DESCRIPTION:
--- Proves that selection transforms use the session clipboard backend, emit copy
--- and paste through uinput, and restore the user's clipboard on every exit.
--- The read-only probe (the tone actions read the selection, then replace it
--- once the model answers) copies the same way and pastes nothing.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs one isolated clipboard transaction against a simulated desktop session.
--- @param kind string "x11" or "wayland"
--- @param selection string|nil Text published by Ctrl+C; nil means no selection.
--- @param body function
local function with_session(kind, selection, body)
	local names = {
		clipboard = "adapters.clipboard",
		shell = "adapters.shell_runner",
		display = "infra.display_server",
	}
	local previous = {}
	for key, name in pairs(names) do previous[key] = package.loaded[name] end

	local shell = { current = "saved", writes = {}, reads = {}, pending = nil }
	function shell.has_command() return true end
	function shell.exec() return shell.current end
	function shell.exec_checked(command)
		shell.reads[#shell.reads + 1] = command
		return true, shell.current, nil
	end
	function shell.with_exact_stdin(command, text)
		shell.pending = { command = command, text = text }
		return command
	end
	function shell.run()
		shell.writes[#shell.writes + 1] = shell.pending
		shell.current = shell.pending.text
		shell.pending = nil
		return true
	end

	package.loaded[names.shell] = shell
	package.loaded[names.display] = {
		UNKNOWN = "unknown",
		is_wayland = function() return kind == "wayland" end,
		is_x11 = function() return kind == "x11" end,
		kind = function() return kind end,
	}
	package.loaded[names.clipboard] = nil

	local combos = {}
	local function emit(combo)
		combos[#combos + 1] = combo
		if combo == "ctrl+c" and selection ~= nil then shell.current = selection end
		return true
	end
	local sleeps = {}
	local function sleep_ms(ms)
		sleeps[#sleeps + 1] = ms
		return true
	end

	local ok, err = pcall(function()
		body(require(names.clipboard), shell, combos, sleeps, emit, sleep_ms)
	end)
	for key, name in pairs(names) do package.loaded[name] = previous[key] end
	helpers.assert_true(ok, "selection transaction probe must not throw: " .. tostring(err))
end

helpers.describe("clipboard selection transaction", function()
	helpers.it("transforms and restores through the X11 backend", function()
		with_session("x11", "selected", function(clipboard, shell, combos, sleeps, emit, sleep_ms)
			local ok = clipboard.transform_selection(string.upper, emit, sleep_ms)

			helpers.assert_true(ok, "the complete transform must succeed")
			helpers.assert_eq(combos, { "ctrl+c", "ctrl+v" }, "copy and paste must use uinput combos")
			helpers.assert_eq(#sleeps, 3, "copy, paste, and restore must each settle")
			helpers.assert_eq(shell.writes[2].text, "SELECTED", "the replacement must be staged")
			helpers.assert_eq(shell.writes[3].text, "saved", "the original clipboard must be restored")
			helpers.assert_true(shell.reads[1]:find("xclip", 1, true) ~= nil,
				"an X11 session must use its selected clipboard backend")
		end)
	end)

	helpers.it("uses wl-clipboard under Wayland", function()
		with_session("wayland", "selected", function(clipboard, shell, _, _, emit, sleep_ms)
			local ok = clipboard.transform_selection(string.upper, emit, sleep_ms)

			helpers.assert_true(ok, "the Wayland transform must succeed")
			helpers.assert_true(shell.reads[1]:find("wl-paste", 1, true) ~= nil,
				"Wayland reads must not fall back to an X11 tool")
			helpers.assert_eq(shell.writes[1].command, "wl-copy",
				"Wayland writes must stay on the selected backend")
		end)
	end)

	helpers.it("detects no selection without pasting the sentinel", function()
		with_session("x11", nil, function(clipboard, shell, combos, _, emit, sleep_ms)
			local ok, reason = clipboard.transform_selection(string.upper, emit, sleep_ms)

			helpers.assert_true(not ok, "an unchanged probe means there was no selection")
			helpers.assert_eq(reason, "no_selection")
			helpers.assert_eq(combos, { "ctrl+c" }, "no replacement must be pasted")
			helpers.assert_eq(shell.writes[#shell.writes].text, "saved",
				"the probe must never remain in the user's clipboard")
		end)
	end)

	helpers.it("restores before reporting a timing failure", function()
		with_session("x11", "selected", function(clipboard, shell, _, _, emit)
			local ok, reason = clipboard.transform_selection(string.upper, emit, function() return false end)

			helpers.assert_true(not ok, "an uncompleted wait must abort the transaction")
			helpers.assert_eq(reason, "copy_settle_failed")
			helpers.assert_eq(shell.writes[#shell.writes].text, "saved",
				"all post-snapshot failures must restore the clipboard")
		end)
	end)

	helpers.it("reads the selection without pasting and restores the clipboard", function()
		with_session("x11", "merci pour ton aide", function(clipboard, shell, combos, _, emit, sleep_ms)
			local ok, text, reason = clipboard.read_selection(emit, sleep_ms)

			helpers.assert_true(ok, "a published selection is read: " .. tostring(reason))
			helpers.assert_eq(text, "merci pour ton aide")
			helpers.assert_eq(combos, { "ctrl+c" }, "the read copies and pastes nothing")
			helpers.assert_eq(shell.writes[#shell.writes].text, "saved", "the clipboard is put back")
		end)
	end)

	helpers.it("reports no selection from the read probe and restores the clipboard", function()
		with_session("wayland", nil, function(clipboard, shell, _, _, emit, sleep_ms)
			local ok, text, reason = clipboard.read_selection(emit, sleep_ms)

			helpers.assert_true(not ok, "an unchanged probe means there was no selection")
			helpers.assert_eq(text, "")
			helpers.assert_eq(reason, "no_selection")
			helpers.assert_eq(shell.writes[#shell.writes].text, "saved",
				"the probe must never remain in the user's clipboard")
		end)
	end)
end)

--- Makes the simulated session answer a text/uri-list read only when the
--- clipboard holds one, as xclip and wl-paste refuse a target nobody offers.
--- @param shell table The simulated shell of with_session.
local function offer_uri_list_only_for_files(shell)
	local read = shell.exec_checked
	function shell.exec_checked(command)
		if command:find("text/uri-list", 1, true) and not shell.current:find("^file:") then
			shell.reads[#shell.reads + 1] = command
			return false, "", "target text/uri-list not available"
		end
		return read(command)
	end
end

helpers.describe("clipboard file-selection probe (text/uri-list)", function()
	for _, case in ipairs({
		{ kind = "x11", needle = "xclip -selection clipboard -t text/uri-list -o" },
		{ kind = "wayland", needle = "wl-paste --no-newline --type text/uri-list" },
	}) do
		helpers.it("reads the copied files as text/uri-list and restores the clipboard (" .. case.kind .. ")", function()
			with_session(case.kind, "file:///home/ana/run.sh\r\n", function(clipboard, shell, combos, _, emit, sleep_ms)
				offer_uri_list_only_for_files(shell)
				local ok, uri_list, reason = clipboard.read_selection_uri_list(emit, sleep_ms)

				helpers.assert_true(ok, "the copied files are read: " .. tostring(reason))
				helpers.assert_eq(uri_list, "file:///home/ana/run.sh\r\n")
				helpers.assert_eq(combos, { "ctrl+c" }, "the probe copies and pastes nothing")
				helpers.assert_true(shell.reads[#shell.reads]:find(case.needle, 1, true) ~= nil,
					"the uri-list target is asked for: " .. shell.reads[#shell.reads])
				helpers.assert_true(shell.writes[1].text:find("^__ERGOPTI_SELECTION_PROBE_") ~= nil,
					"a sentinel replaces files copied earlier before the copy")
				helpers.assert_eq(shell.writes[#shell.writes].text, "saved", "the clipboard is put back")
			end)
		end)
	end

	helpers.it("reports no file selection when the copy published no uri-list", function()
		with_session("x11", nil, function(clipboard, shell, _, _, emit, sleep_ms)
			offer_uri_list_only_for_files(shell)
			local ok, uri_list, reason = clipboard.read_selection_uri_list(emit, sleep_ms)

			helpers.assert_true(not ok, "nothing was copied")
			helpers.assert_eq(uri_list, "")
			helpers.assert_eq(reason, "no_file_selection")
			helpers.assert_eq(shell.writes[#shell.writes].text, "saved", "the sentinel never remains")
		end)
	end)
end)
