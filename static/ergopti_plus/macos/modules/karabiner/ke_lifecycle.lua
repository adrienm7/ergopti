--- modules/karabiner/ke_lifecycle.lua

--- ==============================================================================
--- MODULE: Karabiner-Elements Process Lifecycle
--- DESCRIPTION:
--- Manages the Karabiner-Elements daemon lifecycle for headless operation.
--- Hammerspoon owns the karabiner.json config and triggers KE to ingest it
--- through a one-shot bridge — the GUI is briefly launched in the background
--- and immediately quit so the user never sees a window or focus change.
---
--- FEATURES & RATIONALE:
--- 1. Per-session priming: KE v15 (Karabiner-Core-Service) does NOT auto-load
---    karabiner.json from disk. The on-disk file is read and pushed to
---    Core-Service via IPC by the user-level GUI app — and only by the GUI.
---    Once Core-Service has received the rules in a given login session, they
---    persist in its memory until logout/reboot, even after the user-facing
---    UI is closed and even across HS reloads. We therefore bootstrap the
---    headless bridge daemon only (no app window, no Space switch).
---    Idempotent across HS reloads via a boot-timestamp marker file in /tmp.
--- 2. Honest status: is_remapping_active() requires both the daemon to be
---    detectable AND the bridge to have been primed in this boot session.
---    The menu's green dot is a real guarantee that remapping is applied,
---    not just that some KE process happens to be running.
--- 3. Stop: bootout removes legacy user-level agents (observer, session_monitor)
---    on feature disable. The root daemon is left untouched — it is
---    system-managed and shared with any other KE config the user may use.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")
local Notifications = require("lib.notifications")
local i18n   = require("lib.i18n")

local LOG = "karabiner"

-- Detection pattern that catches ANY Karabiner-Elements daemon, regardless of
-- KE version. Pre-v16, the daemon was karabiner_grabber. From v16 (May 2026),
-- the daemon was renamed to Karabiner-Core-Service, and additional helpers
-- may run under different binary names in future releases. Every KE binary
-- lives under /Library/Application Support/org.pqrs/Karabiner-Elements/, so
-- matching that install-path substring is the most version-tolerant signal.
local KE_GRABBER_CHECK = "/usr/bin/pgrep -fq 'org.pqrs/Karabiner-Elements'"

-- Fully stops every user-level Karabiner-Elements process and prevents
-- launchd from respawning the ones it manages. Used on feature disable
-- and at HS shutdown so that quitting Hammerspoon truly stops the
-- remapping (the IPC bridge dies → Core-Service has no rules → input
-- passes through unmodified).
--
-- Order matters: bootout the launchd registrations first (otherwise
-- pkill is undone within milliseconds by KeepAlive=true plists), then
-- pkill any remaining processes that were not launchd-managed.
--
-- The system-level Karabiner-Core-Service and Karabiner-VirtualHIDDevice-
-- Daemon run as root and are NOT touched by this command — we cannot
-- stop them without sudo, and they are harmless when no IPC bridge feeds
-- them rules. Same for the DriverKit system extension.
--
-- The launchd label list is enumerated dynamically (matching karabiner|pqrs
-- in the awk filter) so the same command works across KE versions: v14
-- registered karabiner_observer + karabiner_session_monitor, v15 ships
-- different labels for Karabiner-Menu and friends. Anything user-level
-- that pqrs ships gets booted out.
local KARABINER_KILL_CMD =
	"UID=$(/usr/bin/id -u)"
	.. "; for pass in 1 2 3; do"
	.. "   for label in $(/bin/launchctl list 2>/dev/null"
	.. "                 | /usr/bin/awk '/[Kk]arabiner|pqrs/ {print $3}'); do"
	.. "     /bin/launchctl bootout gui/$UID/$label 2>/dev/null; true;"
	.. "     /bin/launchctl bootout user/$UID/$label 2>/dev/null; true;"
	.. "   done"
	.. "; /usr/bin/pkill -x Karabiner-Menu 2>/dev/null"
	.. "; /usr/bin/pkill -x Karabiner-NotificationWindow 2>/dev/null"
	.. "; /usr/bin/pkill -f 'Karabiner-Elements Non-Privileged Agents v2' 2>/dev/null"
	.. "; /usr/bin/pkill -x Karabiner-Multitouch-Extension 2>/dev/null"
	.. "; /usr/bin/pkill -x Karabiner-Elements 2>/dev/null"
	.. "; /usr/bin/pkill -x Karabiner-EventViewer 2>/dev/null"
	.. "; /usr/bin/pkill -x karabiner_console_user_server 2>/dev/null"
	.. "; /usr/bin/pkill -x org.pqrs.karabiner_console_user_server 2>/dev/null"
	-- Legacy v14 helper names — no-op on v15 but kept for old installs.
	.. "; /usr/bin/pkill -x karabiner_observer 2>/dev/null"
	.. "; /usr/bin/pkill -x karabiner_session_monitor 2>/dev/null"
	.. "; /usr/bin/pkill -x org.pqrs.karabiner_session_monitor 2>/dev/null"
	.. "; /bin/sleep 1"
	.. "; done"
	-- Clear the per-session prime marker so the next HS launch starts
	-- with a clean slate and re-primes from scratch.
	.. "; /bin/rm -f /tmp/ergopti_ke_primed_v2.txt 2>/dev/null"
	.. "; /bin/rm -f /tmp/ergopti_ke_hs_owner_v1.txt 2>/dev/null"
	.. "; true"

