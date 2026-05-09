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
---    persist in its memory until logout/reboot, even after the GUI quits and
---    even across HS reloads. We therefore launch the GUI silently with
---    `open -gj`, wait for it to push the rules, then quit it via Cmd+Q.
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
	.. "; for label in $(/bin/launchctl list 2>/dev/null"
	.. "                 | /usr/bin/awk '/[Kk]arabiner|pqrs/ {print $3}'); do"
	.. "   /bin/launchctl bootout gui/$UID/$label 2>/dev/null; true;"
	.. " done"
	.. "; /usr/bin/pkill -x Karabiner-Menu 2>/dev/null"
	.. "; /usr/bin/pkill -x Karabiner-NotificationWindow 2>/dev/null"
	.. "; /usr/bin/pkill -x Karabiner-Multitouch-Extension 2>/dev/null"
	.. "; /usr/bin/pkill -x Karabiner-Elements 2>/dev/null"
	.. "; /usr/bin/pkill -x Karabiner-EventViewer 2>/dev/null"
	-- Legacy v14 helper names — no-op on v15 but kept for old installs.
	.. "; /usr/bin/pkill -x karabiner_observer 2>/dev/null"
	.. "; /usr/bin/pkill -x karabiner_session_monitor 2>/dev/null"
	-- Clear the per-session prime marker so the next HS launch starts
	-- with a clean slate and re-primes from scratch.
	.. "; /bin/rm -f /tmp/ergopti_ke_primed_v2.txt 2>/dev/null"
	.. "; true"

--- Shell command to fully stop user-level KE agents — exposed for regenerate().
M.KILL_CMD = KARABINER_KILL_CMD

-- Per-session priming: launching Karabiner-Menu causes it to read
-- karabiner.json and push the rules to Core-Service via IPC. Karabiner-Menu
-- maintains the IPC link as long as it runs, so remapping stays alive
-- across HS reloads.
--
-- Why Karabiner-Menu and NOT Karabiner-Elements.app:
--   Karabiner-Menu has LSUIElement=true (menubar-only app, no main window,
--   no Dock icon, no Space affinity). Launching it cannot trigger a Space
--   switch and cannot show a window — both happen with the full GUI even
--   under `open -gj`. Karabiner-Menu also speaks the same IPC protocol as
--   the main GUI, so the rules get pushed without the user-visible cost.
--
-- Locating Karabiner-Menu.app: it ships inside the main bundle under
-- LoginItems on v15+, with a fallback path for older / custom installs.
-- Discovery is cached at module load.
local KE_MENU_APP_PATH = (function()
	local candidates = {
		"/Applications/Karabiner-Elements.app/Contents/Library/LoginItems/Karabiner-Menu.app",
		"/Library/Application Support/org.pqrs/Karabiner-Elements/Karabiner-Menu.app",
	}
	for _, p in ipairs(candidates) do
		local f = io.open(p .. "/Contents/Info.plist", "r")
		if f then f:close() return p end
	end
	return nil
end)()

-- Launch command, computed at module load. If Karabiner-Menu was found we
-- use it (silent, LSUIElement); otherwise we fall back to the main GUI
-- which has the visible-window + Space-switch downsides but at least
-- establishes the IPC bridge correctly. The latter is the legacy path
-- we keep for KE installs that lack the LoginItems bundle.
local KE_PRIME_OPEN_CMD = (function()
	if KE_MENU_APP_PATH then
		return "/usr/bin/open -gj " .. string.format("%q", KE_MENU_APP_PATH)
	end
	return "/usr/bin/open -gj '/Applications/Karabiner-Elements.app'"
end)()

-- True when the prime path uses Karabiner-Menu (silent). Used by the prime
-- cycle to skip the post-launch GUI cleanup that only matters in the
-- fallback main-GUI launch path.
local KE_PRIME_USES_MENU = (KE_MENU_APP_PATH ~= nil)

-- pkill the main GUI process by exact name. Only used in the fallback
-- legacy path (when Karabiner-Menu.app is not found) to dismiss the main
-- window after the IPC push completes. -x matches only "Karabiner-Elements"
-- and never the system daemons or Karabiner-Menu.
local KE_PRIME_KILL_GUI_CMD = "/usr/bin/pkill -x Karabiner-Elements 2>/dev/null"

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

-- Time to wait between launching the GUI and quitting it. The GUI must
-- finish reading karabiner.json and pushing the rules over IPC before we
-- send Cmd+Q. Empirically ~2 s is enough on modern hardware.
local KE_PRIME_DELAY_SEC = 2.0

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

-- Module-level flag set while a prime cycle is in flight. Exposed via
-- M.is_priming() so the menu can render a transient "amorçage en cours"
-- state instead of a misleading "rules not applied" yellow during the
-- ~2 s prime delay.
local _prime_in_progress = false




-- ========================================
-- ========================================
-- ======= 1/ KE Process Management =======
-- ========================================
-- ========================================

--- Returns true when any Karabiner-Elements daemon is running.
--- This confirms KE is installed and will process our karabiner.json.
--- The detection is version-tolerant by matching the install-path substring
--- rather than a specific binary name (see KE_GRABBER_CHECK above).
--- @return boolean
function M.is_grabber_running()
	-- Capture stderr in stdout so an unexpected pgrep failure (missing binary,
	-- PATH issue, kernel-level oddity) is visible in the log instead of being
	-- silently dropped. The exit code 1 from "no match" is normal and expected.
	local out, ok, exit_type, rc = hs.execute(KE_GRABBER_CHECK .. " 2>&1")
	-- Diagnostic: list every karabiner-related process so the log shows the
	-- real KE state in case detection drifts again across versions. Does not
	-- influence the return value — only the log line.
	local list_out = hs.execute("/usr/bin/pgrep -fil karabiner 2>&1") or ""
	Logger.debug(LOG,
		"is_grabber_running: cmd=%q ok=%s type=%s rc=%s out=%q ; processes=%q.",
		KE_GRABBER_CHECK, tostring(ok), tostring(exit_type), tostring(rc),
		out or "", list_out:gsub("\n", " | "))
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
				"Karabiner-Elements non disponible — vérifier l'installation.",
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
-- ==================================
-- ======= 2/ Session Priming =======
-- ==================================
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

