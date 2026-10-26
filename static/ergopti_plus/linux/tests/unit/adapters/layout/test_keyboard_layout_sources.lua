--- tests/unit/adapters/layout/test_keyboard_layout_sources.lua

--- ==============================================================================
--- MODULE: Keyboard Layout — where the keymap comes from
--- DESCRIPTION:
--- Drives refresh() through every keymap source with a stubbed shell, so the
--- ORDER and the FALLBACKS are pinned rather than only the parser.
---
--- WHY THIS FILE EXISTS:
--- On a Wayland session the only source used to be `xkbcli dump-keymap-wayland`,
--- which needs libxkbcommon 1.8 (February 2025). Ubuntu 24.04 ships 1.6, so on
--- its default GNOME session refresh() found no keymap, capture refused the
--- keyboard and the daemon exited at boot — on the most common Linux desktop
--- there is. Every test below fails against that single-source chain.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A keymap big enough to pass the plausibility floor: 26 letters over two
--- levels plus ten digits.
--- @return string
local function plausible_keymap()
	local codes, symbols = {}, {}
	local letters = "abcdefghijklmnopqrstuvwxyz"
	for index = 1, #letters do
		local letter = letters:sub(index, index)
		codes[#codes + 1] = string.format("\t<K%02d> = %d;", index, 20 + index)
		symbols[#symbols + 1] = string.format("\tkey <K%02d> { [ %s, %s ] };", index, letter, letter:upper())
	end
	for digit = 0, 9 do
		codes[#codes + 1] = string.format("\t<D%02d> = %d;", digit, 60 + digit)
		symbols[#symbols + 1] = string.format("\tkey <D%02d> { [ %d ] };", digit, digit)
	end
	return "xkb_keymap {\nxkb_keycodes \"(unnamed)\" {\n" .. table.concat(codes, "\n")
		.. "\n};\nxkb_symbols \"(unnamed)\" {\n" .. table.concat(symbols, "\n") .. "\n};\n};\n"
end

--- Loads keyboard_layout against a stub shell, a forced display server and a
--- capture stub that accepts any text.
--- @param kind string DisplayServer constant.
--- @param answers table Ordered { pattern, output } pairs; first match wins.
--- @param env table|nil Environment variables the module may read.
--- @return table layout, table commands
local function load_with(kind, answers, env)
	local commands = {}
	-- A controlled map acknowledgement owns the parser's inverse data and
	-- receipt. This checks source order without granting native source currency.
	package.loaded["adapters.xkb_capture"] = require("tests.support.layout_cohort_fixture").capture(function(text)
		return package.loaded["adapters.keyboard_layout"].build(text)
	end)
	local Shell = helpers.load_module("adapters.shell_runner")
	Shell._set_runner(function(cmd)
		commands[#commands + 1] = cmd
		if cmd:match("^command %-v") then
			local binary = cmd:match("command %-v '?([%w%-]+)")
			return env and env["has:" .. tostring(binary)] == true or false
		end
		for _, answer in ipairs(answers) do
			if cmd:find(answer[1], 1, true) then return answer[2] end
		end
		return ""
	end)
	local DisplayServer = helpers.load_module("infra.display_server")
	DisplayServer._set_for_test(kind, "")
	package.loaded["infra.xkb_rmlvo"] = nil
	local layout = helpers.load_module("adapters.keyboard_layout")
	return layout, commands, Shell
end

--- Runs fn with os.getenv answering from `env` (then the real environment for
--- anything a test does not name is NOT consulted: unknown names are nil).
--- @param env table
--- @param fn function
local function with_env(env, fn)
	local real = os.getenv
	os.getenv = function(name) return env[name] end
	local ok, err = pcall(fn)
	os.getenv = real
	if not ok then error(err, 0) end
end

local function cleanup(Shell)
	Shell._reset_runner()
	package.loaded["adapters.xkb_capture"] = nil
	package.loaded["adapters.keyboard_layout"] = nil
end

helpers.describe("keyboard_layout: keymap sources on Wayland", function()

	helpers.it("keymap-session-exit: failed native metadata cannot select the compiled keymap", function()
		local shell = require("adapters.shell_runner")
		helpers.assert_true(shell.has_command("python3") and shell.has_command("luajit"),
			"native session keymap receipts require Python and the actual LuaJIT FFI runtime")
		local quote = require("text_utils").shell_quote
		local runtime = assert(shell.exec_line("command -v luajit"))
		local fixture = helpers.driver_root() .. "/tests/hardware/test_xkb_session_exit.py"
		local status = os.execute("python3 " .. quote(fixture) .. " --runtime " .. quote(runtime))
		helpers.assert_true(status == true or status == 0, "failed actual metadata must not select native compilation")
	end)

	helpers.it("keymap-source-exit: refuses failed real source commands before native publication", function()
		local shell = require("adapters.shell_runner")
		helpers.assert_true(shell.has_command("python3") and shell.has_command("luajit"),
			"native keymap source receipts require Python and the actual LuaJIT FFI runtime")
		local quote = require("text_utils").shell_quote
		local runtime = assert(shell.exec_line("command -v luajit"))
		local fixture = helpers.driver_root() .. "/tests/hardware/test_xkb_source_exit.py"
		local status = os.execute("python3 " .. quote(fixture) .. " --runtime " .. quote(runtime))
		helpers.assert_true(status == true or status == 0, "failed actual keymap acquisition must refuse native publication")
	end)

	helpers.it("uses xkbcli dump-keymap-wayland when libxkbcommon has it", function()
		local layout, _, Shell = load_with("wayland", {
			{ "dump-keymap-wayland", plausible_keymap() },
		})
		with_env({ DISPLAY = ":0" }, function()
			helpers.assert_true(layout.refresh(nil), "a Wayland dump must load")
		end)
		helpers.assert_contains(layout.source(), "dump-keymap-wayland")
		cleanup(Shell)
	end)

	for _, fallback in ipairs({ "xwayland", "compile" }) do
		helpers.it("keymap-source-exit: a failed dump retains the healthy " .. fallback .. " fallback", function()
			local layout, _, Shell = load_with("wayland", {
				{ "dump-keymap-wayland", { ok = false, output = plausible_keymap(), error = "command exited with status 73" } },
				{ "xkbcomp -xkb", fallback == "xwayland" and plausible_keymap() or
					{ ok = false, output = plausible_keymap(), error = "command exited with status 73" } },
				{ "compile-keymap --layout us", plausible_keymap() },
			})
			local ok, detail = pcall(function()
				with_env({ DISPLAY = ":fixture", HOME = "/nonexistent-home", XKB_DEFAULT_LAYOUT = "us" }, function()
					helpers.assert_true(layout.refresh(nil), "a later acknowledged keymap must remain usable")
				end)
				helpers.assert_contains(layout.source(), fallback == "xwayland" and "xkbcomp" or "compile-keymap")
			end)
			cleanup(Shell)
			if not ok then error(detail, 0) end
		end)
	end

	helpers.it("falls back to XWayland's keymap when the dump command is missing", function()
		-- libxkbcommon 1.6 (Ubuntu 24.04): `xkbcli dump-keymap-wayland` prints
		-- nothing. XWayland receives the compositor's keymap like any client.
		local layout, _, Shell = load_with("wayland", {
			{ "xkbcomp -xkb", plausible_keymap() },
		})
		with_env({ DISPLAY = ":0", WAYLAND_DISPLAY = "wayland-0" }, function()
			helpers.assert_true(layout.refresh(nil),
				"with no dump command, XWayland's keymap must be read instead of giving up")
		end)
		helpers.assert_contains(layout.source(), "xkbcomp")
		cleanup(Shell)
	end)

	helpers.it("compiles GNOME's active layout when there is no XWayland either", function()
		local layout, commands, Shell = load_with("wayland", {
			{ "mru-sources", "[('xkb', 'fr+ergopti'), ('xkb', 'us')]" },
			{ "xkb-options", "@as []" },
			{ "compile-keymap --layout fr --variant ergopti", plausible_keymap() },
		}, { ["has:gsettings"] = true })
		with_env({ HOME = "/nonexistent-home" }, function()
			helpers.assert_true(layout.refresh(nil),
				"the session's layout names must be compiled when nothing can be dumped")
		end)
		helpers.assert_contains(layout.source(), "gnome")
		for _, cmd in ipairs(commands) do
			helpers.assert_true(not cmd:find("xkbcomp", 1, true),
				"xkbcomp must not be tried without a DISPLAY to read: " .. cmd)
		end
		cleanup(Shell)
	end)

	helpers.it("uses the XKB_DEFAULT variables of a wlroots compositor", function()
		local layout, _, Shell = load_with("wayland", {
			{ "compile-keymap --layout de", plausible_keymap() },
		})
		with_env({ HOME = "/nonexistent-home", XKB_DEFAULT_LAYOUT = "de" }, function()
			helpers.assert_true(layout.refresh(nil), "XKB_DEFAULT_LAYOUT names the layout on sway")
		end)
		helpers.assert_contains(layout.source(), "env")
		cleanup(Shell)
	end)

	helpers.it("still reports failure when no source names a layout", function()
		local layout, _, Shell = load_with("wayland", {})
		with_env({ HOME = "/nonexistent-home" }, function()
			helpers.assert_eq(layout.refresh(nil), false,
				"no keymap must stay a failure, never a guessed US table")
		end)
		helpers.assert_nil(layout.source())
		cleanup(Shell)
	end)

end)

helpers.describe("keyboard_layout: keymap sources on X11", function()

	helpers.it("compiles the session layout when neither xkbcli nor xkbcomp answer", function()
		local layout, _, Shell = load_with("x11", {
			{ "localectl status", "      X11 Layout: fr\n     X11 Variant: bepo\n" },
			{ "compile-keymap --layout fr --variant bepo", plausible_keymap() },
		}, { ["has:localectl"] = true })
		with_env({ DISPLAY = ":0", HOME = "/nonexistent-home" }, function()
			helpers.assert_true(layout.refresh(nil), "localectl's layout must be compiled as a last resort")
		end)
		helpers.assert_contains(layout.source(), "localectl")
		cleanup(Shell)
	end)

	helpers.it("never runs localectl where systemd-localed is absent", function()
		-- Minimal and non-systemd systems ship no localectl: the probe answers
		-- first, and the system defaults are read as files instead.
		local layout, commands, Shell = load_with("x11", {
			{ "localectl status", "      X11 Layout: fr\n     X11 Variant: bepo\n" },
			{ "compile-keymap --layout fr --variant bepo", plausible_keymap() },
		})
		with_env({ DISPLAY = ":0", HOME = "/nonexistent-home" }, function() layout.refresh(nil) end)
		local probed = false
		for _, command in ipairs(commands) do
			helpers.assert_true(not command:find("localectl status", 1, true), "localectl ran without its probe: " .. command)
			if command:find("command -v 'localectl'", 1, true) or command:find("command -v localectl", 1, true) then
				probed = true
			end
		end
		helpers.assert_true(probed, "the absent localectl must be probed, not assumed")
		cleanup(Shell)
	end)

end)