-- Lightweight kill used only before a config deploy in regenerate().
-- Uses -f (full path) to match processes regardless of their runtime name:
-- KE v16 renames karabiner_console_user_server to org.pqrs.* so pkill -x misses it.
local KARABINER_KILL_FAST_CMD =
	"/usr/bin/pkill -f 'Karabiner-Elements/bin/karabiner_console_user_server' 2>/dev/null; "
	.. "/usr/bin/pkill -x org.pqrs.karabiner_console_user_server 2>/dev/null; "
	.. "/usr/bin/pkill -f 'Karabiner-Elements/bin/karabiner_session_monitor' 2>/dev/null; "
	.. "/usr/bin/pkill -x org.pqrs.karabiner_session_monitor 2>/dev/null; "
	.. "/usr/bin/pkill -x Karabiner-Menu 2>/dev/null; "
	.. "true"

-- User-validated reset script: this exact flow was confirmed to stop
-- user-level KE processes reliably on this machine.
local KARABINER_KILL_TOTAL_SCRIPT = [[#!/bin/zsh
UID=$(/usr/bin/id -u)
for i in 1 2 3 4 5; do
	for label in $(/bin/launchctl list 2>/dev/null | /usr/bin/awk '/[Kk]arabiner|pqrs/ {print $3}'); do
		/bin/launchctl bootout "gui/$UID/$label" 2>/dev/null || true
		/bin/launchctl bootout "user/$UID/$label" 2>/dev/null || true
	done
	/usr/bin/pkill -f "org.pqrs|karabiner|Karabiner" 2>/dev/null || true
	/usr/bin/pkill -x Karabiner-Menu 2>/dev/null || true
	/usr/bin/pkill -x Karabiner-NotificationWindow 2>/dev/null || true
	/usr/bin/pkill -x Karabiner-Elements 2>/dev/null || true
	/usr/bin/pkill -x Karabiner-EventViewer 2>/dev/null || true
	/usr/bin/pkill -x Karabiner-Multitouch-Extension 2>/dev/null || true
	/usr/bin/pkill -x karabiner_console_user_server 2>/dev/null || true
	/usr/bin/pkill -x karabiner_session_monitor 2>/dev/null || true
	/usr/bin/pkill -x karabiner_observer 2>/dev/null || true
	/usr/bin/pkill -x karabiner_grabber 2>/dev/null || true
	/bin/sleep 1
done
if /usr/bin/sudo -n true 2>/dev/null; then
	for d in org.pqrs.service.daemon.Karabiner-Core-Service org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon; do
		/usr/bin/sudo /bin/launchctl bootout "system/$d" 2>/dev/null || true
	done
	/usr/bin/sudo /usr/bin/pkill -f "Karabiner-Core-Service|Karabiner-VirtualHIDDevice-Daemon|org.pqrs/Karabiner-Elements" 2>/dev/null || true
fi
/usr/bin/pkill -f "org.pqrs|karabiner|Karabiner" 2>/dev/null || true
/bin/rm -f /tmp/ergopti_ke_primed_v2.txt /tmp/ergopti_ke_hs_owner_v1.txt 2>/dev/null || true
exit 0
]]

--- Shell command to fully stop user-level KE agents — exposed for regenerate().
M.KILL_CMD      = KARABINER_KILL_CMD
--- Fast kill (no sleep loops) used only during config deploy — exposed for regenerate().
M.KILL_FAST_CMD = KARABINER_KILL_FAST_CMD

local _last_async_reset_launch_ts = 0

--- Writes the total reset script to a temporary file.
--- @param script_path string Absolute path to the temporary script.
--- @return boolean ok True when the script file has been written.
local function write_total_reset_script(script_path)
	local f = io.open(script_path, "w")
	if not f then
		return false
	end
	f:write(KARABINER_KILL_TOTAL_SCRIPT)
	f:close()
	hs.execute(string.format("/bin/chmod 700 %q", script_path))
	return true
end

--- Runs the user-validated Karabiner total reset script via zsh.
--- @return string output Combined stdout/stderr.
--- @return boolean ok True when command exited with success.
function M.run_total_reset()
	local script_path = "/tmp/ergopti_ke_total_reset.sh"
	if not write_total_reset_script(script_path) then
		return "Unable to create reset script", false
	end
	local out, ok = hs.execute(string.format("/bin/zsh %q 2>&1", script_path))
	hs.execute(string.format("/bin/rm -f %q", script_path))
	return out or "", ok == true
end

