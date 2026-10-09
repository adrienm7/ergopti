--- tests/unit/modules/test_system_actions.lua

--- ==============================================================================
--- MODULE: System actions run their exact command (Linux)
--- DESCRIPTION:
--- Runs every system action through the real gesture executor with a recording
--- shell and asserts the exact command it backgrounds; empty_trash and
--- force_quit_frontmost, the ones the catalogue asks to confirm here, are
--- chained behind zenity or kdialog and run nothing when neither can ask;
--- make_executable_selection reads the file manager's text/uri-list and chmods
--- exactly the paths it names.
---
--- ROOT CAUSES ENCODED:
--- 1. The approved system actions did not exist on Linux.
--- 2. The catalogue's `confirm` field was read by no driver: a stray gesture
---    would have emptied the trash unasked.
--- 3. The daemon holds the grabbed keyboard, so every command is backgrounded.
--- 4. sleep_displays powered the displays off at once, so the release of the
---    keys that fired it woke them straight back up.
--- 5. force_quit_frontmost killed unasked (decision of 2026-09-29), and a kill
---    confirmed in a dialog must target the window active before the question.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs `body` with os.execute recording instead of running.
--- @param body function Receives the recorded command table.
--- @param answer function|nil Result of each command, true by default.
local function with_recorded_shell(body, answer)
	local commands = {}
	local real = os.execute
	os.execute = function(cmd)
		commands[#commands + 1] = tostring(cmd)
		if answer then return answer(tostring(cmd)) end
		return true
	end
	local ok, err = pcall(body, commands)
	os.execute = real
	if not ok then error(err, 0) end
end

--- The commands that were not `command -v` probes.
--- @param commands table
--- @return table
local function launched(commands)
	local out = {}
	for _, command in ipairs(commands) do
		if not command:find("command -v", 1, true) then out[#out + 1] = command end
	end
	return out
end

--- Replaces modules in package.loaded for the duration of body.
--- @param stubs table name -> module
--- @param body function
local function with_modules(stubs, body)
	local saved = {}
	for name, stub in pairs(stubs) do
		saved[name] = package.loaded[name]
		package.loaded[name] = stub
	end
	local ok, err = pcall(body)
	for name in pairs(stubs) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

local EXPECTED = {
	show_desktop = "{ case \"$(wmctrl -m 2>/dev/null)\" in *'mode: ON'*) wmctrl -k off;; *) wmctrl -k on;; esac; }",
	-- Powered off at once, the release of the triggering keys woke them again.
	sleep_displays = "{ sleep 1 && xset dpms force off; }",
	toggle_dark_mode = "{ case \"$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null)\" in"
		.. " *prefer-dark*) gsettings set org.gnome.desktop.interface color-scheme default;;"
		.. " *) gsettings set org.gnome.desktop.interface color-scheme prefer-dark;; esac; }",
	mic_mute_toggle = "{ pactl set-source-mute @DEFAULT_SOURCE@ toggle; }",
	-- The desktop and the panels belong to the desktop shell: signalling their
	-- process removed the desktop and the panels for the session.
	quit_frontmost_app = "{ win=$(xdotool getactivewindow 2>/dev/null)"
		.. ' && kind=$(xprop -id "$win" _NET_WM_WINDOW_TYPE 2>/dev/null)'
		.. ' && case "$kind" in *_NET_WM_WINDOW_TYPE_DESKTOP*|*_NET_WM_WINDOW_TYPE_DOCK*) false;; esac'
		.. ' && pid=$(xdotool getwindowpid "$win" 2>/dev/null)'
		.. ' && [ "$pid" -gt 1 ] && [ "$pid" != "$PPID" ] && kill -TERM "$pid"; }',
	clear_notifications = "{ dunstctl close-all 2>/dev/null || makoctl dismiss --all 2>/dev/null"
		.. " || swaync-client --close-all 2>/dev/null; }",
}

helpers.describe("Linux system actions", function()
	local Gestures = helpers.load_module("modules.gestures.manager")
	local Catalogue = require("_generated.action_catalogue")

	for action, expected in pairs(EXPECTED) do
		helpers.it(action .. " backgrounds its exact command (system-actions)", function()
			with_recorded_shell(function(commands)
				Gestures.execute_action(action, "tap_3")
				helpers.assert_eq(launched(commands)[1], expected .. " 2>/dev/null &")
				helpers.assert_eq(#launched(commands), 1)
			end)
		end)
	end

	helpers.it("the catalogue asks to confirm exactly empty_trash and force_quit_frontmost (system-actions)", function()
		local confirmed = {}
		for id, meta in pairs(Catalogue.actions) do
			if meta.confirm == true then confirmed[#confirmed + 1] = id end
		end
		table.sort(confirmed)
		helpers.assert_eq(confirmed, { "empty_trash", "force_quit_frontmost" })
	end)

	-- The window is read before the question: once zenity's own window is gone,
	-- the one the window manager focuses may be another application's.
	local FORCE_QUIT_KILL = 'kind=$(xprop -id "$win" _NET_WM_WINDOW_TYPE 2>/dev/null)'
		.. ' && case "$kind" in *_NET_WM_WINDOW_TYPE_DESKTOP*|*_NET_WM_WINDOW_TYPE_DOCK*) false;; esac'
		.. ' && pid=$(xdotool getwindowpid "$win" 2>/dev/null)'
		.. ' && [ "$pid" -gt 1 ] && [ "$pid" != "$PPID" ] && kill -KILL "$pid"'

	helpers.it("force_quit_frontmost kills only behind zenity's question, window read first (force-quit-confirm)",
		function()
			with_recorded_shell(function(commands)
				Gestures.execute_action("force_quit_frontmost", "tap_3")
				local run = launched(commands)
				helpers.assert_eq(#run, 1)
				local head = "{ win=$(xdotool getactivewindow 2>/dev/null)"
					.. " && zenity --question --no-markup --default-cancel "
				helpers.assert_eq(run[1]:sub(1, #head), head,
					"the active window is read, then the question comes, with Cancel focused: " .. run[1])
				local chained = " && { " .. FORCE_QUIT_KILL .. "; }; } 2>/dev/null &"
				helpers.assert_eq(run[1]:sub(-#chained), chained, "the kill runs only on Continue")
				helpers.assert_eq(select(2, run[1]:gsub("getactivewindow", "")), 1,
					"the window is never read again after the question")
			end, function(command)
				if command:find("command -v", 1, true) then return command:find("zenity", 1, true) ~= nil end
				return true
			end)
		end)

	helpers.it("force_quit_frontmost kills only behind kdialog's No, Cancel as default (force-quit-confirm)", function()
		with_recorded_shell(function(commands)
			Gestures.execute_action("force_quit_frontmost", "tap_3")
			local run = launched(commands)
			helpers.assert_eq(#run, 1)
			helpers.assert_true(run[1]:find("^{ win=%$%(xdotool getactivewindow 2>/dev/null%) && { kdialog ") ~= nil,
				run[1])
			local chained = "; [ $? -eq 1 ]; } && { " .. FORCE_QUIT_KILL .. "; }; } 2>/dev/null &"
			helpers.assert_eq(run[1]:sub(-#chained), chained)
		end, function(command)
			if command:find("command -v", 1, true) then return command:find("kdialog", 1, true) ~= nil end
			return true
		end)
	end)

	helpers.it("force_quit_frontmost kills nothing when no dialog can ask (force-quit-confirm)", function()
		with_recorded_shell(function(commands)
			Gestures.execute_action("force_quit_frontmost", "tap_3")
			helpers.assert_eq(#launched(commands), 0)
		end, function(command)
			if command:find("command -v", 1, true) then return false end
			return true
		end)
	end)

	-- Executed, not only spelled: a real shell runs the confirmed command with
	-- stub tools whose active window changes once the question was asked.
	helpers.it("force_quit_frontmost: Cancel kills nothing, Continue kills the first window (force-quit-confirm)",
		function()
			local SystemActions = require("modules.gestures.system_actions")
			local command = SystemActions.command_for("force_quit_frontmost", "Force quit", true,
				function(binary) return binary == "zenity" end)
			helpers.assert_true(type(command) == "string", "a confirmed command is built")
			local dir = os.tmpname()
			os.remove(dir)
			helpers.assert_true(os.execute("mkdir -p '" .. dir .. "/bin'") ~= nil)
			local function write(path, text)
				local f = assert(io.open(path, "w"))
				f:write(text)
				f:close()
			end
			local function stub(name, body)
				write(dir .. "/bin/" .. name, "#!/bin/sh\n" .. body .. "\n")
				os.execute("chmod +x '" .. dir .. "/bin/" .. name .. "'")
			end
			stub("xdotool", 'case "$1" in getactivewindow) if [ -f "' .. dir .. '/asked" ]; then echo 222;'
				.. ' else echo 111; fi;; getwindowpid) echo "$(( $2 * 100 ))";; esac')
			stub("xprop", "echo '_NET_WM_WINDOW_TYPE(ATOM) = _NET_WM_WINDOW_TYPE_NORMAL'")
			stub("zenity", 'touch "' .. dir .. '/asked"; [ "$(cat "' .. dir .. '/answer")" = continue ]')
			-- kill is a shell builtin: a function shadows it with a recorder.
			write(dir .. "/run.sh", "kill() { echo \"$@\" >> '" .. dir .. "/killed'; }\n" .. command .. "\n")
			local function run(answer)
				os.remove(dir .. "/asked")
				os.remove(dir .. "/killed")
				write(dir .. "/answer", answer)
				os.execute("PATH='" .. dir .. "/bin':\"$PATH\" sh '" .. dir .. "/run.sh' >/dev/null 2>&1")
				local k = io.open(dir .. "/killed", "r")
				if not k then return nil end
				local out = k:read("*a")
				k:close()
				return out
			end
			local cancelled = run("cancel")
			local continued = run("continue")
			os.execute("rm -rf '" .. dir .. "'")
			helpers.assert_eq(cancelled, nil, "Cancel kills nothing")
			helpers.assert_eq(continued, "-KILL 11100\n", "Continue kills the window active before the question")
		end)

	helpers.it("empty_trash runs only behind zenity's question, Cancel as default (system-actions)", function()
		with_recorded_shell(function(commands)
			Gestures.execute_action("empty_trash", "tap_3")
			local run = launched(commands)
			helpers.assert_eq(#run, 1)
			helpers.assert_true(run[1]:find("^zenity %-%-question %-%-no%-markup %-%-default%-cancel ") ~= nil,
				"the question comes first, with Cancel focused: " .. run[1])
			local chained = " && { gio trash --empty; } 2>/dev/null &"
			helpers.assert_eq(run[1]:sub(-#chained), chained, "the trash is emptied only on Continue")
		end, function(command)
			if command:find("command -v", 1, true) then return command:find("zenity", 1, true) ~= nil end
			return true
		end)
	end)

	-- kdialog's --warningcontinuecancel focuses Continue, so a stray Return
	-- emptied the trash: its default button must be the one that cancels.
	helpers.it("empty_trash falls back to kdialog's question, Cancel as default (system-actions)", function()
		local Quote = require("adapters.shell_runner").quote
		local i18n = require("infra.i18n")
		with_recorded_shell(function(commands)
			Gestures.execute_action("empty_trash", "tap_3")
			local run = launched(commands)
			helpers.assert_eq(#run, 1)
			helpers.assert_true(run[1]:find("^{ kdialog %-%-title ") ~= nil, run[1])
			helpers.assert_true(run[1]:find(" --warningyesno ", 1, true) ~= nil, run[1])
			helpers.assert_true(run[1]:find(" --yes-label " .. Quote(i18n.get("button.cancel"))
				.. " --no-label " .. Quote(i18n.get("dialog.confirm_action.confirm")) .. "; ", 1, true) ~= nil,
				"the default Yes button cancels, No continues: " .. run[1])
			local chained = "; [ $? -eq 1 ]; } && { gio trash --empty; } 2>/dev/null &"
			helpers.assert_eq(run[1]:sub(-#chained), chained,
				"only No (exit 1) empties the trash, and the whole question is backgrounded")
		end, function(command)
			if command:find("command -v", 1, true) then return command:find("kdialog", 1, true) ~= nil end
			return true
		end)
	end)

	-- On GNOME and KDE none of the clients exists: the chain was backgrounded
	-- anyway, with its failure discarded, and nothing said why nothing happened.
	helpers.it("clear_notifications starts nothing without a notification client (system-actions)", function()
		with_recorded_shell(function(commands)
			Gestures.execute_action("clear_notifications", "tap_3")
			helpers.assert_eq(#launched(commands), 0)
			local probed = {}
			for _, command in ipairs(commands) do
				if command:find("command -v", 1, true) then probed[#probed + 1] = command end
			end
			helpers.assert_eq(#probed, 3, "dunstctl, makoctl and swaync-client are each looked for")
		end, function(command)
			if command:find("command -v", 1, true) then return false end
			return true
		end)
	end)

	helpers.it("empty_trash runs nothing when no dialog can ask (system-actions)", function()
		with_recorded_shell(function(commands)
			Gestures.execute_action("empty_trash", "tap_3")
			helpers.assert_eq(#launched(commands), 0)
		end, function(command)
			if command:find("command -v", 1, true) then return false end
			return true
		end)
	end)

	helpers.it("clear_clipboard writes an empty clipboard (system-actions)", function()
		local written = {}
		with_modules({ ["adapters.clipboard"] = {
			write = function(text) written[#written + 1] = text return true end,
		} }, function()
			with_recorded_shell(function()
				Gestures.execute_action("clear_clipboard", "tap_3")
			end)
		end)
		helpers.assert_eq(#written, 1)
		helpers.assert_eq(written[1], "")
	end)

	helpers.it("make_executable_selection chmods exactly the copied paths (system-actions)", function()
		local combos = {}
		with_modules({
			["adapters.clipboard"] = {
				read_selection_uri_list = function(emit_combo, sleep_ms)
					helpers.assert_eq(type(emit_combo), "function")
					helpers.assert_eq(type(sleep_ms), "function")
					return true, "file:///home/ana/run.sh\r\nfile:///home/ana/it%27s%20here.sh\r\n", nil
				end,
			},
			["modules.gestures.combo_emitter"] = { press = function(combo) combos[#combos + 1] = combo return true end },
			["adapters.event_loop"] = { sleep_ms = function() return true end },
		}, function()
			with_recorded_shell(function(commands)
				Gestures.execute_action("make_executable_selection", "tap_3")
				local run = launched(commands)
				helpers.assert_eq(run[1], "chmod +x '/home/ana/run.sh' '/home/ana/it'\\''s here.sh' 2>/dev/null &")
			end)
		end)
	end)

	helpers.it("make_executable_selection runs nothing for a foreign or empty selection (system-actions)", function()
		for _, report in ipairs({
			{ true, "https://example.org/x\r\n", nil },
			{ false, "", "no_file_selection" },
			{ true, "", nil },
		}) do
			with_modules({
				["adapters.clipboard"] = {
					read_selection_uri_list = function() return report[1], report[2], report[3] end,
				},
				["modules.gestures.combo_emitter"] = { press = function() return true end },
				["adapters.event_loop"] = { sleep_ms = function() return true end },
				["adapters.application_notifier"] = { send = function() return true end },
			}, function()
				with_recorded_shell(function(commands)
					Gestures.execute_action("make_executable_selection", "tap_3")
					helpers.assert_eq(#launched(commands), 0)
				end)
			end)
		end
	end)
end)
