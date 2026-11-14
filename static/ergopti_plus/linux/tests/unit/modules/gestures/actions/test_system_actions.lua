--- tests/unit/modules/gestures/actions/test_system_actions.lua

--- ==============================================================================
--- MODULE: System actions run their exact command (Linux)
--- DESCRIPTION:
--- Runs every system action through the real gesture executor with a recording
--- shell and asserts the exact command it backgrounds; empty_trash and
--- force_quit_frontmost, the ones the catalogue asks to confirm here, are
--- chained behind Ergopti's own dialog and run nothing when it cannot ask;
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
--- 7. open_terminal_here and new_text_file_here had no Linux handler: they act
---    only in the folder core/fs/adapters/file_manager_folder.lua proved, start the
---    terminal detached in it, create the file exclusively under the first free
---    name, reveal it in the same Nautilus process, and say why otherwise.
--- 6. minimize_all, eject_all_disks, open_emoji_picker, pick_color,
---    screen_capture_instant and ocr_screenshot were declared for Windows and
---    macOS only. Their Linux commands run here in a real shell against stub
---    tools, so a quoting slip or a filter that ejects the system disk fails.
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

--- The command an observed background launch runs, without the wrapper that
--- records its status and stderr (modules/gestures/background_commands.lua).
--- @param text string The recorded os.execute command.
--- @return string|nil
local function unwrap(text)
	return text:match("^%( %( (.*) %) </dev/null >/dev/null 2>'")
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

--- Runs `script` with `sh` in a PATH whose first folder holds the stub tools.
--- Every stub appends its name and arguments to the log the result returns.
--- @param script string Shell text, as the driver would background it.
--- @param stubs table name -> shell body run after the call is logged.
--- @return string log One "name arg arg" line per stub call.
--- @return string dir The stub folder (for files a stub wrote).
local function run_with_stubs(script, stubs)
	local dir = os.tmpname()
	os.remove(dir)
	-- LuaJIT's os.execute returns the status number, Lua 5.4's a boolean.
	local made = os.execute("mkdir '" .. dir .. "'")
	helpers.assert_true(made == true or made == 0, "the stub folder must be created")
	for name, body in pairs(stubs) do
		local fh = assert(io.open(dir .. "/" .. name, "w"))
		fh:write("#!/bin/sh\necho \"" .. name .. " $*\" >> \"" .. dir .. "/calls.log\"\n" .. body .. "\n")
		fh:close()
		os.execute("chmod +x '" .. dir .. "/" .. name .. "'")
	end
	local script_file = dir .. "/script.sh"
	local fh = assert(io.open(script_file, "w"))
	fh:write(script .. "\n")
	fh:close()
	-- install/launch.sh creates the session lock folder the serialized toggles
	-- flock in; the test provides it rather than depending on the host's home.
	local session = os.execute("mkdir '" .. dir .. "/ergopti'")
	helpers.assert_true(session == true or session == 0, "the session lock folder must be created")
	os.execute("PATH='" .. dir .. ":/usr/bin:/bin' STUBS='" .. dir .. "' XDG_RUNTIME_DIR='" .. dir
		.. "' sh '" .. script_file .. "' </dev/null >/dev/null 2>&1")
	local log_fh = io.open(dir .. "/calls.log", "r")
	local log = log_fh and log_fh:read("*a") or ""
	if log_fh then log_fh:close() end
	return log, dir
end