--- Starts the total reset script in background and returns immediately.
--- Consecutive calls within a short window are deduplicated.
--- @return string output Launch status message.
--- @return boolean ok True when background launch has been requested.
function M.run_total_reset_async()
	local now = os.time()
	if (now - _last_async_reset_launch_ts) < 5 then
		return "Skipped duplicate async launch", true
	end
	local script_path = string.format("/tmp/ergopti_ke_total_reset_async_%d.sh", now)
	if not write_total_reset_script(script_path) then
		return "Unable to create async reset script", false
	end
	local cmd = string.format("/usr/bin/nohup /bin/zsh %q >/tmp/ergopti_ke_total_reset_async.log 2>&1 </dev/null &", script_path)
	local _, ok = hs.execute(cmd)
	if ok == true then
		_last_async_reset_launch_ts = now
		return string.format("Async reset launched (%s)", script_path), true
	end
	hs.execute(string.format("/bin/rm -f %q", script_path))
	return "Async reset launch failed", false
end


-- Per-session priming: launching Karabiner-Menu causes it to read
-- karabiner.json and push the rules to Core-Service via IPC. Karabiner-Menu
-- maintains the IPC link as long as it runs, so remapping stays alive
-- across HS reloads.
--
-- Headless priming command validated on this setup: start the user-level
-- Karabiner bridge daemon directly (no Dock icon, no app window, no Space switch).
-- This process in turn starts session_monitor and notification agents as needed.
local KE_CONSOLE_USER_SERVER_BIN =
	"/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_console_user_server"

local KE_CLI_BIN =
	"/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"

local KE_PRIME_HEADLESS_CMD =
	string.format("/usr/bin/nohup %q", KE_CONSOLE_USER_SERVER_BIN)
	.. " >/tmp/ke_console_user_server.out 2>/tmp/ke_console_user_server.err </dev/null &"

-- GUI fallback intentionally disabled: the user explicitly requires 100%
-- headless behavior with no app/window activation side-effects.

-- Re-enables any pqrs launchd labels that may have been disabled by an older
-- revision. This self-heals quit/reload failures where KE could no longer
-- restart after the first HS shutdown.
local KE_REENABLE_USER_LABELS_CMD =
	"UID=$(/usr/bin/id -u)"
	.. "; for plist in /Library/LaunchAgents/org.pqrs*.plist \"$HOME\"/Library/LaunchAgents/org.pqrs*.plist; do"
	.. "     [ -e \"$plist\" ] || continue;"
	.. "     label=$(/usr/bin/basename \"$plist\" .plist);"
	.. "     /bin/launchctl enable gui/$UID/$label 2>/dev/null; true;"
	.. "     /bin/launchctl enable user/$UID/$label 2>/dev/null; true;"
	.. "   done"
	.. "; true"

-- Best-effort suppression of Dock-visible KE helpers started by the bridge.
-- Remapping stays active via console_user_server/session_monitor/Core-Service.
local KE_SUPPRESS_DOCK_HELPERS_CMD =
	"UID=$(/usr/bin/id -u)"
	.. "; for label in $(/bin/launchctl list 2>/dev/null"
	.. "                 | /usr/bin/awk '{print $3}'"
	.. "                 | /usr/bin/grep -i karabiner"
	.. "                 | /usr/bin/grep -iv 'console_user_server'"
	.. "                 | /usr/bin/grep -iv 'session_monitor'"
	.. "                 | /usr/bin/grep -iv 'Karabiner-Core-Service'); do"
	.. "   /bin/launchctl bootout gui/$UID/$label 2>/dev/null; true;"
	.. " done"
	.. "; /usr/bin/pkill -x Karabiner-NotificationWindow 2>/dev/null"
	.. "; /usr/bin/pkill -f 'Karabiner-Elements Non-Privileged Agents v2' 2>/dev/null"
	.. "; /usr/bin/pkill -x Karabiner-Menu 2>/dev/null"
	.. "; true"

local DOCK_SUPPRESS_RETRY_COUNT = 6
local DOCK_SUPPRESS_RETRY_INTERVAL_SEC = 0.6

-- Set so macOS never restores prior window/Space state for KE. Without this,
-- launching the GUI can drag focus to whichever Space last hosted a KE
-- window. Idempotent — same value every time. Cosmetic-only: does not
-- affect the IPC bridge or the priming itself.
local KE_PERSISTENCE_OFF_CMD =
	"/usr/bin/defaults write org.pqrs.Karabiner-Elements ApplePersistenceIgnoreState -bool YES"

-- Pgrep pattern that matches the user-facing Karabiner-Elements GUI app
-- specifically (NOT the system Core-Service daemon). Used to skip priming
-- when the user already has the GUI open intentionally.
local KE_GUI_CHECK_CMD = "/usr/bin/pgrep -fq '/Applications/Karabiner-Elements.app/Contents/MacOS/Karabiner-Elements'"

-- Polling constants for bridge-ready detection. Instead of waiting a fixed
-- delay before checking, we poll every INTERVAL up to MAX_ATTEMPTS times
-- so a fast daemon start resolves in ~300 ms instead of always waiting 2 s.
local PRIME_POLL_INTERVAL_SEC = 0.3
local PRIME_POLL_MAX_ATTEMPTS = 45  -- 13.5 s absolute maximum (increased from 9 s for IPC readiness)
local PRIME_FALLBACK_AFTER_ATTEMPTS = 6  -- Informational threshold only (no GUI fallback)
local PRIME_RETRY_HEADLESS_EVERY_ATTEMPTS = 4
local PRIME_MAX_HEADLESS_ATTEMPTS = 3
local PRIME_RULES_PROBE_RETRY_INTERVAL_SEC = 0.3  -- Increased from 0.2 s to give socket more settle time
local PRIME_RULES_PROBE_RETRY_ATTEMPTS = 15  -- Increased from 5 to 15 for ~4.5 s IPC probe window
local RUNTIME_PROBE_CACHE_SEC = 8
local RUNTIME_PROBE_FAIL_COOLDOWN_SEC = 1.5

