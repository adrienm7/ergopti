--- modules/karabiner/ke_lifecycle.lua

--- ==============================================================================
--- MODULE: Karabiner-Elements Process Lifecycle
--- DESCRIPTION:
--- Manages the Karabiner-Elements process lifecycle: removing it from Login
--- Items, suppressing its GUI after relaunch, and launching or stopping its
--- background daemons without exposing the Preferences window to the user.
---
--- FEATURES & RATIONALE:
--- 1. Login Items Removal: Prevents KE from auto-launching at login so
---    Hammerspoon retains full control over when it starts.
--- 2. GUI Suppressor: Kills any KE window that opens within a grace window
---    after HS init or after a config regeneration, preventing unsolicited
---    Spaces switches and keeping the desktop clean.
--- 3. Headless Launch: Bootstraps only the KE background daemons via
---    launchctl, avoiding the Preferences GUI entirely.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "karabiner"

-- Bootstrap KE via its LaunchAgents. The GUI suppressor watcher handles killing
-- any GUI window that opens — we no longer kill daemons during pause (empty config
-- is deployed instead), so this command runs only when daemons are truly absent.
local KARABINER_OPEN_CMD =
	"PLISTS=$(/usr/bin/find /Library/LaunchAgents -name '*karabiner*' 2>/dev/null);"
	.. " if [ -n \"$PLISTS\" ]; then"
	.. "   echo \"$PLISTS\" | /usr/bin/xargs -I{} /bin/launchctl bootstrap gui/$(/usr/bin/id -u) {} 2>/dev/null;"
	.. " else"
	.. "   open -jg -a 'Karabiner-Elements' 2>/dev/null;"
	.. " fi; true"

-- Fully stops Karabiner-Elements (UI + user-level daemons) so karabiner.json can
-- be replaced safely. Without this, a live KE Preferences window or session_monitor
-- may overwrite our deploy within seconds.
-- launchctl bootout must run first so launchd does not restart the daemons;
-- pkill then cleans up any lingering processes.
local KARABINER_KILL_CMD =
	"/bin/launchctl list"
	.. " | /usr/bin/grep -i karabiner"
	.. " | /usr/bin/awk '{print $3}'"
	.. " | /usr/bin/xargs -I{} /bin/launchctl bootout gui/$(/usr/bin/id -u)/{} 2>/dev/null"
	.. "; /usr/bin/pkill -if karabiner 2>/dev/null; true"

-- karabiner_grabber is a root-level LaunchDaemon that stays running regardless
-- of whether the GUI or session_monitor are alive — using it avoids
-- re-bootstrapping when we killed only the GUI.
local KE_RUNNING_CHECK = "/usr/bin/pgrep -q karabiner_grabber"

-- How long after HS init the startup suppressor stays active.
-- Short enough not to block the user; Login Items launches are nearly immediate.
local KE_SUPPRESS_DURATION_SEC = 5

-- App watcher stored at module level to prevent garbage collection.
local _ke_app_watcher = nil

-- Space ID saved just before the suppressor window opens, used to jump back if
-- KE's GUI causes macOS to switch Spaces before we can kill it.
local _pre_suppress_space = nil

--- Shell command to bootstrap KE daemons — exposed so M.regenerate can relaunch.
M.OPEN_CMD = KARABINER_OPEN_CMD

--- Shell command to fully stop KE — exposed so M.regenerate can stop before deploy.
M.KILL_CMD = KARABINER_KILL_CMD




-- ========================================
-- ========================================
-- ======= 1/ KE Process Management =======
-- ========================================
-- ========================================

--- Removes Karabiner-Elements from macOS Login Items so it never auto-launches.
--- Uses hs.osascript.applescript which runs inside HS's process (already granted
--- Accessibility access) — unlike hs.execute which spawns a shell with no such rights.
--- Takes effect on the next login; harmless if KE is not in Login Items.
function M.remove_ke_from_login_items()
	local ok, _, raw = hs.osascript.applescript(
		'tell application "System Events"\n'
		.. '  set items_found to every login item whose name is "Karabiner-Elements"\n'
		.. '  if (count of items_found) > 0 then\n'
		.. '    delete items_found\n'
		.. '    return "removed"\n'
		.. '  else\n'
		.. '    return "not_found"\n'
		.. '  end if\n'
		.. 'end tell'
	)
	if ok then
		Logger.debug(LOG, "Login Items (System Events): %s.", tostring(raw))
	else
		Logger.debug(LOG, "Login Items removal skipped — no Accessibility access or not found.")
	end
end

--- Quits the Karabiner-Elements GUI app if it is running.
--- The background daemons are NOT affected — they are launchd-managed services.
local function quit_ke_gui()
	local apps = hs.application.applicationsForBundleID("org.pqrs.Karabiner-Elements")
	for _, app in ipairs(apps or {}) do
		app:kill()
		Logger.debug(LOG, "Karabiner-Elements GUI killed.")
	end
	hs.execute(
		"osascript -e 'tell application \"Karabiner-Elements\" to quit' 2>/dev/null"
	)