--- True when any user-level KE process that maintains the IPC bridge is
--- currently running — either the main Karabiner-Elements GUI (because the
--- user opened it manually) or Karabiner-Menu (the silent menubar helper
--- our prime launches). Either implies that rules have already been pushed
--- to Core-Service in this session.
--- @return boolean
local function is_ipc_bridge_running()
	local _, gui_ok = hs.execute(KE_GUI_CHECK_CMD .. " 2>/dev/null")
	if gui_ok == true then return true end
	local _, menu_ok = hs.execute("/usr/bin/pgrep -x Karabiner-Menu 2>/dev/null")
	return menu_ok == true
end

--- True while a prime cycle is in flight. Exposed so the menu can render a
--- distinct "amorçage en cours" status during the ~2 s window — without
--- this signal, the menu would show the alarming "règles non appliquées"
--- yellow even though the prime is about to complete normally.
--- @return boolean
function M.is_priming()
	return _prime_in_progress
end

--- Primes Karabiner-Elements for headless operation by silently launching
--- the KE GUI app, waiting for it to push the on-disk rules to Core-Service
--- via IPC, then quitting the GUI. KE keeps the loaded rules in
--- Core-Service's memory after the GUI quits, so remapping persists for the
--- rest of the boot session — even across HS reloads.
---
--- This step is mandatory: without it, Core-Service runs but does not apply
--- our deployed config. The GUI is the only known way to trigger the IPC
--- push (karabiner_cli has no --reload flag in v15).
---
--- Launch target is Karabiner-Menu.app when available (LSUIElement=true →
--- no window, no Dock icon, no Space switch possible) — see KE_PRIME_OPEN_CMD
--- above for the discovery logic. Karabiner-Menu speaks the same IPC
--- protocol as the main GUI, so the rules reach Core-Service identically
--- but without any user-visible side effect.
---
--- Falls back to launching the full Karabiner-Elements.app when the Menu
--- bundle is not found. The fallback is visible (window flash + Space
--- switch) and is followed by a pkill to dismiss it; it exists only so
--- non-standard KE installs do not break.
---
--- Idempotent across HS reloads via the boot-timestamp marker file. Skipped
--- (and the marker written) when an IPC bridge is already running.
--- @param callback function|nil fun(success: boolean) called when done.
--- @param force boolean|nil When true, ignore the per-session marker and
---                          always perform the prime cycle. Used by the
---                          Status menu item so the user can manually re-push
---                          rules when the daemon has been restarted by macOS.
function M.prime_ke_for_session(callback, force)
	callback = callback or function() end
	if not force and M.is_session_primed() then
		Logger.debug(LOG, "KE bridge already primed for this boot session — skipping.")
		callback(true)
		return
	end

	if is_ipc_bridge_running() then
		Logger.info(LOG, "KE IPC bridge already running (Menu or GUI) — recording marker.")
		mark_session_primed()
		callback(true)
		return
	end

	-- Disable window-state persistence so any GUI-fallback launch cannot
	-- drag focus to whichever Space last hosted a KE window. Idempotent.
	-- Cheap (~5 ms), so we do it inline rather than once at module load.
	hs.execute(KE_PERSISTENCE_OFF_CMD .. " 2>/dev/null")

	if KE_PRIME_USES_MENU then
		Logger.start(LOG, "Priming KE bridge (silent Karabiner-Menu launch)…")
	else
		Logger.start(LOG, "Priming KE bridge (legacy main-GUI fallback — visible window expected)…")
	end
	_prime_in_progress = true

	local _, open_ok = hs.execute(KE_PRIME_OPEN_CMD .. " 2>&1")
	if open_ok ~= true then
		Logger.error(LOG, "Failed to launch KE bridge for priming — config may not be applied.")
		_prime_in_progress = false
		callback(false)
		return
	end

	-- Wait long enough for the just-launched bridge process (Menu or full
	-- GUI) to read karabiner.json and push the rules to Core-Service over
	-- IPC. Empirically ~2 s is the floor on modern hardware.
	hs.timer.doAfter(KE_PRIME_DELAY_SEC, function()
		if not KE_PRIME_USES_MENU then
			-- Fallback path only: pkill the visible main GUI now that the
			-- IPC push is done. Karabiner-Menu, if it was auto-spawned by
			-- the GUI launch, intentionally survives — it is what keeps
			-- the bridge alive across HS reloads.
			hs.execute(KE_PRIME_KILL_GUI_CMD)
		end
		mark_session_primed()
		_prime_in_progress = false
		Logger.success(LOG, "KE bridge primed; menubar helper kept alive for the rest of the session.")
		callback(true)
	end)
end

--- True only when the KE stack is fully operational AND the bridge has been
--- primed in the current boot session. This is the honest signal for the
--- menu's green status indicator: a "yes" here means remapping is actually
--- applied, not merely that processes happen to be running.
--- @return boolean
function M.is_remapping_active()
	return M.is_grabber_running() and M.is_session_primed()
end

return M