-- Per-boot-session marker so a single GUI prime serves all subsequent HS
-- reloads in the same login session. The file content is the kernel boot
-- timestamp; a mismatch (or missing file) means the session changed and
-- we need to re-prime.
--
-- The "_v2" suffix invalidates older markers that may have been written by
-- a buggy revision of prime_ke_for_session — in particular the short-lived
-- hs.application.open(_, _, noActivate=true) attempt on Sequoia which
-- recorded "primed" without actually establishing the IPC bridge. Bump the
-- version any time the prime semantics change so users get a clean re-prime
-- instead of inheriting a stale "already primed" claim.
local PRIME_MARKER_PATH = "/tmp/ergopti_ke_primed_v2.txt"

-- Marker written only when HS itself successfully bootstraps the KE bridge.
-- Used to avoid killing a user-managed KE session on HS shutdown.
local HS_OWNER_MARKER_PATH = "/tmp/ergopti_ke_hs_owner_v1.txt"

-- Module-level flag set while a prime cycle is in flight. Exposed via
-- M.is_priming() so the menu can render a transient "amorçage en cours"
-- state instead of a misleading "rules not applied" yellow during the
-- ~2 s prime delay.
local _prime_in_progress = false
local _hs_owned_runtime = false
local _prime_callbacks = {}
local _prime_settle_timer = nil
local _prime_poll_timer = nil
local _prime_probe_timer = nil
local _last_karabiner_ready_notify_at = 0
local _pending_karabiner_ready_notify = false
local _karabiner_ready_notify_timer = nil
local is_ipc_bridge_fully_ready
local _last_runtime_probe_ok = false
local _last_runtime_probe_at = 0

local KARABINER_READY_NOTIFY_COOLDOWN_SEC = 10
local KARABINER_READY_NOTIFY_DELAY_SEC = 2.5
local HS_BOOT_READY_SETTING_KEY = "ergopti_hs_boot_ready_v1"

--- Returns true only when init.lua has completed the full boot sequence.
--- @return boolean
local function is_hs_boot_ready()
	local ok, value = pcall(function()
		return hs.settings.get(HS_BOOT_READY_SETTING_KEY)
	end)
	return ok and value == true
end

--- Dispatches a user-facing "Karabiner ready" notification with cooldown.
local function notify_karabiner_ready()
	if not is_hs_boot_ready() then
		_pending_karabiner_ready_notify = true
		Logger.debug(LOG, "Karabiner ready notification deferred until HS boot completes.")
		return
	end

	if _karabiner_ready_notify_timer then
		pcall(function() _karabiner_ready_notify_timer:stop() end)
		_karabiner_ready_notify_timer = nil
	end

	_pending_karabiner_ready_notify = false
	_karabiner_ready_notify_timer = hs.timer.doAfter(KARABINER_READY_NOTIFY_DELAY_SEC, function()
		local ok, err = pcall(function()
			Logger.debug(LOG, "Karabiner ready notification timer triggered (%.1f s delay).", KARABINER_READY_NOTIFY_DELAY_SEC)
			_karabiner_ready_notify_timer = nil
			if not is_hs_boot_ready() then
				_pending_karabiner_ready_notify = true
				Logger.debug(LOG, "Karabiner ready notification postponed — HS boot not ready.")
				return
			end

			local now = hs.timer.secondsSinceEpoch()
			if (now - _last_karabiner_ready_notify_at) < KARABINER_READY_NOTIFY_COOLDOWN_SEC then
				Logger.debug(LOG, "Karabiner ready notification skipped (cooldown %.1fs).",
					KARABINER_READY_NOTIFY_COOLDOWN_SEC)
				return
			end
			_last_karabiner_ready_notify_at = now
			Logger.info(LOG, "Karabiner ready notification sent.")
			Notifications.notify(i18n.get("karabiner.ready_title"), i18n.get("karabiner.ready_body"), "success")
		end)
		if not ok then
			_pending_karabiner_ready_notify = true
			_karabiner_ready_notify_timer = nil
			Logger.error(LOG, "Karabiner ready notification callback failed: %s.", tostring(err))
		end
	end)
end

--- Flushes a deferred Karabiner ready notification once HS boot is complete.
function M.flush_pending_ready_notification()
	if not _pending_karabiner_ready_notify then return end
	if not is_hs_boot_ready() then return end
		Logger.debug(LOG, "Flushing pending Karabiner ready notification…")
	_pending_karabiner_ready_notify = false
	notify_karabiner_ready()
end




-- ========================================
--- ========================================
-- ======= 1/ KE Process Management =======
--- ========================================
-- ========================================