end

--- Stops the KE GUI suppressor watcher, if active.
--- Called before the user intentionally opens KE so the watcher does not fight them.
function M.stop_gui_suppressor()
	if not _ke_app_watcher then return end
	_ke_app_watcher:stop()
	_ke_app_watcher = nil
	Logger.debug(LOG, "Karabiner-Elements GUI suppressor stopped by user request.")
end

--- Arms the KE GUI suppressor watcher: kills any current GUI window and installs
--- a short-lived watcher that quits any GUI launched within KE_SUPPRESS_DURATION_SEC.
--- Used at Hammerspoon startup and after every regenerate() relaunch — some KE
--- LaunchAgents re-open the Preferences window during bootstrap.
--- Call stop_gui_suppressor() (or open_gui()) to end the window early.
function M.arm_ke_gui_suppressor()
	-- Idempotent: stop any previous watcher so a re-arm always gets a fresh
	-- KE_SUPPRESS_DURATION_SEC window (important when regenerate fires near the
	-- tail end of the startup suppressor's lifetime).
	if _ke_app_watcher then
		_ke_app_watcher:stop()
		_ke_app_watcher = nil
	end

	-- Save the current Space so we can jump back if KE triggers a switch
	pcall(function() _pre_suppress_space = hs.spaces.focusedSpace() end)

	-- Kill any GUI already open (covers HS reload / previous session)
	quit_ke_gui()

	_ke_app_watcher = hs.application.watcher.new(function(name, event, _app)
		if name ~= "Karabiner-Elements" then return end
		-- Only intercept fresh launches (Login Items auto-start). Activated events
		-- are user-initiated (Spotlight, Dock) and must not be suppressed.
		if event == hs.application.watcher.launched then
			Logger.debug(LOG, "Karabiner-Elements GUI appeared during suppression window — quitting…")
			quit_ke_gui()
			-- Self-deactivate immediately after the first kill: the Login Items
			-- launch fires exactly once, so any subsequent open is user-initiated.
			if _ke_app_watcher then
				_ke_app_watcher:stop()
				_ke_app_watcher = nil
			end
			local saved_space = _pre_suppress_space
			_pre_suppress_space = nil
			if saved_space then
				hs.timer.doAfter(0.3, function()
					local ok, cur = pcall(hs.spaces.focusedSpace)
					if ok and cur ~= saved_space then
						Logger.debug(LOG, "Restoring Space after Karabiner-Elements GUI switch.")
						pcall(hs.spaces.gotoSpace, saved_space)
					end
				end)
			end
		end
	end)
	_ke_app_watcher:start()

	-- Auto-stop after the grace period
	hs.timer.doAfter(KE_SUPPRESS_DURATION_SEC, function()
		if _ke_app_watcher then
			_ke_app_watcher:stop()
			_ke_app_watcher = nil
			_pre_suppress_space = nil
			Logger.debug(LOG, "Karabiner-Elements GUI suppressor expired — manual open now allowed.")
		end
	end)

	Logger.debug(LOG, "Karabiner-Elements GUI suppressor active for %ds.", KE_SUPPRESS_DURATION_SEC)
end

--- Opens the Karabiner-Elements GUI for the user.
--- Stops the startup suppressor first so the watcher does not immediately kill the app.
function M.open_gui()
	M.stop_gui_suppressor()
	-- Small delay so the watcher stop propagates before the app launches
	hs.timer.doAfter(0.1, function()
		local ok = pcall(hs.application.launchOrFocus, "Karabiner-Elements")
		if not ok then
			hs.execute("open -a 'Karabiner-Elements' 2>/dev/null")
		end
	end)
	Logger.info(LOG, "Karabiner-Elements GUI opened by user request.")
end

--- Ensures Karabiner-Elements background services are running.
--- Logs a warning if KE cannot be started (app not installed or disabled).
--- @return boolean True if services are (or were already) running after this call.
function M.launch_headless()
	local _, already_running = hs.execute(KE_RUNNING_CHECK)
	if already_running then
		Logger.debug(LOG, "Karabiner-Elements services already running.")
		return true
	end
	Logger.debug(LOG, "Karabiner-Elements not running — bootstrapping daemon plists…")
	hs.execute(KARABINER_OPEN_CMD)

	-- Verify that the daemons actually started after the bootstrap command
	hs.timer.doAfter(3, function()
		local _, now_running = hs.execute(KE_RUNNING_CHECK)
		if not now_running then
			Logger.warn(LOG, "Karabiner-Elements daemons did not start — integration may be unavailable.")
			local ok_notif, notifications = pcall(require, "lib.notifications")
			if ok_notif then
				notifications.notify("⚠️ Karabiner-Elements non disponible — les remappages clavier sont inactifs.")
			end
		end
	end)
	return false
end

return M
