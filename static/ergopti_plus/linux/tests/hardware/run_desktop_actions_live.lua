--- tests/hardware/run_desktop_actions_live.lua

--- ==============================================================================
--- MODULE: Desktop Actions, Executed for Real
--- DESCRIPTION:
--- Run by run_desktop_actions_live.sh on Xvfb with a private session bus and a
--- throwaway HOME. Each action goes through the gesture manager's public
--- executor (modules/gestures/manager.lua execute_action), the one the
--- gestures and keyboard shortcuts call, and its effect is read back from the
--- desktop itself:
---   1. empty_trash, whose question is cancelled, leaves a real gio trash as
---      it was; confirmed, it empties it (files trashed with `gio trash`);
---   2. center_mouse moves the real X pointer to the centre of its monitor;
---   3. toggle_dark_mode flips the real GSettings color-scheme key, and two
---      overlapping toggles end where they started (LDS-002 serialization).
--- Exit 0 = every check held.
--- ==============================================================================

local uv = require("luv")
local Shell = require("adapters.shell_runner")

for _, program in ipairs({ "gio", "xdotool", "gsettings", "luajit" }) do
	assert(Shell.exec_checked("command -v " .. program), program .. " is required")
end

local checks, failures = 0, 0
local function check(condition, text)
	checks = checks + 1
	if not condition then failures = failures + 1 end
	print((condition and "  ok   " or "  FAIL ") .. text)
	return condition
end

local function output(command)
	local ok, text = Shell.exec_checked(command)
	return ok and type(text) == "string" and text or ""
end

--- Polls until the predicate holds or the deadline passes. The predicate runs
--- shell reads, which drive the loop themselves: never from a callback.
local function settle(predicate, seconds)
	local deadline = uv.hrtime() + seconds * 1e9
	repeat
		uv.run("nowait")
		if predicate() then return true end
		uv.sleep(50)
	until uv.hrtime() > deadline
	return predicate()
end

require("core.i18n.engine.i18n").init()
local Manager = require("modules.gestures.manager")
local BackgroundCommands = require("modules.gestures.background_commands")
-- The daemon defers the result collector through its own event-loop adapter;
-- this host runs a bare luv loop, so it collects in the predicate.
local function idle()
	BackgroundCommands._collect_now()
	return BackgroundCommands.pending_count() == 0
end

print("=== desktop actions, executed for real ===")

-- 1) empty_trash
local trash = (os.getenv("XDG_DATA_HOME") or (os.getenv("HOME") .. "/.local/share")) .. "/Trash/files"
local work = assert(uv.fs_mkdtemp(os.getenv("HOME") .. "/trashed-XXXXXX"))
for index = 1, 3 do
	local fh = assert(io.open(work .. "/file-" .. index .. ".txt", "wb")); fh:write("trashed ", index, "\n"); fh:close()
end
check(Shell.run("gio trash " .. Shell.quote(work .. "/file-1.txt") .. " " .. Shell.quote(work .. "/file-2.txt")
	.. " " .. Shell.quote(work .. "/file-3.txt")), "three files are in the real trash")
local function trashed() return #output("ls -A " .. Shell.quote(trash) .. " 2>/dev/null"):gsub("%s+$", "") end
check(trashed() > 0, "the trash folder holds them")
-- empty_trash asks first (catalogue confirm): its question is the product's
-- own GTK dialog host, answered here as a user would, from the keyboard.
local WindowTitles = require("core.ui.engine.window_titles")
local title = WindowTitles.compose(require("core.i18n.engine.i18n").get("dialog.confirm_action.title"))
-- xdotool search --name does not match this UTF-8 title: compare each
-- visible window's name exactly.
local function answer(keys)
	return Shell.run("(t=" .. Shell.quote(title) .. "; w=; for i in $(seq 120); do"
		.. " for c in $(xdotool search --onlyvisible --name '' 2>/dev/null); do"
		.. " [ \"$(xdotool getwindowname \"$c\" 2>/dev/null)\" = \"$t\" ] && w=$c && break; done;"
		.. " [ -n \"$w\" ] && break; sleep 0.25; done; [ -n \"$w\" ] || exit 1; sleep 1;"
		.. " xdotool windowactivate --sync \"$w\"; xdotool windowfocus --sync \"$w\"; sleep 0.5; xdotool key " .. keys
		.. ") >/dev/null 2>&1 &")
end
answer("Escape")
check(Manager.execute_action("empty_trash", "phys"), "empty_trash is dispatched, its question cancelled")
check(settle(idle, 30) and trashed() > 0, "a cancelled question leaves the trash as it was")
answer("Tab Return")
check(Manager.execute_action("empty_trash", "phys"), "empty_trash is dispatched, its question confirmed")
check(settle(function() return idle() and trashed() == 0 end, 30), "the trash is empty afterwards")

-- 2) center_mouse
Shell.run("xdotool mousemove 7 9")
check(Manager.execute_action("center_mouse", "phys"), "center_mouse is dispatched")
local geometry = output("xdotool getdisplaygeometry")
local width, height = geometry:match("(%d+)%s+(%d+)")
width, height = tonumber(width), tonumber(height)
local function at_centre()
	local x, y = output("xdotool getmouselocation --shell"):match("X=(%d+)%s+Y=(%d+)")
	x, y = tonumber(x), tonumber(y)
	return x ~= nil and width ~= nil and math.abs(x - math.floor(width / 2)) <= 1 and math.abs(y - math.floor(height / 2)) <= 1
end
check(settle(function() return idle() and at_centre() end, 20), "the X pointer sits at the monitor centre: "
	.. output("xdotool getmouselocation --shell"):gsub("\n", " "))

-- 3) toggle_dark_mode
local KEY = "org.gnome.desktop.interface color-scheme"
local function scheme() return output("gsettings get " .. KEY):gsub("%s+$", "") end
Shell.run("gsettings set " .. KEY .. " default")
check(Manager.execute_action("toggle_dark_mode", "phys"), "toggle_dark_mode is dispatched")
check(settle(function() return idle() and scheme() == "'prefer-dark'" end, 20), "the real key reads prefer-dark: " .. scheme())
Manager.execute_action("toggle_dark_mode", "phys")
Manager.execute_action("toggle_dark_mode", "phys")
settle(idle, 20)
check(scheme() == "'prefer-dark'", "two overlapping toggles end where they started: " .. scheme())

print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