--- Returns true when any Karabiner-Elements daemon is running.
--- This confirms KE is installed and will process our karabiner.json.
--- The detection is version-tolerant by matching the install-path substring
--- rather than a specific binary name (see KE_GRABBER_CHECK above).
--- @return boolean
function M.is_grabber_running()
	local _, ok = hs.execute(KE_GRABBER_CHECK .. " 2>/dev/null")
	return ok == true
end

--- Checks that Karabiner-Elements is installed (grabber running) and notifies
--- the user if it is not. No agent is bootstrapped — the grabber reloads
--- karabiner.json via FSEvents automatically, so starting any user-level agent
--- is unnecessary and would cause the KE menubar icon to appear.
--- @return boolean True if the grabber is running.
function M.launch_headless()
	if not M.is_grabber_running() then
		Logger.warn(LOG, "karabiner_grabber not running — Karabiner-Elements may not be installed.")
		local ok_notif, notifications = pcall(require, "lib.notifications")
		if ok_notif then
			notifications.notify(
				i18n.get("karabiner.lifecycle.unavailable"),
				nil, "warning")
		end
		return false
	end
	Logger.debug(LOG, "karabiner_grabber is running — FSEvents reload will apply the new config.")
	return true
end

--- Opens the Karabiner-Elements GUI for the user on explicit request.
--- This is the only path that ever opens the app visibly — purely user-initiated.
function M.open_gui()
	local ok = pcall(hs.application.launchOrFocus, "Karabiner-Elements")
	if not ok then
		hs.execute("open -a 'Karabiner-Elements' 2>/dev/null")
	end
	Logger.info(LOG, "Karabiner-Elements GUI opened by user request.")
end




-- ==================================
--- ==================================
-- ======= 2/ Session Priming =======
--- ==================================
-- ==================================

--- Returns the kernel boot timestamp (epoch seconds), or nil on failure.
--- Used as a per-session identifier — boot timestamp changes only on full
--- reboot, which is also when KE's in-memory rules state is wiped. This is
--- a safer signal than tracking login sessions, which can be hard to detect.
--- @return string|nil
local function get_boot_timestamp()
	local out, ok = hs.execute("/usr/sbin/sysctl -n kern.boottime 2>/dev/null")
	if ok ~= true or type(out) ~= "string" then return nil end
	return out:match("sec = (%d+)")
end

--- True when the KE bridge has been primed in the current boot session.
--- The marker file at PRIME_MARKER_PATH stores the boot timestamp; a mismatch
--- (or missing file) means we are in a new session that needs re-priming.
--- @return boolean
function M.is_session_primed()
	local boot_ts = get_boot_timestamp()
	if not boot_ts then return false end
	local f = io.open(PRIME_MARKER_PATH, "r")
	if not f then return false end
	local saved_ts = f:read("*line")
	f:close()
	return saved_ts == boot_ts
end

--- Persists the current boot timestamp to the marker file so future HS
--- reloads in the same boot session can skip the prime step.
local function mark_session_primed()
	local boot_ts = get_boot_timestamp()
	if not boot_ts then
		Logger.warn(LOG, "mark_session_primed: could not read boot timestamp — marker not written.")
		return
	end
	local f = io.open(PRIME_MARKER_PATH, "w")
	if not f then
		Logger.warn(LOG, "mark_session_primed: could not write marker at '%s'.", PRIME_MARKER_PATH)
		return
	end
	f:write(boot_ts)
	f:close()
end

--- Marks the bridge as spawned by Hammerspoon in the current boot session.
local function mark_hs_owned_bridge()
	_hs_owned_runtime = true
	local boot_ts = get_boot_timestamp()
	if not boot_ts then
		Logger.warn(LOG, "mark_hs_owned_bridge: could not read boot timestamp — owner marker not written.")
		return
	end
	local f = io.open(HS_OWNER_MARKER_PATH, "w")
	if not f then
		Logger.warn(LOG, "mark_hs_owned_bridge: could not write owner marker at '%s'.", HS_OWNER_MARKER_PATH)
		return
	end
	f:write(boot_ts .. "\n")
	f:write(tostring(os.time()) .. "\n")
	f:close()
end

--- Clears the HS ownership marker.
local function clear_hs_owned_bridge_marker()
	_hs_owned_runtime = false
	pcall(os.remove, HS_OWNER_MARKER_PATH)
end

--- Returns true when a file exists and is readable.
--- @param path string
--- @return boolean
local function file_exists(path)
	local f = io.open(path, "r")
	if not f then return false end
	f:close()
	return true
end

--- Resolves all callbacks waiting for the current prime cycle.
--- @param ok boolean
local function resolve_prime_callbacks(ok)
	local callbacks = _prime_callbacks
	_prime_callbacks = {}
	for _, cb in ipairs(callbacks) do
		pcall(cb, ok)
	end
end

--- True when the current KE bridge instance was spawned by HS in this boot session.
--- @return boolean
function M.is_hs_owned_bridge()
	if _hs_owned_runtime then return true end
	local boot_ts = get_boot_timestamp()
	if not boot_ts then return false end
	local f = io.open(HS_OWNER_MARKER_PATH, "r")
	if not f then return false end
	local saved_ts = f:read("*line")
	f:close()
	return saved_ts == boot_ts
end