--- The shell text one action backgrounds, without its backgrounding suffix.
--- @param Gestures table
--- @param action string
--- @param answer function|nil Result of each recorded command.
--- @return string
local function backgrounded(Gestures, action, answer)
	local text
	with_recorded_shell(function(commands)
		Gestures.execute_action(action, "tap_3")
		local run = launched(commands)
		helpers.assert_eq(#run, 1, action .. " must background exactly one command")
		text = unwrap(run[1])
		helpers.assert_not_nil(text, action .. " must run as an observed background command")
	end, answer)
	return text
end

-- The read-modify-write toggles queue on one session lock (toggle-serialized-lds-002).
local SERIAL = "flock \"${XDG_RUNTIME_DIR:-$HOME/.cache}/ergopti/system-toggle.lock\" sh -c "

local EXPECTED = {
	show_desktop = "{ " .. SERIAL .. "'desktop=$(wmctrl -m 2>/dev/null) && case \"$desktop\" in"
		.. " *'\\''mode: ON'\\''*) wmctrl -k off;; *'\\''mode: OFF'\\''*) wmctrl -k on;; *) false;; esac'; }",
	-- Powered off at once, the release of the triggering keys woke them again.
	sleep_displays = "{ sleep 1 && xset dpms force off; }",
	toggle_dark_mode = "{ " .. SERIAL .. "'scheme=$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null)"
		.. " && case \"$scheme\" in"
		.. " \"'\\''prefer-dark'\\''\") gsettings set org.gnome.desktop.interface color-scheme default;;"
		.. " \"'\\''default'\\''\"|\"'\\''prefer-light'\\''\") gsettings set org.gnome.desktop.interface color-scheme prefer-dark;;"
		.. " *) false;; esac'; }",

	mic_mute_toggle = "{ pactl set-source-mute @DEFAULT_SOURCE@ toggle; }",
	-- The desktop and the panels belong to the desktop shell: signalling their
	-- process removed the desktop and the panels for the session.
	quit_frontmost_app = "{ win=$(xdotool getactivewindow 2>/dev/null)"
		.. ' && kind=$(xprop -id "$win" _NET_WM_WINDOW_TYPE 2>/dev/null)'
		.. ' && case "$kind" in *_NET_WM_WINDOW_TYPE_DESKTOP*|*_NET_WM_WINDOW_TYPE_DOCK*) false;; esac'
		.. ' && pid=$(xdotool getwindowpid "$win" 2>/dev/null)'
		.. ' && [ "$pid" -gt 1 ] && [ "$pid" != "$PPID" ]'
		.. ' && [ "$(xdotool getwindowpid "$win" 2>/dev/null)" = "$pid" ] && kill -TERM "$pid"; }',
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
				helpers.assert_eq(unwrap(launched(commands)[1]), expected)
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

	-- The window and its process are read before the question: once the
	-- dialog's own window is gone, the one the window manager focuses may be another
	-- application's, and a window closed meanwhile has no process to resolve.
	-- The owned dialog host's command words (ui/native_dialog.lua).
	local DIALOG = require("ui.native_dialog").command()
	local FORCE_QUIT_KILL = '[ "$(xdotool getwindowpid "$win" 2>/dev/null)" = "$pid" ] && kill -KILL "$pid"'

	helpers.it("force_quit_frontmost kills only behind the owned question, window read first (force-quit-confirm)",
		function()
			with_recorded_shell(function(commands)
				Gestures.execute_action("force_quit_frontmost", "tap_3")
				local run = launched(commands)
				helpers.assert_eq(#run, 1)
				local head = "{ win=$(xdotool getactivewindow 2>/dev/null)"
					.. ' && kind=$(xprop -id "$win" _NET_WM_WINDOW_TYPE 2>/dev/null)'
					.. ' && case "$kind" in *_NET_WM_WINDOW_TYPE_DESKTOP*|*_NET_WM_WINDOW_TYPE_DOCK*) false;; esac'
					.. ' && pid=$(xdotool getwindowpid "$win" 2>/dev/null)'
					.. ' && [ "$pid" -gt 1 ] && [ "$pid" != "$PPID" ]'
					.. " && " .. DIALOG .. " --question --no-markup --default-cancel "
				local command = unwrap(run[1])
				helpers.assert_eq(command:sub(1, #head), head,
					"the active window is read, then the question comes, with Cancel focused: " .. command)
				local chained = " && { " .. FORCE_QUIT_KILL .. "; }; }"
				helpers.assert_eq(command:sub(-#chained), chained, "the kill runs only on Continue")
				helpers.assert_eq(select(2, command:gsub("getactivewindow", "")), 1,
					"the window is never read again after the question")
			end)
		end)

	-- Executed, not only spelled: a real shell runs the confirmed command with
	-- stub tools whose active window changes once the question was asked.
	helpers.it("force_quit_frontmost: Cancel or a closed window kills nothing, Continue kills the first window"
		.. " (force-quit-confirm)",
		function()
			local SystemActions = require("modules.gestures.system_actions")
			local command = SystemActions.command_for("force_quit_frontmost", "Force quit", true)
			helpers.assert_true(type(command) == "string", "a confirmed command is built")
			local at = command:find(DIALOG, 1, true)
			helpers.assert_true(at ~= nil, "the owned dialog asks: " .. command)
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
			-- A window closed during the question no longer resolves to a process.
			stub("xdotool", 'case "$1" in getactivewindow) if [ -f "' .. dir .. '/asked" ]; then echo 222;'
				.. ' else echo 111; fi;; getwindowpid) [ -f "' .. dir .. '/closed" ] && exit 1;'
				.. ' echo "$(( $2 * 100 ))";; esac')
			stub("xprop", "echo '_NET_WM_WINDOW_TYPE(ATOM) = _NET_WM_WINDOW_TYPE_NORMAL'")
			-- The private executable stands in for the owned dialog host; exit 69
			-- is the host's « no display or no GTK 3 ».
			stub("dialog", 'touch "' .. dir .. '/asked"; answer=$(cat "' .. dir .. '/answer");'
				.. ' [ "$answer" = unavailable ] && exit 69;'
				.. ' [ "$answer" = closed ] && touch "' .. dir .. '/closed"; [ "$answer" != cancel ]')
			command = command:sub(1, at - 1) .. "'" .. dir .. "/bin/dialog'" .. command:sub(at + #DIALOG)
			-- kill is a shell builtin: a function shadows it with a recorder.
			write(dir .. "/run.sh", "kill() { echo \"$@\" >> '" .. dir .. "/killed'; }\n" .. command .. "\n")
			local function run(answer)
				os.remove(dir .. "/asked")
				os.remove(dir .. "/closed")
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
			local closed = run("closed")
			local unavailable = run("unavailable")
			os.execute("rm -rf '" .. dir .. "'")
			helpers.assert_eq(cancelled, nil, "Cancel kills nothing")
			helpers.assert_eq(continued, "-KILL 11100\n", "Continue kills the window active before the question")
			helpers.assert_eq(closed, nil, "a window closed during the question leaves its old process id alone")
			helpers.assert_eq(unavailable, nil, "a dialog that cannot open kills nothing")
		end)

	helpers.it("empty_trash runs only behind the owned question, Cancel as default (system-actions)", function()
		with_recorded_shell(function(commands)
			Gestures.execute_action("empty_trash", "tap_3")
			local run = launched(commands)
			helpers.assert_eq(#run, 1)
			local head = DIALOG .. " --question --no-markup --default-cancel "
			local command = unwrap(run[1])
			helpers.assert_true(command:sub(1, #head) == head,
				"the question comes first, with Cancel focused: " .. command)
			local chained = " && { " .. require("modules.gestures.system_actions").EMPTY_TRASH .. "; }"
			helpers.assert_eq(command:sub(-#chained), chained, "the trash is emptied only on Continue")
		end)
	end)

	-- Measured on Ubuntu 24.04 (tests/hardware/run_desktop_actions_live.lua):
	-- without GVfs, `gio trash --empty` exits 0 and leaves the trash full, so
	-- the action reported success for nothing. It now fails unless the home
	-- trash (XDG trash specification) is empty afterwards.
	helpers.it("empty_trash fails when the trash is still full afterwards (system-actions-empty-trash)", function()
		local SystemActions = require("modules.gestures.system_actions")
		local dir = os.tmpname(); os.remove(dir)
		assert(os.execute("mkdir -p '" .. dir .. "/bin' '" .. dir .. "/data/Trash/files'"))
		local function run(gio_body, trashed)
			local gio = assert(io.open(dir .. "/bin/gio", "w")); gio:write("#!/bin/sh\n", gio_body, "\n"); gio:close()
			os.execute("chmod +x '" .. dir .. "/bin/gio'; rm -rf '" .. dir .. "/data/Trash/files'; mkdir -p '"
				.. dir .. "/data/Trash/files'")
			if trashed then local fh = assert(io.open(dir .. "/data/Trash/files/" .. trashed, "w")); fh:write("x"); fh:close() end
			local status = os.execute("PATH='" .. dir .. "/bin':\"$PATH\" XDG_DATA_HOME='" .. dir .. "/data' sh -c "
				.. require("core.text.engine.utils_core").shell_quote(SystemActions.EMPTY_TRASH))
			return status == true or status == 0
		end
		local ok, err = pcall(function()
			helpers.assert_eq(run("exit 0", "kept.txt"), false, "a no-op empty that leaves a file reports failure")
			helpers.assert_eq(run("exit 0", ".hidden"), false, "a hidden file left in the trash counts")
			helpers.assert_eq(run("rm -f \"$XDG_DATA_HOME\"/Trash/files/*; exit 0", "gone.txt"), true,
				"an empty that empties the trash succeeds")
			helpers.assert_eq(run("exit 1", nil), false, "gio's own failure still fails")
		end)
		os.execute("rm -rf '" .. dir .. "'")
		assert(ok, err)
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

	--- Runs body with a scripted folder owner and a recording notifier.
	local function with_folder(answer, body)
		local notices = {}
		local folder_port = {
			available = function() return true end,
			read_active_folder = function() return answer() end,
			reveal_command = function(folder, path) return "reveal " .. folder.bus .. " " .. path end,
		}
		with_modules({
			["core.fs.adapters.file_manager_folder"] = folder_port,
			["adapters.application_notifier"] = { send = function(message) notices[#notices + 1] = message; return true end },
		}, function() body(notices) end)
	end

	helpers.it("open_terminal_here starts the session terminal detached in the proven folder (system-actions)", function()
		with_folder(function() return { path = "/home/ana/My dir", bus = ":1.9" } end, function(notices)
			with_recorded_shell(function(commands)
				Gestures.execute_action("open_terminal_here", "tap_3")
				local run = launched(commands)
				helpers.assert_eq(#run, 1)
				helpers.assert_true(run[1]:match("^cd %-%- '/home/ana/My dir' && setsid '[%w%-]+' </dev/null >/dev/null 2>&1 &$")
					~= nil, run[1])
			end)
			helpers.assert_eq(notices, {})
		end)
	end)

	helpers.it("file-manager folder refusals say why and run nothing (system-actions)", function()
		local i18n = require("infra.i18n")
		local SystemActions = require("modules.gestures.system_actions")
		for reason, key in pairs(SystemActions.FOLDER_REFUSALS) do
			for _, action in ipairs({ "open_terminal_here", "new_text_file_here" }) do
				with_folder(function() return nil, reason, "Thunar" end, function(notices)
					with_recorded_shell(function(commands)
						Gestures.execute_action(action, "tap_3")
						helpers.assert_eq(#launched(commands), 0, action .. " " .. reason)
					end)
					local expected = i18n.get(key):gsub("{1}", "Thunar")
					helpers.assert_eq(notices, { expected }, action .. " " .. reason)
				end)
			end
		end
		helpers.assert_eq(SystemActions.FOLDER_REFUSALS.unsupported_file_manager, "system_actions.file_manager_unsupported")
	end)

	helpers.it("(nui-007-failure-level) a terminal or new-file failure is an error notice", function()
		local levels = {}
		with_modules({
			["core.fs.adapters.file_manager_folder"] = {
				available = function() return true end,
				read_active_folder = function() return { path = "/nonexistent/ergopti-nui-007", bus = ":1.9" } end,
				reveal_command = function() return "reveal" end,
			},
			["adapters.application_notifier"] = { send = function(message, opts)
				levels[#levels + 1] = { message = message, level = opts and opts.level }
				return true
			end },
			["modules.gestures.user_actions"] = {
				resolve_terminal = function() return nil end,
				detached_command = function() return "true" end,
			},
		}, function()
			with_recorded_shell(function()
				Gestures.execute_action("open_terminal_here", "tap_3")
				Gestures.execute_action("new_text_file_here", "tap_3")
			end)
		end)
		local i18n = require("infra.i18n")
		helpers.assert_eq(levels, {
			{ message = i18n.get("user_actions.terminal_unavailable"), level = "error" },
			{ message = i18n.get("system_actions.new_text_file_failed"), level = "error" },
		}, "Windows and user_actions show these failures as errors")
	end)

	helpers.it("new_text_file_here creates the first free name exclusively and reveals it (system-actions)", function()
		local dir = os.tmpname()
		os.remove(dir)
		local made = os.execute("mkdir '" .. dir .. "'")
		helpers.assert_true(made == true or made == 0)
		local base = require("infra.i18n").get("system_actions.new_text_file_name")
		local taken = assert(io.open(dir .. "/" .. base .. ".txt", "w"))
		taken:write("kept")
		taken:close()
		with_folder(function() return { path = dir, bus = ":1.9" } end, function(notices)
			with_recorded_shell(function(commands)
				Gestures.execute_action("new_text_file_here", "tap_3")
				local run = launched(commands)
				helpers.assert_eq(#run, 1)
				helpers.assert_eq(unwrap(run[1]), "reveal :1.9 " .. dir .. "/" .. base .. " 2.txt")
			end)
			helpers.assert_eq(notices, {})
		end)
		local kept = assert(io.open(dir .. "/" .. base .. ".txt", "r"))
		helpers.assert_eq(kept:read("*a"), "kept", "an existing file is never overwritten")
		kept:close()
		local created = io.open(dir .. "/" .. base .. " 2.txt", "r")
		helpers.assert_not_nil(created, "the second name is created")
		helpers.assert_eq(created:read("*a"), "")
		created:close()
		os.execute("rm -rf '" .. dir .. "'")
	end)

	helpers.it("create_new_text_file stops on a refusal other than an existing name (system-actions)", function()
		local SystemActions = require("modules.gestures.system_actions")
		local tried = {}
		local path = SystemActions.create_new_text_file("/srv/x", function(candidate)
			tried[#tried + 1] = candidate
			if #tried == 1 then return false, 17 end
			return false, 13
		end)
		helpers.assert_nil(path)
		helpers.assert_eq(#tried, 2)
		local count = 0
		helpers.assert_nil(SystemActions.create_new_text_file("/srv/x/", function()
			count = count + 1
			return false, "EEXIST"
		end))
		helpers.assert_eq(count, SystemActions.NEW_FILE_NAME_ATTEMPTS)
	end)

	helpers.it("never sends Ctrl+C to a terminal for make_executable_selection", function()
		local Open = require("modules.shortcuts.open_selection")
		Open._set_deps_for_test({ focused_app = function() return "gnome-terminal-server" end,
			focused_context = function() return "gnome-terminal-server", "test:terminal" end })
		local combos = {}
		local ok, err = pcall(function()
			with_modules({
				["adapters.clipboard"] = { read_selection_uri_list = function(emit)
					emit("ctrl+c"); return false, "", "no_file_selection"
				end },
				["modules.gestures.combo_emitter"] = { press = function(combo) combos[#combos + 1] = combo; return true end },
				["core.events.loop"] = { sleep_ms = function() return true end },
			}, function() Gestures.execute_action("make_executable_selection", "tap_3") end)
		end)
		Open._set_deps_for_test(nil)
		if not ok then error(err, 0) end
		helpers.assert_eq(combos, {})
	end)

	for _, boundary in ipairs({ "before copy", "after copy" }) do
		helpers.it("refuses make-executable when focus changes " .. boundary, function()
			local Open = require("modules.shortcuts.open_selection")
			local app, combos = "nautilus", {}
			Open._set_deps_for_test({ focused_app = function() return app end,
				focused_context = function() return app, "test:file-manager-window" end })
			local ok, err = pcall(function()
				with_modules({
					["adapters.clipboard"] = { read_selection_uri_list = function(emit)
						if boundary == "before copy" then app = "gnome-terminal-server" end
						local sent = emit("ctrl+c")
						if boundary == "before copy" then helpers.assert_eq(sent, false) end
						app = "gnome-terminal-server"
						return true, "file:///home/ana/run.sh", nil
					end },
					["modules.gestures.combo_emitter"] = { press = function(combo) combos[#combos + 1] = combo; return true end },
					["core.events.loop"] = { sleep_ms = function() return true end },
				}, function()
					with_recorded_shell(function(commands)
						Gestures.execute_action("make_executable_selection", "tap_3")
						helpers.assert_eq(#launched(commands), 0)
					end)
				end)
			end)
			Open._set_deps_for_test(nil)
			if not ok then error(err, 0) end
			helpers.assert_eq(combos, boundary == "before copy" and {} or { "ctrl+c" })
		end)
	end

	helpers.it("make_executable_selection chmods exactly the copied paths (system-actions)", function()
		local combos = {}
		with_modules({
			["modules.shortcuts.open_selection"] = { capture_file_manager = function() return function() return true end end },
			["adapters.clipboard"] = {
				read_selection_uri_list = function(emit_combo, sleep_ms)
					helpers.assert_eq(type(emit_combo), "function")
					helpers.assert_eq(type(sleep_ms), "function")
					return true, "file:///home/ana/run.sh\r\nfile:///home/ana/it%27s%20here.sh\r\n", nil
				end,
			},
			["modules.gestures.combo_emitter"] = { press = function(combo) combos[#combos + 1] = combo return true end },
			["core.events.loop"] = { sleep_ms = function() return true end },
		}, function()
			with_recorded_shell(function(commands)
				Gestures.execute_action("make_executable_selection", "tap_3")
				local run = launched(commands)
				helpers.assert_eq(unwrap(run[1]), "chmod +x '/home/ana/run.sh' '/home/ana/it'\\''s here.sh'")
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
				["modules.shortcuts.open_selection"] = { capture_file_manager = function() return function() return true end end },
				["adapters.clipboard"] = {
					read_selection_uri_list = function() return report[1], report[2], report[3] end,
				},
				["modules.gestures.combo_emitter"] = { press = function() return true end },
				["core.events.loop"] = { sleep_ms = function() return true end },
				["adapters.application_notifier"] = { send = function() return true end },
			}, function()
				with_recorded_shell(function(commands)
					Gestures.execute_action("make_executable_selection", "tap_3")
					helpers.assert_eq(#launched(commands), 0)
				end)
			end)
		end
	end)

	for _, response in ipairs({ "exit 1", 'printf "unknown"' }) do
		helpers.it("does not change desktop visibility after an unreadable query (" .. response .. ")", function()
			local log = run_with_stubs(backgrounded(Gestures, "show_desktop"), {
				wmctrl = 'if [ "$1" = -m ]; then ' .. response .. '; fi',
			})
			helpers.assert_true(not log:find("wmctrl -k", 1, true), "unobserved state must not be changed: " .. log)
		end)
	end

	for _, vector in ipairs({ { "ON", "off" }, { "OFF", "on" } }) do
		helpers.it("toggles observed desktop visibility " .. vector[1], function()
			local log = run_with_stubs(backgrounded(Gestures, "show_desktop"), {
				wmctrl = 'if [ "$1" = -m ]; then printf "%s\\n" "showing the desktop mode: ' .. vector[1] .. '"; fi',
			})
			helpers.assert_true(log:find("wmctrl -k " .. vector[2], 1, true) ~= nil, log)
		end)
	end

	for _, response in ipairs({ "exit 1", 'printf "unexpected"' }) do
		helpers.it("does not change the colour scheme after an unreadable setting (" .. response .. ")", function()
			local log = run_with_stubs(backgrounded(Gestures, "toggle_dark_mode"), {
				gsettings = 'if [ "$1" = get ]; then ' .. response .. '; fi',
			})
			helpers.assert_true(not log:find("gsettings set", 1, true), "unobserved state must not be changed: " .. log)
		end)
	end

	for _, vector in ipairs({ { "default", "prefer-dark" }, { "prefer-light", "prefer-dark" }, { "prefer-dark", "default" } }) do
		helpers.it("toggles the observed " .. vector[1] .. " colour scheme", function()
			local log = run_with_stubs(backgrounded(Gestures, "toggle_dark_mode"), {
				gsettings = 'if [ "$1" = get ]; then printf "\\047%s\\047\\n" "' .. vector[1] .. '"; fi',
			})
			helpers.assert_true(log:find("gsettings set org.gnome.desktop.interface color-scheme " .. vector[2], 1, true) ~= nil, log)
		end)
	end

	helpers.it("minimize_all minimizes every listed window but the sticky ones (action-parity-linux-system)", function()
		local log = run_with_stubs(backgrounded(Gestures, "minimize_all"), {
			wmctrl = 'printf "%s\\n" "0x01 0 host Editor" "0x02 -1 host Panel" "0x03 1 host Browser"',
			xdotool = ":",
		})
		helpers.assert_eq(log, "wmctrl -l\nxdotool windowminimize 0x01\nxdotool windowminimize 0x03\n")
	end)

	helpers.it("eject_all_disks powers off the removable disks, never the system's own (action-parity-linux-system)",
		function()
			-- sda: the internal disk. sdb: a USB key with one mounted partition and
			-- one that is not. sdc: a hot-plugged disk the system runs from.
			-- sdd: a removable disk with a space in its mount point. sr0: a rom.
			local lsblk = table.concat({
				'case "$*" in',
				'  "-nrpo NAME,TYPE,RM,HOTPLUG") printf "%s\\n" "/dev/sda disk 0 0" "/dev/sda1 part 0 0"'
					.. ' "/dev/sdb disk 1 1" "/dev/sdb1 part 1 1" "/dev/sdc disk 0 1" "/dev/sdd disk 1 0" "/dev/sr0 rom 1 0";;',
				'  "-nrpo MOUNTPOINT /dev/sdb") printf "%s\\n" "" "/media/ana/KEY" "";;',
				'  "-nrpo MOUNTPOINT /dev/sdc") printf "%s\\n" "" "/boot/efi" "/";;',
				'  "-nrpo MOUNTPOINT /dev/sdd") printf "%s\\n" "/media/ana/My\\\\x20Disk";;',
				'  "-nrpo NAME,MOUNTPOINT /dev/sdb") printf "%s\\n" "/dev/sdb " "/dev/sdb1 /media/ana/KEY" "/dev/sdb2 ";;',
				'  "-nrpo NAME,MOUNTPOINT /dev/sdd") printf "%s\\n" "/dev/sdd /media/ana/My\\\\x20Disk";;',
				"esac",
			}, "\n")
			local log = run_with_stubs(backgrounded(Gestures, "eject_all_disks"), { lsblk = lsblk, udisksctl = ":" })
			local calls = {}
			for line in log:gmatch("[^\n]+") do
				if line:find("^udisksctl") then calls[#calls + 1] = line end
			end
			helpers.assert_eq(calls, {
				"udisksctl unmount -b /dev/sdb1",
				"udisksctl power-off -b /dev/sdb",
				"udisksctl unmount -b /dev/sdd",
				"udisksctl power-off -b /dev/sdd",
			})
		end)

	for _, fault in ipairs({ "mount query", "partition query", "unmount" }) do
		helpers.it("does not power off a disk after " .. fault .. " fails", function()
			local lsblk = table.concat({
				'case "$*" in',
				'  "-nrpo NAME,TYPE,RM,HOTPLUG") printf "%s\\n" "/dev/sdb disk 1 1";;',
				'  "-nrpo MOUNTPOINT /dev/sdb") ' .. (fault == "mount query" and "exit 1" or 'printf "%s\\n" "/media/ana/KEY"') .. ';;',
				'  "-nrpo NAME,MOUNTPOINT /dev/sdb") ' .. (fault == "partition query" and "exit 1" or 'printf "%s\\n" "/dev/sdb1 /media/ana/KEY"') .. ';;',
				'esac',
			}, "\n")
			local log = run_with_stubs(backgrounded(Gestures, "eject_all_disks"), {
				lsblk = lsblk, udisksctl = fault == "unmount" and 'exit 1' or ':',
			})
			helpers.assert_true(not log:find("udisksctl power%-off"), "unsafe power-off after " .. fault .. ": " .. log)
		end)
	end

	helpers.it("open_emoji_picker chains the installed choosers and logs when there is none (action-parity-linux-system)",
		function()
			local installed = { ibus = true, smile = true }
			local answer = function(command)
				local binary = command:match("command %-v '([^']+)'")
				if binary then return installed[binary] == true end
				return true
			end
			helpers.assert_eq(backgrounded(Gestures, "open_emoji_picker", answer), "{ ibus emoji || smile; }")
			installed = {}
			with_recorded_shell(function(commands)
				Gestures.execute_action("open_emoji_picker", "tap_3")
				helpers.assert_eq(#launched(commands), 0, "no chooser installed: nothing is started")
			end, answer)
		end)

	helpers.it("pick_color runs the picker of the session it is in (action-parity-linux-system)", function()
		local real_getenv = os.getenv
		local wayland = nil
		os.getenv = function(name)
			if name == "WAYLAND_DISPLAY" then return wayland end
			return real_getenv(name)
		end
		local answer = function(command)
			if command:find("command -v", 1, true) then return true end
			return true
		end
		local ok, err = pcall(function()
			helpers.assert_eq(backgrounded(Gestures, "pick_color", answer),
				'{ xcolor --selection clipboard || { colour=$(gpick --single --output --no-newline) && [ -n "$colour" ] && printf "%s" "$colour" | xclip -selection clipboard; }; }')
			wayland = "wayland-0"
			helpers.assert_eq(backgrounded(Gestures, "pick_color", answer), "{ hyprpicker --autocopy --format=hex; }")
		end)
		os.getenv = real_getenv
		if not ok then error(err, 0) end
	end)

	for _, gpick in ipairs({ "exit 1", "exit 0" }) do
		helpers.it("keeps the clipboard when the X11 colour picker produces no colour (" .. gpick .. ")", function()
			local old_getenv = os.getenv
			os.getenv = function(name) if name == "WAYLAND_DISPLAY" then return "" end; return old_getenv(name) end
			local ok, err = pcall(function()
				local command = backgrounded(Gestures, "pick_color", function() return true end)
				local log, dir = run_with_stubs(command, { xcolor = "exit 1", gpick = gpick,
					xclip = 'cat > "$STUBS/clipboard"' })
				helpers.assert_nil(io.open(dir .. "/clipboard", "rb"), "no colour must preserve clipboard: " .. log)
			end)
			os.getenv = old_getenv
			if not ok then error(err, 0) end
		end)
	end

	helpers.it("copies a colour produced by the X11 fallback picker", function()
		local old_getenv = os.getenv
		os.getenv = function(name) if name == "WAYLAND_DISPLAY" then return "" end; return old_getenv(name) end
		local ok, err = pcall(function()
			local command = backgrounded(Gestures, "pick_color", function() return true end)
			local _, dir = run_with_stubs(command, { xcolor = "exit 1", gpick = 'printf "#aabbcc"',
				xclip = 'cat > "$STUBS/clipboard"' })
			local file = assert(io.open(dir .. "/clipboard", "rb"))
			helpers.assert_eq(file:read("*a"), "#aabbcc")
			file:close()
		end)
		os.getenv = old_getenv
		if not ok then error(err, 0) end
	end)

	for _, action in ipairs({ "screenshot_fullscreen_clipboard", "screenshot_region_clipboard" }) do
		helpers.it("falls back without writing an empty clipboard when grim fails (" .. action .. ")", function()
			local log, dir = run_with_stubs(backgrounded(Gestures, action), {
				grim = "exit 1", slurp = 'echo "10,10 50x20"',
				["wl-copy"] = 'cat > "$STUBS/clipboard"',
				["gnome-screenshot"] = "exit 0", spectacle = "exit 1", maim = "exit 1",
			})
			helpers.assert_nil(io.open(dir .. "/clipboard", "r"), "failed grim cannot replace the clipboard: " .. log)
			helpers.assert_true(log:find("gnome%-screenshot") ~= nil, "next capture tool must run: " .. log)
		end)
	end

	for _, action in ipairs({ "screenshot_fullscreen_clipboard", "screenshot_region_clipboard" }) do
		helpers.it("copies a successful PNG and cleans its private temporary file (" .. action .. ")", function()
			local command = 'TMPDIR="$STUBS"; export TMPDIR; ' .. backgrounded(Gestures, action)
			local log, dir = run_with_stubs(command, {
				grim = 'for last; do :; done; printf PNG > "$last"',
				slurp = 'echo "10,10 50x20"', ["wl-copy"] = 'cat > "$STUBS/clipboard"',
				["gnome-screenshot"] = "exit 1", spectacle = "exit 1", maim = "exit 1",
			})
			local clip = assert(io.open(dir .. "/clipboard", "rb"))
			helpers.assert_eq(clip:read("*a"), "PNG")
			clip:close()
			helpers.assert_true(not log:find("gnome%-screenshot"), "success stops the cascade")
			local stream = assert(io.popen("find '" .. dir .. "' -name '*.png' -print"))
			helpers.assert_eq(stream:read("*a"), "", "the staged PNG is removed")
			stream:close()
		end)
	end

	for _, signal in ipairs({ "HUP", "INT", "TERM" }) do
		helpers.it("removes the staged screenshot when its shell receives SIG" .. signal, function()
			local command = 'TMPDIR="$STUBS"; export TMPDIR; ' .. backgrounded(Gestures, "screenshot_fullscreen_clipboard")
			local log, dir = run_with_stubs(command, {
				grim = 'for last; do :; done; printf PNG > "$last"; kill -' .. signal .. ' "$PPID"; exit 0',
				["wl-copy"] = 'cat > "$STUBS/clipboard"', ["gnome-screenshot"] = "exit 1",
				spectacle = "exit 1", maim = "exit 1",
			})
			local stream = assert(io.popen("find '" .. dir .. "' -name 'ergopti-screenshot.*' -print"))
			helpers.assert_eq(stream:read("*a"), "", "the private capture directory must be removed: " .. log)
			stream:close()
		end)
	end

	helpers.it("two saved window captures in the same second retain both images", function()
		local target = os.tmpname()
		os.remove(target)
		local executed = os.execute("mkdir '" .. target .. "'"); assert(executed == true or executed == 0)
		local old_getenv, old_date = os.getenv, os.date
		os.getenv = function(key) if key == "XDG_PICTURES_DIR" then return target end; return old_getenv(key) end
		os.date = function() return "2026-11-04_16-00-00" end
		local ok, err = pcall(function()
			local cmd = backgrounded(Gestures, "screenshot_window_save")
			run_with_stubs(cmd .. " & " .. cmd .. " & wait", {
				["gnome-screenshot"] = 'printf PNG > "$2"',
			})
			local pipe = assert(io.popen("find '" .. target .. "' -type f | wc -l"))
			local count = tonumber(pipe:read("*l"))
			pipe:close()
			helpers.assert_eq(count, 2, "both screenshots must remain")
		end)
		os.getenv, os.date = old_getenv, old_date
		os.execute("rm -rf '" .. target .. "'")
		if not ok then error(err, 0) end
	end)

	helpers.it("removes an incomplete reserved screenshot after all capture tools fail", function()
		local target = os.tmpname()
		os.remove(target)
		local executed = os.execute("mkdir '" .. target .. "'"); assert(executed == true or executed == 0)
		local old_getenv = os.getenv
		os.getenv = function(key) if key == "XDG_PICTURES_DIR" then return target end; return old_getenv(key) end
		local ok, err = pcall(function()
			local command = backgrounded(Gestures, "screenshot_window_save")
			run_with_stubs(command, {
				["gnome-screenshot"] = 'printf partial > "$2"; exit 1',
				spectacle = "exit 1", maim = "exit 1", xdotool = "exit 1",
			})
			local pipe = assert(io.popen("find '" .. target .. "' -mindepth 1 -print"))
			helpers.assert_eq(pipe:read("*a"), "", "failed capture leaves no reserved artifact")
			pipe:close()
		end)
		os.getenv = old_getenv
		os.execute("rm -rf '" .. target .. "'")
		if not ok then error(err, 0) end
	end)

	for _, variant in ipairs({ "empty-success", "partial-failure" }) do
		helpers.it("saved screenshots continue after " .. variant .. " from the first tool", function()
			local target = os.tmpname()
			os.remove(target)
			local executed = os.execute("mkdir '" .. target .. "'"); assert(executed == true or executed == 0)
			local old_getenv = os.getenv
			os.getenv = function(key) if key == "XDG_PICTURES_DIR" then return target end; return old_getenv(key) end
			local ok, err = pcall(function()
				local command = backgrounded(Gestures, "screenshot_fullscreen_save")
				local log = run_with_stubs(command, {
					grim = variant == "empty-success" and "exit 0" or 'printf partial > "$1"; exit 1',
					["gnome-screenshot"] = 'printf GOOD > "$2"', spectacle = "exit 1", maim = "exit 1",
				})
				helpers.assert_true(log:find("gnome%-screenshot") ~= nil, "fallback must run: " .. log)
				local pipe = assert(io.popen("cat '" .. target .. "'/*.png 2>/dev/null"))
				helpers.assert_eq(pipe:read("*a"), "GOOD")
				pipe:close()
			end)
			os.getenv = old_getenv
			os.execute("rm -rf '" .. target .. "'")
			if not ok then error(err, 0) end
		end)
	end

	helpers.it("does not retain an earlier failed tool's partial screenshot", function()
		local target = os.tmpname()
		os.remove(target)
		local executed = os.execute("mkdir '" .. target .. "'"); assert(executed == true or executed == 0)
		local old_getenv = os.getenv
		os.getenv = function(key) if key == "XDG_PICTURES_DIR" then return target end; return old_getenv(key) end
		local ok, err = pcall(function()
			local command = backgrounded(Gestures, "screenshot_fullscreen_save")
			run_with_stubs(command, { grim = 'printf partial > "$1"; exit 1',
				["gnome-screenshot"] = "exit 0", spectacle = "exit 1", maim = "exit 1" })
			local pipe = assert(io.popen("find '" .. target .. "' -mindepth 1 -print"))
			helpers.assert_eq(pipe:read("*a"), "", "partial data cannot masquerade as a later success")
			pipe:close()
		end)
		os.getenv = old_getenv
		os.execute("rm -rf '" .. target .. "'")
		if not ok then error(err, 0) end
	end)

	helpers.it("screen_capture_instant saves the active window like screenshot_window_save (action-parity-linux-system)",
		function()
			local instant = backgrounded(Gestures, "screen_capture_instant")
			helpers.assert_true(instant:find('gnome-screenshot -wf "$f"', 1, true) ~= nil, instant)
			helpers.assert_true(instant:find("/ergopti_win_", 1, true) ~= nil, "a window capture file name: " .. instant)
		end)

	helpers.it("ocr_screenshot puts the text of the drawn region on the clipboard (action-parity-linux-system)", function()
		local log, dir = run_with_stubs(backgrounded(Gestures, "ocr_screenshot"), {
			slurp = 'echo "10,10 50x20"',
			grim = 'for last; do :; done; printf png > "$last"',
			tesseract = 'case "$1" in --list-langs) printf "%s\\n" "List of available languages:" eng fra osd;;'
				.. ' *) printf "Bonjour"; esac',
			["wl-copy"] = 'cat > "$STUBS/clipboard"',
		})
		local clip_fh = io.open(dir .. "/clipboard", "r")
		local clip = clip_fh and clip_fh:read("*a")
		if clip_fh then clip_fh:close() end
		helpers.assert_eq(clip, "Bonjour", "the recognised text reaches the clipboard; calls: " .. log)
		helpers.assert_true(log:find("tesseract /[^ ]+%.png %- %-l eng%+fra\n") ~= nil,
			"tesseract reads the capture in every installed language but osd: " .. log)
		local leftover = io.popen("ls '" .. dir .. "' | grep -c png$"):read("*l")
		helpers.assert_true(log:find("grim %-g 10,10 50x20 /") ~= nil, "the drawn region is captured: " .. log)
		helpers.assert_eq(leftover, "0", "the temporary capture is removed")
	end)

	helpers.it("keeps the clipboard when OCR finds no text", function()
		local log, dir = run_with_stubs(backgrounded(Gestures, "ocr_screenshot"), {
			slurp = 'echo "10,10 50x20"',
			grim = 'for last; do :; done; printf PNG > "$last"',
			tesseract = 'case "$1" in --list-langs) printf "List:\neng\n";; *) exit 0;; esac',
			["wl-copy"] = 'cat > "$STUBS/clipboard"',
		})
		helpers.assert_nil(io.open(dir .. "/clipboard", "rb"), "empty OCR must not clear the clipboard: " .. log)
	end)

	for _, signal in ipairs({ "HUP", "INT", "TERM" }) do
		helpers.it("cleans the private OCR image on SIG" .. signal, function()
			local command = 'TMPDIR="$STUBS"; export TMPDIR; ' .. backgrounded(Gestures, "ocr_screenshot")
			local log, dir = run_with_stubs(command, {
				slurp = 'echo "10,10 50x20"',
				grim = 'for last; do :; done; printf PNG > "$last"; kill -' .. signal .. ' "$PPID"; exit 0',
				tesseract = 'printf text', ["wl-copy"] = 'cat > "$STUBS/clipboard"',
			})
			local pipe = assert(io.popen("find '" .. dir .. "' -name 'ergopti-ocr.*' -print"))
			helpers.assert_eq(pipe:read("*a"), "", "OCR capture directory must be removed on signal: " .. log)
			pipe:close()
		end)
	end

	helpers.it("ocr_screenshot leaves the clipboard alone when the selection is cancelled (action-parity-linux-system)",
		function()
			local log, dir = run_with_stubs(backgrounded(Gestures, "ocr_screenshot"), {
				slurp = "exit 1",
				grim = "exit 1",
				tesseract = 'printf "x"',
				["wl-copy"] = 'cat > "$STUBS/clipboard"',
			})
			helpers.assert_nil(io.open(dir .. "/clipboard", "r"), "nothing reached the clipboard: " .. log)
			helpers.assert_true(not log:find("tesseract", 1, true), "nothing was read: " .. log)
		end)

	-- Two accepted toggles background two shells. Unserialized, both read the
	-- old state before either writes, so both write the same new state and one
	-- toggle is lost. The stubs widen that window with a slow read.
	local TOGGLES = {
		toggle_dark_mode = {
			stub = "gsettings",
			body = 'if [ "$1" = get ]; then v=$(cat "$STUBS/state"); sleep 0.3; printf "\'%s\'\\n" "$v";'
				.. ' else printf "%s" "$4" > "$STUBS/state"; fi',
			initial = "default", once = "prefer-dark",
		},
		show_desktop = {
			stub = "wmctrl",
			body = 'if [ "$1" = -m ]; then v=$(cat "$STUBS/state"); sleep 0.3; printf "Name: stub\\n'
				.. 'Window manager\'s \\"showing the desktop\\" mode: %s\\n" "$v";'
				.. ' else case "$2" in on) printf ON;; off) printf OFF;; esac > "$STUBS/state"; fi',
			initial = "OFF", once = "ON",
		},
	}
	for action, toggle in pairs(TOGGLES) do
		helpers.it(action .. ": overlapping toggles both apply (toggle-serialized-lds-002)", function()
			local command = backgrounded(Gestures, action)
			local function run(times)
				local jobs = {}
				for index = 1, times do jobs[index] = "( " .. command .. " ) &" end
				local script = 'printf "%s" ' .. toggle.initial .. ' > "$STUBS/state"\n'
					.. 'export XDG_RUNTIME_DIR="$STUBS"\nmkdir -p "$STUBS/ergopti"\n'
					.. table.concat(jobs, "\n") .. "\nwait"
				local log, dir = run_with_stubs(script, { [toggle.stub] = toggle.body })
				local fh = io.open(dir .. "/state", "r")
				local state = fh and fh:read("*a")
				if fh then fh:close() end
				os.execute("rm -rf '" .. dir .. "'")
				return state, log
			end
			local once = run(1)
			helpers.assert_eq(once, toggle.once, "one toggle flips the state")
			local twice, log = run(2)
			helpers.assert_eq(twice, toggle.initial, "two overlapping toggles flip it back; calls: " .. log)
		end)
	end

	-- The shell that backgrounds a command answers at once. Its refusal (no
	-- fork, no shell, status 126 under either os.execute ABI, or a raise) was
	-- dropped by an ignored pcall, so the action failed with no line logged.
	helpers.it("a refused background shell is logged, a started one is not (background-acquisition-lds-001)",
		function()
			local errors = {}
			local logger = helpers.make_logger_stub()
			logger.error = function(_, format, ...) errors[#errors + 1] = string.format(format, ...) end
			local cached = package.loaded["modules.gestures.manager"]
			local cached_runner = package.loaded["modules.gestures.background_commands"]
			package.loaded["modules.gestures.background_commands"] = nil
			local ok, failure = pcall(function()
				local Fresh = helpers.load_module_with_dependency("modules.gestures.manager", "core.logger.engine.shim", logger)
				local real = os.execute
				local function dispatch(answer)
					errors = {}
					os.execute = answer
					local called, raised = pcall(Fresh.execute_action, "mic_mute_toggle", "tap_3")
					os.execute = real
					if not called then error(raised, 0) end
					return #errors
				end
				helpers.assert_eq(dispatch(function() return true end), 0, "Lua 5.2+ success logs nothing")
				helpers.assert_eq(dispatch(function() return 0 end), 0, "LuaJIT success logs nothing")
				helpers.assert_eq(dispatch(function() return nil, "exit", 126 end), 1, "Lua 5.2+ refusal is logged")
				helpers.assert_eq(dispatch(function() return 126 * 256 end), 1, "LuaJIT refusal is logged")
				helpers.assert_eq(dispatch(function() error("fork refused") end), 1, "a raise is logged")
				helpers.assert_true(not errors[1]:find("pactl", 1, true), "the command is never logged: " .. errors[1])
			end)
			package.loaded["modules.gestures.manager"] = cached
			package.loaded["modules.gestures.background_commands"] = cached_runner
			if not ok then error(failure, 0) end
		end)
end)
