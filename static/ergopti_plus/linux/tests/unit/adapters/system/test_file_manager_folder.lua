--- tests/unit/adapters/system/test_file_manager_folder.lua

--- ==============================================================================
--- MODULE: Active File Manager Folder Tests (Linux)
--- DESCRIPTION:
--- Drives core/fs/adapters/file_manager_folder.lua with the exact xprop and gdbus
--- answers a real Nautilus 46 gave in a headless X11 session (Xvfb, Openbox,
--- a D-Bus session bus), and with the answers of the cases it must refuse.
---
--- ROOT CAUSES ENCODED:
--- 1. open_terminal_here and new_text_file_here had no Linux folder owner:
---    the folder must come from the active window's own file manager, read on
---    that process's unique bus name, never from the well-known name another
---    file manager (Thunar) may own.
--- 2. Nautilus lists every tab of a window and never says which one is active:
---    tabs on different folders are ambiguous and refused.
--- 3. A trash:///, starred:/// or sftp:// location is not a local folder and
---    must never become the home folder.
--- 4. A focus change or a navigation between the two reads is refused.
--- 5. Thunar and Dolphin publish no active folder: refused by name.
--- ==============================================================================

local helpers = require("tests.helpers")

local Folder = require("core.fs.adapters.file_manager_folder")

-- Recorded from Nautilus 46.4 under Xvfb and Openbox (2026-11-10).
local NAUTILUS_PROPS = table.concat({
	'_GTK_APPLICATION_ID = "org.gnome.Nautilus"',
	'_GTK_UNIQUE_BUS_NAME = ":1.9"',
	'_GTK_WINDOW_OBJECT_PATH = "/org/gnome/Nautilus/window/1"',
	'WM_CLASS = "org.gnome.Nautilus", "org.gnome.Nautilus"',
}, "\n") .. "\n"
local THUNAR_PROPS = table.concat({
	'_GTK_APPLICATION_ID = "org.xfce.Thunar"',
	'_GTK_UNIQUE_BUS_NAME = ":1.0"',
	"_GTK_WINDOW_OBJECT_PATH:  not found.",
	'WM_CLASS = "thunar", "Thunar"',
}, "\n") .. "\n"
local DOLPHIN_PROPS = table.concat({
	"_GTK_APPLICATION_ID:  not found.",
	"_GTK_UNIQUE_BUS_NAME:  not found.",
	"_GTK_WINDOW_OBJECT_PATH:  not found.",
	'WM_CLASS = "dolphin", "dolphin"',
}, "\n") .. "\n"
local TERMINAL_PROPS = '_GTK_APPLICATION_ID = "org.gnome.Terminal"\nWM_CLASS = "gnome-terminal-server", "Gnome-terminal"\n'

local function locations(body)
	return "(<{'/org/gnome/Nautilus/window/1': [" .. body .. "]}>,)\n"
end