--- True when any user-level KE bridge process is running.
--- Single shell call with short-circuit so at most one pgrep ever spawns.
--- Uses -f (full command-line match) instead of -x (exact process name) because
--- KE v16 renames karabiner_console_user_server to org.pqrs.karabiner_console_user_server
--- at runtime, which breaks -x exact matching even though the process is alive.
--- @return boolean
local function is_ipc_bridge_running()
	local _, ok = hs.execute(
		"/usr/bin/pgrep -fq 'Karabiner-Elements/bin/karabiner_console_user_server' 2>/dev/null"
		.. " || /usr/bin/pgrep -qx org.pqrs.karabiner_console_user_server 2>/dev/null"
		.. " || /usr/bin/pgrep -qx karabiner_console_user_server 2>/dev/null"
		.. " || /usr/bin/pgrep -fq 'Karabiner-Elements/bin/karabiner_session_monitor' 2>/dev/null"
		.. " || /usr/bin/pgrep -qx org.pqrs.karabiner_session_monitor 2>/dev/null"
		.. " || /usr/bin/pgrep -qx karabiner_session_monitor 2>/dev/null"
		.. " || /usr/bin/pgrep -qx Karabiner-Menu 2>/dev/null"
	)
	return ok == true
end

--- True only when the headless bridge runtime is fully up.
--- We require BOTH user-level processes because console_user_server can be
--- visible first while session_monitor is still starting; remapping is not
--- reliably operational until both are alive.
--- @return boolean
is_ipc_bridge_fully_ready = function()
	-- KE v16+ dropped karabiner_session_monitor — console_user_server alone is
	-- sufficient to confirm the IPC bridge is up. Requiring session_monitor
	-- caused an infinite polling timeout on v16 (process absent → always false).
	local _, ok = hs.execute(
		"( /usr/bin/pgrep -fq 'Karabiner-Elements/bin/karabiner_console_user_server' 2>/dev/null"
		.. " || /usr/bin/pgrep -qx org.pqrs.karabiner_console_user_server 2>/dev/null"
		.. " || /usr/bin/pgrep -qx karabiner_console_user_server 2>/dev/null )"
	)
	return ok == true
end

--- Runs a runtime probe through karabiner_cli to ensure the bridge is not only
--- spawned but also responsive for variable IPC operations.
--- Uses --set-variables (JSON format) for Karabiner v16+ compatibility.
--- @return boolean
local function is_cli_roundtrip_ready()
	if not file_exists(KE_CLI_BIN) then
		Logger.warn(LOG, "karabiner_cli not found at '%s'.", KE_CLI_BIN)
		return false
	end

	local probe_value = math.floor((hs.timer.secondsSinceEpoch() * 1000) % 1000000)
	-- Use --set-variables with JSON format (Karabiner v16+)
	local set_cmd = string.format(
		"%q --set-variables '{\"ergopti_ready_probe\":%d}' >/dev/null 2>&1",
		KE_CLI_BIN,
		probe_value
	)
	local _, set_ok = hs.execute(set_cmd)
	if set_ok ~= true then
		Logger.debug(LOG, "karabiner_cli set-variables probe failed.")
		_last_runtime_probe_ok = false
		_last_runtime_probe_at = hs.timer.secondsSinceEpoch()
		return false
	end

	-- For Karabiner v16+, we cannot easily read back individual variables.
	-- A successful set-variables call indicates IPC is working, which is
	-- sufficient for our readiness probe.
	_last_runtime_probe_ok = true
	_last_runtime_probe_at = hs.timer.secondsSinceEpoch()
	return true
end

--- True only when the bridge processes are up and the runtime IPC roundtrip is
--- functional through karabiner_cli.
--- @return boolean
local function is_runtime_remapping_ready(force_probe)
	if not is_ipc_bridge_fully_ready() then
		_last_runtime_probe_ok = false
		_last_runtime_probe_at = hs.timer.secondsSinceEpoch()
		return false
	end

	local now = hs.timer.secondsSinceEpoch()
	if not force_probe and _last_runtime_probe_ok
		and (now - _last_runtime_probe_at) <= RUNTIME_PROBE_CACHE_SEC then
		return true
	end

	if not force_probe and (now - _last_runtime_probe_at) <= RUNTIME_PROBE_FAIL_COOLDOWN_SEC then
		return _last_runtime_probe_ok
	end

	return is_cli_roundtrip_ready()
end

--- Public alias so callers (e.g. karabiner/init.lua) can check bridge status
--- without duplicating the detection logic.
--- @return boolean
function M.is_bridge_running()
	return is_ipc_bridge_running()
end

--- True while a prime cycle is in flight. Exposed so the menu can render a
--- distinct "amorçage en cours" status during the ~2 s window — without
--- this signal, the menu would show the alarming "règles non appliquées"
--- yellow even though the prime is about to complete normally.
--- @return boolean
function M.is_priming()
	return _prime_in_progress
end

--- Primes Karabiner-Elements for headless operation: launches the bridge
--- daemon in background, then polls asynchronously via hs.timer.doAfter
--- until the IPC roundtrip probe confirms the rules are live.
---
--- Fully non-blocking: Hammerspoon's event loop is never paused. The outer
--- process poll and the CLI probe retries both use hs.timer so the menu bar
--- and all other modules continue responding while KE starts up.
---
--- GUI fallback is intentionally disabled: if headless priming cannot start,
--- we fail loudly and keep behavior fully background-only.
---
--- Idempotent across HS reloads via the boot-timestamp marker file. Skipped
--- (and the marker written) when an IPC bridge is already running.
--- @param callback function|nil fun(success: boolean) called when done.
--- @param force boolean|nil When true, ignore the per-session marker and
---                          always perform the prime cycle. Used after an
---                          explicit bridge kill (regenerate) or on manual
---                          re-prime from the menu.
function M.prime_ke_for_session(callback, force)
	callback = callback or function() end
	if _prime_in_progress then
		Logger.debug(LOG, "Prime already in progress — callback queued.")
		_prime_callbacks[#_prime_callbacks + 1] = callback
		return
	end

	_prime_callbacks[#_prime_callbacks + 1] = callback

	local bridge_running = is_ipc_bridge_running()
	if not force and M.is_session_primed() and bridge_running then
		Logger.debug(LOG, "KE bridge already primed for this boot session and bridge is alive — skipping.")
		resolve_prime_callbacks(true)
		return
	end

	-- When force=false and bridge is running but not yet marked, record the marker.
	if bridge_running and not force then
		Logger.info(LOG, "KE IPC bridge already running (Menu or GUI) — recording marker.")
		mark_session_primed()
		resolve_prime_callbacks(true)
		return
	end

	if not force and M.is_session_primed() and not bridge_running then
		Logger.warn(LOG, "Prime marker exists but bridge is not running — re-priming now.")
	end

	-- Idempotent defaults write — fast, kept synchronous (no UI side-effect).
	hs.execute(KE_PERSISTENCE_OFF_CMD .. " 2>/dev/null")
	hs.execute(KE_REENABLE_USER_LABELS_CMD)
	-- Kill visible KE UI agents immediately, before the bridge spawns, so the
	-- menubar hammer icon and app window never appear even during the prime window.
	-- This is the same command run at the end of priming, but running it here
	-- prevents the ~2-13 s window where launchd-started agents are visible.
	pcall(function() hs.execute(KE_SUPPRESS_DOCK_HELPERS_CMD) end)

	Logger.start(LOG, "Priming KE bridge (headless, async)…")
	_prime_in_progress = true
	mark_hs_owned_bridge()

	local headless_launch_attempts = 0
	local fallback_attempted       = false

	local function launch_headless_once()
		if not file_exists(KE_CONSOLE_USER_SERVER_BIN) then
			Logger.warn(LOG, "Headless bridge binary not found at '%s'.", KE_CONSOLE_USER_SERVER_BIN)
			return false
		end
		headless_launch_attempts = headless_launch_attempts + 1
		hs.execute(KE_PRIME_HEADLESS_CMD)
		return true
	end

	-- Forward declaration: probe_and_commit and poll_attempt are mutually recursive.
	-- probe_and_commit falls back to poll_attempt when all probe retries fail.
	local poll_attempt

	-- Called once the bridge processes are visible. Runs the CLI roundtrip probe
	-- and retries asynchronously up to PRIME_RULES_PROBE_RETRY_ATTEMPTS times.
	-- Falls back to the next outer poll tick when all probe retries are exhausted.
	local function probe_and_commit(outer_attempt, probe_attempt)
		if is_cli_roundtrip_ready() then
			pcall(function() hs.execute(KE_SUPPRESS_DOCK_HELPERS_CMD) end)
			mark_session_primed()
			mark_hs_owned_bridge()
			_prime_in_progress = false
			Logger.success(LOG,
				"KE bridge ready in %d poll(s), IPC probe ok on probe attempt %d.",
				outer_attempt, probe_attempt)
			notify_karabiner_ready()
			resolve_prime_callbacks(true)
			return
		end

		if probe_attempt < PRIME_RULES_PROBE_RETRY_ATTEMPTS then
			Logger.debug(LOG, "IPC probe not ready (attempt %d/%d) — retrying in %.0f ms…",
				probe_attempt, PRIME_RULES_PROBE_RETRY_ATTEMPTS,
				PRIME_RULES_PROBE_RETRY_INTERVAL_SEC * 1000)
			_prime_probe_timer = hs.timer.doAfter(PRIME_RULES_PROBE_RETRY_INTERVAL_SEC, function()
				_prime_probe_timer = nil
				probe_and_commit(outer_attempt, probe_attempt + 1)
			end)
		else
			-- All probe retries exhausted on this outer tick; bridge may still be
			-- initialising its IPC socket — resume the outer poll.
			Logger.debug(LOG,
				"Bridge up but IPC probe still failing after %d retries — resuming outer poll…",
				PRIME_RULES_PROBE_RETRY_ATTEMPTS)
			_prime_poll_timer = hs.timer.doAfter(PRIME_POLL_INTERVAL_SEC, function()
				_prime_poll_timer = nil
				poll_attempt(outer_attempt + 1)
			end)
		end
	end

	-- Outer async polling loop: checks for bridge process visibility on each tick,
	-- then hands off to probe_and_commit. Schedules itself until success or timeout.
	poll_attempt = function(attempt)
		if attempt > PRIME_POLL_MAX_ATTEMPTS then
			clear_hs_owned_bridge_marker()
			_prime_in_progress = false
			Logger.error(LOG,
				"KE bridge did not appear after %d polls (%.1f s) — config may not be applied.",
				PRIME_POLL_MAX_ATTEMPTS, PRIME_POLL_MAX_ATTEMPTS * PRIME_POLL_INTERVAL_SEC)
			resolve_prime_callbacks(false)
			return
		end

		if is_ipc_bridge_fully_ready() then
			-- Bridge processes are visible: start the IPC probe sequence.
			probe_and_commit(attempt, 1)
			return
		end

		if attempt == PRIME_FALLBACK_AFTER_ATTEMPTS and is_ipc_bridge_running() then
			Logger.info(LOG, "Bridge process visible but not fully ready yet — waiting…")
		end

		-- Periodically retry the headless launch if the bridge has not appeared yet.
		if not fallback_attempted
			and headless_launch_attempts > 0
			and headless_launch_attempts < PRIME_MAX_HEADLESS_ATTEMPTS
			and (attempt % PRIME_RETRY_HEADLESS_EVERY_ATTEMPTS == 0) then
			Logger.warn(LOG, "Bridge still absent after %d poll(s) — retrying headless launch…", attempt)
			launch_headless_once()
		end

		if not fallback_attempted and attempt >= PRIME_FALLBACK_AFTER_ATTEMPTS then
			fallback_attempted = true
			Logger.warn(LOG, "Primary headless launch not yet visible — GUI fallback disabled, continuing…")
		end

		_prime_poll_timer = hs.timer.doAfter(PRIME_POLL_INTERVAL_SEC, function()
			_prime_poll_timer = nil
			poll_attempt(attempt + 1)
		end)
	end

	-- Entry point: start the bridge, then begin async polling.
	-- When force=true the old bridge was just pkill'd (async), so we wait briefly
	-- before launching the new one to avoid a PID race.
	local function start_launch_and_poll()
		if not launch_headless_once() then
			fallback_attempted = true
			Logger.error(LOG, "Headless bridge binary missing — GUI fallback is disabled by design.")
		end
		_prime_poll_timer = hs.timer.doAfter(PRIME_POLL_INTERVAL_SEC, function()
			_prime_poll_timer = nil
			poll_attempt(1)
		end)
	end

	if bridge_running and force then
		-- Fast path: in some environments the bridge is already fully responsive
		-- right after regenerate(). Avoid the async settle/relaunch path and mark
		-- primed immediately to prevent getting stuck in an unmarked state.
		if is_cli_roundtrip_ready() then
			mark_session_primed()
			mark_hs_owned_bridge()
			_prime_in_progress = false
			Logger.success(LOG, "KE bridge already responsive (force path) — primed immediately.")
			notify_karabiner_ready()
			resolve_prime_callbacks(true)
			return
		end

		-- pkill is async; give it 200 ms to propagate before checking again.
		Logger.info(LOG, "Bridge alive but force=true — waiting 200 ms for pkill to settle…")
		_prime_settle_timer = hs.timer.doAfter(0.2, function()
			_prime_settle_timer = nil
			Logger.debug(LOG, "Prime settle callback fired.")
			if is_ipc_bridge_running() then
				-- On KE v16+, the bridge may intentionally stay alive despite fast kill.
				-- If IPC is already responsive, mark as primed immediately instead of
				-- forcing a kill/relaunch cycle that can deadlock the polling path.
				if is_cli_roundtrip_ready() then
					mark_session_primed()
					mark_hs_owned_bridge()
					_prime_in_progress = false
					Logger.success(LOG, "KE bridge already responsive after settle — primed without relaunch.")
					notify_karabiner_ready()
					resolve_prime_callbacks(true)
					return
				end

				Logger.warn(LOG, "Bridge still alive after settle but IPC probe failed — firing extra kill before re-prime…")
				pcall(function() hs.execute(KARABINER_KILL_FAST_CMD) end)
				_prime_settle_timer = hs.timer.doAfter(0.2, function()
					_prime_settle_timer = nil
					start_launch_and_poll()
				end)
			else
				start_launch_and_poll()
			end
		end)
	else
		start_launch_and_poll()
	end
end

--- True only when the KE stack is fully operational AND the bridge has been
--- primed in the current boot session. This is the honest signal for the
--- menu's green status indicator: a "yes" here means remapping is actually
--- applied, not merely that processes happen to be running.
---
--- Lazy-marking: if the session marker is absent but the bridge is currently
--- running, we write the marker now. This recovers from a polling timeout
--- (the daemon took >2.4 s to appear) without waiting for a manual re-prime.
--- @return boolean
function M.is_remapping_active()
	if not M.is_grabber_running() then return false end
	if M.is_session_primed() then
		return is_runtime_remapping_ready()
	end
	-- Lazy fallback: bridge is alive even though the polling callback missed it.
	if is_runtime_remapping_ready() then
		mark_session_primed()
		mark_hs_owned_bridge()
		Logger.info(LOG, "Lazy prime marker written — runtime remapping probe is ready.")
		return true
	end
	return false
end

return M