--- Installs a scripted desktop: each read returns the next state.
--- @param states table List of { xid, props, locations }; the last repeats.
--- @return table calls Every command run.
local function scripted(states, overrides)
	local calls, reads = {}, 0
	local function state() return states[math.min(reads, #states)] end
	Folder._set_deps({
		exec = function(command)
			calls[#calls + 1] = command
			if command:find("^xdotool getactivewindow") then
				reads = reads + 1
				return state().xid and (state().xid .. "\n") or nil
			end
			if command:find("^xprop ") then return state().props end
			if command:find("^gdbus call ") then return state().locations end
			error("unexpected command " .. command)
		end,
		has_command = function() return true end,
		is_directory = (overrides and overrides.is_directory) or function() return true end,
		is_x11 = function() return true end,
	})
	return calls
end

helpers.describe("Linux file manager folder owner", function()
	helpers.it("parses Nautilus's OpenWindowsWithLocations in tab order", function()
		helpers.assert_eq(Folder.parse_windows_with_locations(
			"(<{'/org/gnome/Nautilus/window/1': ['file:///home/fmtest/a', 'file:///home/fmtest/b']}>,)"),
			{ ["/org/gnome/Nautilus/window/1"] = { "file:///home/fmtest/a", "file:///home/fmtest/b" } })
		helpers.assert_eq(Folder.parse_windows_with_locations("(<@a{sas} {}>,)"), {})
		helpers.assert_eq(Folder.parse_windows_with_locations(
			"(<{'/w/1': @as [], '/w/2': [\"file:///it's\"]}>,)"), { ["/w/1"] = {}, ["/w/2"] = { "file:///it's" } })
		helpers.assert_eq(Folder.parse_windows_with_locations("(<{'/w/1': ['file:///a\\'b']}>,)"),
			{ ["/w/1"] = { "file:///a'b" } })
	end)

	helpers.it("encodes a folder as a file URI the GVariant quoting never has to escape", function()
		helpers.assert_eq(Folder.file_uri("/home/ann/Docs"), "file:///home/ann/Docs")
		helpers.assert_eq(Folder.file_uri("/tmp/l'été & co/"), "file:///tmp/l%27%C3%A9t%C3%A9%20%26%20co/")
		local FileSelection = require("core.fs.engine.file_selection")
		helpers.assert_eq(FileSelection.parse_uri_list(Folder.file_uri("/tmp/a b'c")), { "/tmp/a b'c" })
	end)

	helpers.it("refuses malformed or unexpected GVariant text", function()
		for _, text in ipairs({
			"", "()", "(<{'/w/1': ['file:///a']>,)", "(<{'/w/1': ['file:///a'}>,)",
			"(<{'/w/1': ['file:///\\u00e9']}>,)", "(<{'/w/1': ['a'], '/w/1': ['b']}>,)",
			"(<{'/w/1': ['a']} junk>,)",
		}) do
			helpers.assert_nil(Folder.parse_windows_with_locations(text), text)
		end
	end)

	helpers.it("reads the active Nautilus window's folder from its own unique bus", function()
		local calls = scripted({ { xid = "8388612", props = NAUTILUS_PROPS,
			locations = locations("'file:///home/ana/My%20files'") } })
		local folder, reason = Folder.read_active_folder()
		Folder._reset_deps()
		helpers.assert_nil(reason)
		helpers.assert_eq(folder.path, "/home/ana/My files")
		helpers.assert_eq(folder.bus, ":1.9")
		helpers.assert_eq(folder.window_path, "/org/gnome/Nautilus/window/1")
		local queried = 0
		for _, command in ipairs(calls) do
			if command:find("^gdbus call ") then
				queried = queried + 1
				helpers.assert_true(command:find("--dest ':1.9'", 1, true) ~= nil, command)
				helpers.assert_true(command:find("--dest org.freedesktop.FileManager1", 1, true) == nil, command)
			end
		end
		helpers.assert_eq(queried, 2, "the window and its folder are read twice")
	end)

	helpers.it("admits several tabs on one folder and refuses tabs on different folders", function()
		scripted({ { xid = "7", props = NAUTILUS_PROPS,
			locations = locations("'file:///home/ana/a', 'file:///home/ana/a'") } })
		local folder = Folder.read_active_folder()
		helpers.assert_eq(folder.path, "/home/ana/a")
		scripted({ { xid = "7", props = NAUTILUS_PROPS,
			locations = locations("'file:///home/ana/a', 'file:///home/ana/b'") } })
		local none, reason = Folder.read_active_folder()
		Folder._reset_deps()
		helpers.assert_nil(none)
		helpers.assert_eq(reason, "ambiguous_tabs")
	end)

	helpers.it("refuses a location that is not a local folder, never the home folder", function()
		for _, uri in ipairs({ "trash:///", "starred:///", "sftp://host/home/ana", "file://host/home/ana" }) do
			scripted({ { xid = "7", props = NAUTILUS_PROPS, locations = locations("'" .. uri .. "'") } })
			local folder, reason = Folder.read_active_folder()
			helpers.assert_nil(folder, uri)
			helpers.assert_eq(reason, "not_local", uri)
		end
		scripted({ { xid = "7", props = NAUTILUS_PROPS, locations = locations("'file:///gone'") } },
			{ is_directory = function() return false end })
		local _, reason = Folder.read_active_folder()
		Folder._reset_deps()
		helpers.assert_eq(reason, "not_directory")
	end)

	helpers.it("refuses a focus change or a navigation between the two reads", function()
		scripted({
			{ xid = "7", props = NAUTILUS_PROPS, locations = locations("'file:///home/ana/a'") },
			{ xid = "9", props = TERMINAL_PROPS },
		})
		local _, reason = Folder.read_active_folder()
		helpers.assert_eq(reason, "focus_changed")
		scripted({
			{ xid = "7", props = NAUTILUS_PROPS, locations = locations("'file:///home/ana/a'") },
			{ xid = "7", props = NAUTILUS_PROPS, locations = locations("'file:///home/ana/b'") },
		})
		_, reason = Folder.read_active_folder()
		helpers.assert_eq(reason, "focus_changed")
		scripted({
			{ xid = "7", props = NAUTILUS_PROPS, locations = locations("'file:///home/ana/a'") },
			{ xid = nil },
		})
		_, reason = Folder.read_active_folder()
		Folder._reset_deps()
		helpers.assert_eq(reason, "focus_changed")
	end)

	helpers.it("names Thunar and Dolphin, which publish no active folder", function()
		for name, props in pairs({ Thunar = THUNAR_PROPS, Dolphin = DOLPHIN_PROPS }) do
			local calls = scripted({ { xid = "7", props = props } })
			local folder, reason, detail = Folder.read_active_folder()
			helpers.assert_nil(folder)
			helpers.assert_eq(reason, "unsupported_file_manager")
			helpers.assert_eq(detail, name)
			for _, command in ipairs(calls) do
				helpers.assert_true(command:find("^gdbus") == nil, "no D-Bus guess for " .. name)
			end
		end
		scripted({ { xid = "7", props = TERMINAL_PROPS } })
		local _, reason = Folder.read_active_folder()
		helpers.assert_eq(reason, "not_file_manager")
		scripted({ { xid = nil } })
		_, reason = Folder.read_active_folder()
		Folder._reset_deps()
		helpers.assert_eq(reason, "no_window")
	end)

	helpers.it("refuses a window Nautilus does not list", function()
		scripted({ { xid = "7", props = NAUTILUS_PROPS,
			locations = "(<{'/org/gnome/Nautilus/window/2': ['file:///home/ana']}>,)" } })
		local _, reason = Folder.read_active_folder()
		Folder._reset_deps()
		helpers.assert_eq(reason, "query_failed")
	end)

	helpers.it("reveals through the same Nautilus process with an escaped file URI", function()
		local command = Folder.reveal_command({ bus = ":1.9" }, "/home/ana/l'été/New text file.txt")
		helpers.assert_eq(command, "gdbus call --session --timeout 2 --dest ':1.9'"
			.. " --object-path /org/freedesktop/FileManager1 --method org.freedesktop.FileManager1.ShowItems"
			.. " '['\\''file:///home/ana/l%27%C3%A9t%C3%A9/New%20text%20file.txt'\\'']' ''")
	end)

	helpers.it("is unavailable without X11, a tool or Nautilus", function()
		local function availability(x11, missing)
			Folder._set_deps({ is_x11 = function() return x11 end,
				has_command = function(binary) return binary ~= missing end })
			local ok, why = Folder.available()
			Folder._reset_deps()
			return ok, why
		end
		helpers.assert_eq({ availability(true, nil) }, { true })
		helpers.assert_eq({ availability(false, nil) }, { false, "session:x11" })
		helpers.assert_eq({ availability(true, "gdbus") }, { false, "tool:gdbus" })
		helpers.assert_eq({ availability(true, "nautilus") }, { false, "file_manager" })
	end)
end)
