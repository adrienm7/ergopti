--- modules/keymap/input_sources.lua

--- ==============================================================================
--- MODULE: Keyboard Input Sources
--- DESCRIPTION:
--- Enumerates and switches the macOS keyboard input sources (the live HIToolbox
--- list), maps Ergopti variants to their TIS identifiers, and enables / selects a
--- source via isolated osascript. Extracted from ui/menu/menu_keyboard_layout.lua
--- (audit F4) — the ~660-line input-source layer that the submenu builder drives.
---
--- FEATURES & RATIONALE:
--- 1. Subprocess-free menu opens: the expensive HIToolbox probe is memoised in
---    _active_layouts_cache and refreshed asynchronously off the click path.
--- 2. Legacy-id migration: upgrades pre-namespace Ergopti ids to the current TIS
---    namespace so older installs keep working.
--- 3. Isolated osascript: TIS calls run in their own subprocess so a hang cannot
---    stall the Hammerspoon run loop.
---
--- Owns the active-layout probe cache; depends on layout_install for on-disk
--- bundle detection (highest_installed / path_exists) and the install dirs.
--- ==============================================================================

local hs      = hs
local Logger  = require("infra.logger")
local text_utils = require("infra.text_utils")
local Timings = require("infra.timings")
local install = require("modules.keymap.layout_install")
local ShellRunner = require("adapters.shell_runner")
local TaskLifecycle = require("adapters.task_lifecycle")
local TimerScheduler = require("adapters.timer_scheduler")
local LOG     = "menu.keyboard_layout"

-- Install-layer helpers used by the enumeration / selection logic below.
local highest_installed  = install.highest_installed
local path_exists        = install.path_exists
local version_gt         = install.version_gt
local USER_LAYOUTS_DIR   = install.USER_LAYOUTS_DIR
local SYSTEM_LAYOUTS_DIR = install.SYSTEM_LAYOUTS_DIR

-- All Ergopti variants packaged in the bundle. Used to expose a submenu with
-- a one-click TISEnableInputSource entry for each. The order shown in the
-- menu mirrors the natural progression: base → ANSI → plus → plus ANSI →
-- plus_plus → plus_plus ANSI.
-- TIS IDs use the `com.apple.keyboardlayout.*` namespace (third-party convention).
-- The shorter `com.apple.keylayout.*` namespace is reserved by macOS for system
-- input sources; using it for a third-party bundle causes the OS to silently
-- refuse to register the bundle, so it never appears in the input-source list.
-- Note: Ergopti++ variants are intentionally absent here — they are not
-- included in the current bundle and must not be offered to the user.
local ERGOPTI_VARIANTS = {
	{ id = "com.apple.keyboardlayout.ergopti",           label = "Ergopti",      suffix = ""          },
	{ id = "com.apple.keyboardlayout.ergopti.ansi",      label = "Ergopti ANSI", suffix = "_ansi"     },
	{ id = "com.apple.keyboardlayout.ergopti.plus",      label = "Ergopti+",     suffix = "_plus"     },
	{ id = "com.apple.keyboardlayout.ergopti.plus.ansi", label = "Ergopti+ ANSI", suffix = "_plus_ansi" },
}

-- Throttle window for the async active-layout refresh (seconds). Bounds python3
-- spawns even if the user reopens the menu rapidly.
local ACTIVE_LAYOUTS_REFRESH_THROTTLE_SEC = 5

-- A wedged cfprefsd, SystemUIServer, or TIS bridge must never park the single
-- Hammerspoon runloop. Every mutating child is owned through this deadline.
local INPUT_SOURCE_OPERATION_TIMEOUT_SEC =
	Timings.sec("ui", "input_source_operation_timeout_ms")

-- Records from the (expensive) HIToolbox active-layout probe. nil until first
-- computed; refreshed asynchronously so menu opens never pay the python3 cost.
local _active_layouts_cache = nil
-- Epoch seconds of the last async refresh (throttle anchor); 0 forces a refresh.
local _active_layouts_last_refresh = 0
-- Guards against overlapping async refreshes.
local _active_layouts_refreshing = false
-- GC-root for in-flight probe task handles. An async task handle that is not
-- referenced from a reachable table can be collected before the subprocess
-- finishes, which silently drops its completion callback (see adapters/shell_runner's
-- identical pin). Keys are the live handles; cleared in the callback / on a failed start.
local _active_probe_tasks = {}

-- Input-source mutations are serialized. A timed-out child remains the exact
-- owner until its native completion callback settles, so a successor cannot
-- overlap a still-running defaults/TIS transaction.
local _mutation_owner = nil


--- Invokes one optional mutation callback with visible traceback handling.
--- @param label string Callback label.
--- @param on_done function|nil Completion callback.
--- @param ... any Callback arguments.
local function invoke_mutation_done(label, on_done, ...)
	if type(on_done) ~= "function" then return end
	Logger.callback(LOG, label, on_done, ...)
end


--- Rejects a mutation before any in-process or native side effect when an exact
--- prior owner is still settling.
--- @param label string Operation label.
--- @param on_done function|nil Completion callback.
--- @return boolean busy True when the caller must return without mutating.
local function reject_if_mutation_busy(label, on_done)
	if _mutation_owner == nil then return false end
	Logger.warn(LOG, "%s refused: another input-source mutation is still settling.", label)
	invoke_mutation_done(label .. ".busy", on_done, false, nil, "busy", nil)
	return true
end


--- Releases the serialized mutation slot after both native owners settle.
--- @param owner table Exact mutation owner.
local function release_mutation_if_settled(owner)
	if _mutation_owner == owner
		and owner.task_settled == true
		and owner.deadline_settled == true then
		_mutation_owner = nil
	end
end


--- Runs one argv subprocess behind an owned hard deadline.
--- @param label string Operation label for logs and callback diagnostics.
--- @param executable string Absolute executable path.
--- @param args table Argument vector.
--- @param on_done function|nil fn(ok, stdout, reason, stderr).
--- @return boolean accepted True only when the subprocess start commits.
local function run_bounded_process(label, executable, args, on_done)
	if reject_if_mutation_busy(label, on_done) then return false end

	local owner = {
		label = label,
		terminal_sent = false,
		task_settled = false,
		deadline_settled = false,
		pending_terminal = nil,
	}
	_mutation_owner = owner

	local function publish_terminal(ok, stdout, reason, stderr)
		if owner.terminal_sent == true then return false end
		owner.terminal_sent = true
		invoke_mutation_done(label .. ".done", on_done, ok, stdout, reason, stderr)
		return true
	end

	local function publish_pending_terminal()
		local pending = owner.pending_terminal
		if pending == nil
			or owner.task_settled ~= true
			or owner.deadline_settled ~= true then
			return false
		end
		owner.pending_terminal = nil
		return publish_terminal(pending.ok, pending.stdout, pending.reason, pending.stderr)
	end

	local handle = ShellRunner.spawn(executable, args, function(exit_code, stdout, stderr)
		if owner.terminal_sent == true then return end
		local process_reason = nil
		if exit_code ~= 0 then process_reason = "process_failed" end
		owner.pending_terminal = {
			ok = exit_code == 0,
			stdout = stdout,
			reason = process_reason,
			stderr = stderr,
		}
		local deadline_settled = TimerScheduler.cancel(owner.deadline)
		if deadline_settled == true then owner.deadline_settled = true end
		publish_pending_terminal()
		release_mutation_if_settled(owner)
	end)
	owner.handle = handle

	local observed_task = handle.onSettled(function()
		owner.task_settled = true
		publish_pending_terminal()
		release_mutation_if_settled(owner)
	end)
	if observed_task ~= true then
		Logger.error(LOG, "%s could not observe subprocess settlement.", label)
	end
	if handle.isSettled() then
		owner.task_settled = true
		owner.deadline_settled = true
		publish_terminal(false, nil, "construction_failed", nil)
		release_mutation_if_settled(owner)
		return false
	end

	local deadline, deadline_committed = TimerScheduler.after(
		INPUT_SOURCE_OPERATION_TIMEOUT_SEC,
		function()
			if owner.terminal_sent == true then
				release_mutation_if_settled(owner)
				return
			end
			Logger.error(LOG, "%s timed out after %.1f seconds; terminating the exact child.",
				label, INPUT_SOURCE_OPERATION_TIMEOUT_SEC)
			-- Fence the business terminal before terminate(): a hostile native
			-- implementation may synchronously deliver completion from terminate().
			publish_terminal(false, nil, "timeout", nil)
			local terminated, state = handle.terminate()
			if terminated ~= true then
				Logger.error(LOG, "%s termination was refused; exact ownership is retained.", label)
			elseif state == "settled" then
				owner.task_settled = true
			end
			release_mutation_if_settled(owner)
		end)
	owner.deadline = deadline
	local observed_deadline = TimerScheduler.onSettled(deadline, function()
		owner.deadline_settled = true
		publish_pending_terminal()
		release_mutation_if_settled(owner)
	end)
	if observed_deadline ~= true then
		Logger.error(LOG, "%s could not observe deadline settlement.", label)
	end
	if deadline_committed ~= true then
		Logger.error(LOG, "%s refused: the subprocess deadline did not commit.", label)
		publish_terminal(false, nil, "deadline_unavailable", nil)
		local terminated, state = handle.terminate()
		if terminated == true and state == "settled" then owner.task_settled = true end
		release_mutation_if_settled(owner)
		return false
	end

	local started = handle.start()
	if started ~= true then
		Logger.error(LOG, "%s subprocess start did not commit.", label)
		local deadline_settled = TimerScheduler.cancel(deadline)
		if deadline_settled == true then owner.deadline_settled = true end
		publish_terminal(false, nil, "start_failed", nil)
		if handle.isSettled() then owner.task_settled = true end
		release_mutation_if_settled(owner)
		return false
	end
	return true
end

--- Clears the active-layout cache and resets the throttle so the next menu open
--- recomputes immediately. Called after the enabled input-source set changes.
local function invalidate_active_layouts_cache()
	_active_layouts_cache        = nil
	_active_layouts_last_refresh = 0
end

--- Test seam: overwrite the active-layout cache directly (latency tests prime it
--- without spawning the probe). Mirrors the former inline M._set_active_layouts_cache.
local function set_active_layouts_cache(records)
	_active_layouts_cache = records
end




-- ============================================
-- ============================================
-- ======= 1/ Input Source Enumeration ========
-- ============================================
-- ============================================

--- Extracts the Ergopti version embedded in an input-source identifier.
--- Supports both legacy ("com.apple.keyboardlayout.ergopti.v2_2_0") and
--- current macOS-standard ("com.apple.keylayout.ergopti.v2.2.1") forms.
--- @param name string Raw or cleaned layout name.
--- @return table|nil Numeric version components or nil if not an Ergopti id.
local function extract_ergopti_version(name)
	if type(name) ~= "string" then return nil end
	local lower = name:lower()
	if not lower:find("ergopti", 1, true) then return nil end
	-- Match v<major>(_|.)<minor>(_|.)<patch> after the ergopti keyword
	local maj, min, pat = lower:match("ergopti[._]v(%d+)[._%-](%d+)[._%-](%d+)")
	if maj then return { tonumber(maj), tonumber(min), tonumber(pat) } end
	-- Match shorter forms like ergopti_v2.2 or ergopti.v2
	local m1, m2 = lower:match("ergopti[._]v(%d+)[._%-](%d+)")
	if m1 then return { tonumber(m1), tonumber(m2), 0 } end
	local m = lower:match("ergopti[._]v(%d+)")
	if m then return { tonumber(m), 0, 0 } end
	-- An Ergopti layout with no version suffix is treated as version 0
	return { 0, 0, 0 }
end

--- Renders an Ergopti input-source identifier as a human-friendly display
--- name (e.g. "Ergopti+ v2.2.0 ANSI"). macOS normally provides this string
--- via the bundle's InfoPlist.strings file, but bundles generated before the
--- v2.2.2 fix used the keylayout filename as the localisation key instead of
--- the TISInputSourceID, so hs.keycodes fell back to the raw ID. This helper
--- recovers the pretty form purely from the ID structure.
--- @param id string Raw or already-prefix-stripped Ergopti identifier.
--- @return string|nil Friendly display name, or nil if the id is not Ergopti.
local function format_ergopti_display(id)
	if type(id) ~= "string" then return nil end
	local lower = id:lower()
	if not lower:find("ergopti", 1, true) then return nil end
	-- Variant detection — order matters: ++ before +, and symbol forms before word forms.
	-- "plus_plus" / "plus.plus" cover bundle IDs; "++" / "+" cover localised names
	-- returned by hs.keycodes (e.g. "Ergopti+" when TIS osascript is unavailable).
	local variant
	if lower:find("plus_plus") or lower:find("plus%.plus") or id:find("%+%+") then
		variant = "++"
	elseif lower:find("plus") or id:find("%+") then
		variant = "+"
	else
		variant = ""
	end
	local is_ansi = lower:find("ansi") ~= nil
	local v = extract_ergopti_version(id)
	local version_part = ""
	if v and (v[1] ~= 0 or v[2] ~= 0 or v[3] ~= 0) then
		version_part = string.format(" v%d.%d.%d", v[1] or 0, v[2] or 0, v[3] or 0)
	end
	local ansi_part = is_ansi and " ANSI" or ""
	return "Ergopti" .. variant .. ansi_part .. version_part
end

--- Runs an AppleScript in an owned, deadline-bounded child process so Carbon/TIS
--- failures stay contained without blocking the Hammerspoon runloop.
--- @param script string The AppleScript source code to execute.
--- @param on_done function|nil fn(ok, output, reason).
--- @return boolean accepted True only when the child start commits.
local function run_osascript_isolated_async(script, on_done)
	if type(script) ~= "string" or script == "" then
		invoke_mutation_done("osascript.reject", on_done, false, nil, "invalid_script")
		return false
	end
	return run_bounded_process("Input-source AppleScript", "/usr/bin/osascript",
		{ "-e", script }, on_done)
end

--- Enumerates every enabled keyboard-layout input source via Carbon TIS
--- in an isolated osascript subprocess. Returns a list of records:
---
---     { id = "com.apple.keylayout.ergopti.plus",
---       name = "Ergopti+",
---       selected = false }
---
--- The result is filtered to ``kTISTypeKeyboardLayout`` so non-keyboard
--- entries that always sit in ``AppleEnabledInputSources`` (PressAndHold,
--- CharacterPalette, IMEs) are dropped at the source rather than after the
--- fact. Exactly one record carries ``selected = true`` — the layout
--- macOS would route a keystroke to right now — which is what the menu
--- uses to render the checkmark on the active row.
---
--- A defensive Lua-side filter also drops ids that look like input methods
--- or services in case the TIS type predicate is partially honoured by
--- older macOS versions.
---
--- Returns an empty list when osascript or TIS fails (logged), so callers
--- can fall back to a "no layout" placeholder without having to handle
--- nil. Pure-Lua test runs without the native task adapter hit this branch silently.
--- @return table List of input-source records (possibly empty).
--- Reads AppleEnabledInputSources from HIToolbox via a Python plist parser and
--- returns a list of records {id, name, selected} for every enabled keyboard
--- layout. Using Python avoids the regex-on-XML fragility that caused duplicate
--- entries when the same KeyboardLayout Name appeared in multiple plist sections.
--- HIToolbox is the macOS source of truth — changes in System Settings are
--- reflected immediately, without the TIS cache lag from osascript/hs.keycodes.
-- The python that reads AppleEnabledInputSources from HIToolbox via cfprefsd.
-- Kept as a module constant so the probe can run ASYNCHRONOUSLY (hs.task) off the
-- menu-open path instead of blocking the click with a python3 cold start. Reading
-- via `defaults export` (cfprefsd) reflects System Settings changes immediately,
-- unlike reading the plist file directly which can return stale entries.
local ACTIVE_LAYOUTS_PY = [[
import subprocess, sys, plistlib, json

DOMAIN = "com.apple.HIToolbox"
KEY    = "AppleEnabledInputSources"

# Read via cfprefsd (defaults export) — reflects System Settings changes
# immediately, unlike reading the plist file directly which can be stale.
try:
    raw = subprocess.check_output(
        ["defaults", "export", DOMAIN, "-"], stderr=subprocess.DEVNULL)
    prefs = plistlib.loads(raw)
except Exception as e:
    print("ERR:" + str(e)); sys.exit(1)

sources = prefs.get(KEY, [])
out = []
for s in sources:
    kind = s.get("InputSourceKind", "")
    name = s.get("KeyboardLayout Name", "")
    if name and (kind == "Keyboard Layout" or kind == ""):
        out.append(name)
print(json.dumps(out))
]]

--- Returns whether a record is the currently-selected layout, comparing the raw
--- KeyboardLayout Name and the localised display against the current layout name.
--- hs.keycodes.currentLayout() may return the localised display name, the raw
--- KeyboardLayout Name, or a version-stripped variant — all three are accepted.
--- @param kl_name string Raw KeyboardLayout Name (record id).
--- @param display string Localised display name.
--- @param current_name string|nil hs.keycodes.currentLayout() value.
--- @return boolean
local function is_record_selected(kl_name, display, current_name)
	if not current_name then return false end
	if kl_name == current_name or display == current_name then return true end
	local display_no_space = display:gsub("%s+", ""):lower()
	local current_lower    = current_name:lower():gsub("%s+", "")
	return display_no_space == current_lower
end

--- Parses the JSON array of KeyboardLayout Names emitted by the HIToolbox probe
--- into menu records. Pure (no I/O), so it is unit-testable and never runs a
--- subprocess. `selected` is computed live against current_name.
--- @param raw_out string|nil Probe stdout (a JSON array of strings).
--- @param current_name string|nil hs.keycodes.currentLayout() value.
--- @return table|nil records, or nil when raw_out is not a parseable array.
local function parse_active_layouts(raw_out, current_name)
	if type(raw_out) ~= "string" or raw_out:sub(1, 1) ~= "[" then return nil end
	local out = {}
	for kl_name in raw_out:gmatch('"([^"]+)"') do
		-- For Ergopti entries the localised name is produced by format_ergopti_display
		-- (e.g. "Ergopti+" for "Ergopti_v2_2_2_plus"). Other layouts: strip the
		-- underscores and any version suffix. This localised name is what
		-- hs.keycodes.setLayout() and currentLayout() understand.
		local ergopti_display = format_ergopti_display(kl_name)
		local display = ergopti_display or kl_name:gsub("_", " "):gsub("%s+v%d.*$", "")
		out[#out + 1] = { id = kl_name, name = display, selected = is_record_selected(kl_name, display, current_name) }
	end
	return out
end

--- Fast, in-process active-layout list via hs.keycodes (no subprocess). Used as
--- the cold-cache fallback so the FIRST menu open stays instant; the accurate
--- HIToolbox list replaces it asynchronously. May briefly show TIS-cache-lagged
--- or duplicate entries — corrected on the next open.
--- @param current_name string|nil hs.keycodes.currentLayout() value.
--- @return table records (possibly empty).
local function compute_active_layouts_fast(current_name)
	local out = {}
	if hs.keycodes and type(hs.keycodes.layouts) == "function" then
		local layouts = hs.keycodes.layouts() or {}
		for _, name in ipairs(layouts) do
			local display = format_ergopti_display(name) or name
			out[#out + 1] = { id = name, name = display, selected = is_record_selected(name, display, current_name) }
		end
	end
	return out
end

--- Refreshes _active_layouts_cache asynchronously via hs.task so the expensive
--- python3 + `defaults export` round-trip NEVER blocks a menu open. The probe is
--- passed inline with `python3 -c` (a single argv element — no temp file, no
--- shell quoting). On a headless run (no hs.task — unit tests / CLI) the probe is
--- skipped and the previous cache is kept. on_done (if given) fires when complete.
--- @param on_done function|nil Callback invoked after the cache is updated.
local function refresh_active_layouts_async(on_done)
	if _active_layouts_refreshing then
		if on_done then Logger.pcall(LOG, on_done) end
		return
	end
	_active_layouts_refreshing = true

	local current_name = (hs.keycodes and type(hs.keycodes.currentLayout) == "function")
		and hs.keycodes.currentLayout() or nil

	local function finish(raw_out)
		_active_layouts_refreshing = false
		local records = parse_active_layouts(raw_out, current_name)
		if records then
			_active_layouts_cache = records
			Logger.debug(LOG, "Active layouts refreshed asynchronously: %d.", #records)
		else
			Logger.warn(LOG, "Async active-layout probe returned unparseable output — keeping previous cache.")
		end
		if on_done then Logger.pcall(LOG, on_done) end
	end

	if hs.task and type(hs.task.new) == "function" then
		-- Non-blocking: the click handler returns immediately; the cache updates
		-- when python3 finishes and is read on the NEXT open. The handle is
		-- forward-declared ABOVE its callback (closure-nil rule) and pinned in a
		-- GC root for the whole subprocess lifetime — python3 cold-start is
		-- 300 ms–1 s and an unreferenced async handle could be collected before it
		-- fires, dropping the callback so finish() never runs and the refresh flag
		-- stays wedged true for the session.
		local probe_task
		probe_task = TaskLifecycle.native("Active keyboard-layout probe", "/usr/bin/python3", function(_code, stdout, _stderr)
				if probe_task then _active_probe_tasks[probe_task] = nil end
				Logger.pcall(LOG, finish, stdout)
			end, { "-c", ACTIVE_LAYOUTS_PY })
		if probe_task then
			_active_probe_tasks[probe_task] = true
			if not TaskLifecycle.start(probe_task, "Active keyboard-layout probe") then
				_active_probe_tasks[probe_task] = nil
				probe_task = nil
				finish(nil)
			end
		else
			finish(nil)
		end
	else
		finish(nil)
	end
end

--- Schedules a throttled async active-layout refresh so rapid menu opens never
--- spawn overlapping probes.
--- @param force boolean|nil When true, bypasses the throttle (startup prime).
local function maybe_refresh_active_layouts(force)
	local now = (hs.timer and type(hs.timer.secondsSinceEpoch) == "function")
		and hs.timer.secondsSinceEpoch() or nil
	if not force and now and (now - _active_layouts_last_refresh) < ACTIVE_LAYOUTS_REFRESH_THROTTLE_SEC then
		return
	end
	if now then _active_layouts_last_refresh = now end
	refresh_active_layouts_async(nil)
end

--- Returns the active keyboard-layout records for the menu WITHOUT blocking.
--- Serves the memoised HIToolbox result when available (recomputing the live
--- `selected` flag so a layout switch reflects instantly), otherwise an in-process
--- fast list. Either way it schedules a throttled async refresh so the cache is
--- accurate for the next open. This call used to run python3 SYNCHRONOUSLY here,
--- which is what made the menubar take ~1 s to open.
--- @return table List of input-source records (possibly empty).
local function list_active_keyboard_layouts()
	local current_name = (hs.keycodes and type(hs.keycodes.currentLayout) == "function")
		and hs.keycodes.currentLayout() or nil
	if _active_layouts_cache then
		for _, r in ipairs(_active_layouts_cache) do
			r.selected = is_record_selected(r.id or "", r.name or "", current_name)
		end
		maybe_refresh_active_layouts(false)
		return _active_layouts_cache
	end
	maybe_refresh_active_layouts(false)
	return compute_active_layouts_fast(current_name)
end

-- Forward-declared because set_input_source_async (below) calls it in its TIS fallback
-- path, but the definition appears later in the file. Without this the name resolves
-- to a global nil at the call site (silently) and the fallback never runs.
local build_kl_name_to_tis_id

--- Activates the given keyboard layout.
--- Strategy (in order):
---   1. hs.keycodes.setLayout(localised_name) — works for standard layouts and
---      Ergopti when the bundle localisation is intact. "French" and "Ergopti+"
---      are the forms macOS publishes; the raw KeyboardLayout Name (e.g.
---      "Ergopti_v2_2_2_plus") is NOT accepted by setLayout.
---   2. hs.keycodes.setLayout(kl_name) — fallback using the internal name in case
---      the localised form differs from what hs.keycodes expects.
---   3. TISSelectInputSource via osascript with the stable TIS ID resolved from
---      kl_name through build_kl_name_to_tis_id() — covers Ergopti variants on
---      macOS Sequoia where setLayout fails for third-party bundles.
--- @param localised_name string The display / localised name (r.name), e.g. "French".
--- @param kl_name string The raw KeyboardLayout Name (r.id), e.g. "Ergopti_v2_2_2_plus".
--- @param on_done function|nil fn(ok, output, reason).
--- @return boolean accepted True for an immediate switch or committed fallback child.
local function set_input_source_async(localised_name, kl_name, on_done)
	if reject_if_mutation_busy("Input-source selection", on_done) then return false end
	if hs.keycodes and type(hs.keycodes.setLayout) == "function" then
		-- Both attempts bind `changed` — pcall's SECOND return, i.e. setLayout's
		-- own result. setLayout returns a boolean and does NOT raise on an
		-- unknown or unswitchable layout, so reading only pcall's status made
		-- `ok` true on every call: the function returned success at the first
		-- attempt, the kl_name retry and the TIS fallback below became dead
		-- code, and a failed switch was affirmatively logged as a success.
		-- Try the localised name first — this is what hs.keycodes expects
		if type(localised_name) == "string" and localised_name ~= "" then
			local ok, changed = pcall(hs.keycodes.setLayout, localised_name)
			if ok and changed == true then
				Logger.info(LOG, "Active layout switched to '%s' (hs.keycodes, localised).", localised_name)
				invoke_mutation_done("set_input_source.localised", on_done, true, nil, nil)
				return true
			end
			Logger.debug(LOG, "hs.keycodes declined the localised name '%s' — trying the next strategy…", localised_name)
		end
		-- Try the raw KeyboardLayout Name as a secondary candidate
		if type(kl_name) == "string" and kl_name ~= "" and kl_name ~= localised_name then
			local ok, changed = pcall(hs.keycodes.setLayout, kl_name)
			if ok and changed == true then
				Logger.info(LOG, "Active layout switched to '%s' (hs.keycodes, kl_name).", kl_name)
				invoke_mutation_done("set_input_source.kl_name", on_done, true, nil, nil)
				return true
			end
			Logger.debug(LOG, "hs.keycodes declined the kl_name '%s' — falling back to TIS…", kl_name)
		end
	end
	-- Resolve the stable TIS ID for Ergopti variants via the installed bundle map,
	-- then fall back to using kl_name directly as the TIS ID for standard layouts.
	local tis_id = kl_name or localised_name or ""
	if type(kl_name) == "string" and kl_name ~= "" then
		local kl_map = build_kl_name_to_tis_id() or {}
		tis_id = kl_map[kl_name] or kl_name
	end
	local script = text_utils.applescript_format([[
use framework "Carbon"
use framework "Foundation"
on run
	set theProps to current application's NSDictionary's dictionaryWithObjects:{"%s"} forKeys:{"TISPropertyInputSourceID"}
	set theSources to current application's TISCreateInputSourceList(theProps, true)
	if theSources is not missing value and (count of (theSources as list)) > 0 then
		set theSource to item 1 of (theSources as list)
		current application's TISSelectInputSource(theSource)
		return "OK"
	end if
	return "MISS"
end run
]], tis_id)
	return run_osascript_isolated_async(script, function(process_ok, out, reason)
		local out_text = tostring(out or ""):gsub("[\r\n]+$", "")
		local switched = process_ok == true and out_text == "OK"
		if switched then
			Logger.info(LOG, "Active layout switched to '%s' (TIS subprocess, tis_id=%s).",
				localised_name or kl_name, tis_id)
			invoke_mutation_done("set_input_source.tis", on_done, true, out_text, nil)
			return
		end
		local failure_reason = reason or "invalid_output"
		Logger.warn(LOG, "Failed to switch active layout to '%s' / '%s' (tis_id=%s, reason=%s).",
			tostring(localised_name), tostring(kl_name), tis_id, failure_reason)
		invoke_mutation_done("set_input_source.tis", on_done, false, out_text, failure_reason)
	end)
end

--- Returns a set of TIS IDs for Ergopti variants currently present in
--- AppleEnabledInputSources, read directly from HIToolbox via `defaults export`.
--- Maps KeyboardLayout Name (internal name) back to TIS IDs via ERGOPTI_VARIANTS.
--- This bypasses the TIS osascript path that fails on macOS Sequoia.
--- @return table Set of TIS IDs, e.g. { ["com.apple.keyboardlayout.ergopti.plus"] = true }.
--- Builds a mapping from KeyboardLayout Name (internal HIToolbox name) to stable TIS ID
--- for every variant in the currently installed bundle. Returns nil if no bundle is installed.
--- Example: { ["Ergopti_v2_2_2_plus"] = "com.apple.keyboardlayout.ergopti.plus", ... }
--- @return table|nil
function build_kl_name_to_tis_id()
	local sb_sys  = highest_installed(SYSTEM_LAYOUTS_DIR)
	local sb_user = highest_installed(USER_LAYOUTS_DIR)
	local sb      = sb_sys or sb_user
	local sb_dir  = sb_sys and SYSTEM_LAYOUTS_DIR or (sb_user and USER_LAYOUTS_DIR) or nil
	if not sb or not sb_dir then return nil end
	local installed_bundle = sb.name:gsub("%.bundle$", ""):gsub("%.", "_")
	local bundle_path = sb_dir:gsub("[/\\]$", "") .. "/" .. sb.name
	local map = {}
	for _, var in ipairs(ERGOPTI_VARIANTS) do
		local internal   = installed_bundle .. (var.suffix or "")
		local keylayout  = bundle_path .. "/Contents/Resources/" .. internal .. ".keylayout"
		if path_exists(keylayout) then
			map[internal] = var.id
		end
	end
	return map
end


--- Adds the given TIS input source to the user's enabled-list via
--- `defaults write com.apple.HIToolbox`, then restarts SystemUIServer so
--- the change takes effect immediately.
---
--- The Carbon TIS ObjC-bridge approach (TISCreateInputSourceList +
--- TISEnableInputSource called from osascript) was tried extensively but
--- crashes silently on macOS Sequoia: NSMutableDictionary bridged to
--- CFDictionaryRef causes osascript to exit without writing any output,
--- leaving the Lua caller with status=<no-output>. The `defaults write`
--- approach is what Karabiner-Elements and other third-party tools use and
--- is known to work reliably on macOS 12–15.
---
--- The AppleEnabledInputSources preference is an array of dicts. We read
--- the current list, check whether the target ID is already present, append
--- it if not, and write back.  The whole operation is a single Python 3
--- one-liner that ships with macOS and needs no extra dependencies.
--- @param raw_id string TISInputSourceID, e.g. "com.apple.keyboardlayout.ergopti.plus".
--- @param label string Human-readable label used in log messages.
--- @param on_done function|nil fn(ok, output, reason).
--- @return boolean accepted True only when the child start commits.
local function enable_and_select_source_async(raw_id, label, bundle_path, internal_name, on_done)
	if type(raw_id) ~= "string" or raw_id == "" then
		invoke_mutation_done("enable_source.reject", on_done, false, nil, "invalid_id")
		return false
	end
	if type(bundle_path) ~= "string" or bundle_path == "" then
		Logger.error(LOG, "enable_and_select_source_async: bundle_path missing for '%s'.", raw_id)
		invoke_mutation_done("enable_source.reject", on_done, false, nil, "invalid_bundle")
		return false
	end
	if type(internal_name) ~= "string" or internal_name == "" then
		Logger.error(LOG, "enable_and_select_source_async: internal_name missing for '%s'.", raw_id)
		invoke_mutation_done("enable_source.reject", on_done, false, nil, "invalid_name")
		return false
	end
	local display = (type(label) == "string" and label ~= "") and label or raw_id

	-- bundle_path: absolute path to the installed .bundle directory
	-- internal_name: the keylayout filename base (e.g. "Ergopti_v2_2_2_plus")
	-- The correct HIToolbox entry format matches macOS built-in layouts (e.g. French):
	--   InputSourceKind  → "Keyboard Layout"
	--   KeyboardLayout ID   → integer id= from the .keylayout XML (no Bundle ID needed)
	--   KeyboardLayout Name → name= from the .keylayout XML (= internal_name)
	-- Adding a Bundle ID or using a string for KeyboardLayout ID causes macOS to silently
	-- ignore the entry at next login / SystemUIServer restart.
	local py_script = [[
import subprocess, sys, plistlib, re, os, signal, time

DOMAIN        = "com.apple.HIToolbox"
KEY           = "AppleEnabledInputSources"
BUNDLE_PATH   = sys.argv[1]
INTERNAL_NAME = sys.argv[2]
CHILD_TIMEOUT = float(sys.argv[3])
DEADLINE      = time.monotonic() + CHILD_TIMEOUT
ACTIVE_CHILD  = None

def stop_active_child():
    global ACTIVE_CHILD
    child = ACTIVE_CHILD
    if child is None or child.poll() is not None:
        return
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        child.wait(timeout=1)
    except Exception:
        pass

def terminate_with_parent(_signum, _frame):
    stop_active_child()
    raise SystemExit(124)

signal.signal(signal.SIGTERM, terminate_with_parent)

def run_child(args, capture_stdout=False):
    global ACTIVE_CHILD
    remaining = DEADLINE - time.monotonic()
    if remaining <= 0:
        raise subprocess.TimeoutExpired(args, CHILD_TIMEOUT)
    stdout_target = subprocess.PIPE if capture_stdout else subprocess.DEVNULL
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
    try:
        child = subprocess.Popen(
            args, stdout=stdout_target, stderr=subprocess.DEVNULL,
            start_new_session=True)
        ACTIVE_CHILD = child
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    try:
        stdout, _stderr = child.communicate(timeout=remaining)
    except subprocess.TimeoutExpired:
        stop_active_child()
        raise
    finally:
        ACTIVE_CHILD = None
    if child.returncode != 0:
        raise subprocess.CalledProcessError(child.returncode, args)
    return stdout

# Extract KeyboardLayout ID (integer) from the .keylayout XML
keylayout_file = os.path.join(BUNDLE_PATH, "Contents", "Resources", INTERNAL_NAME + ".keylayout")
try:
    with open(keylayout_file, "r", encoding="utf-8") as f:
        content = f.read(4096)
    m = re.search(r'<keyboard\b[^>]*\bid=["\']?(-?\d+)["\']?', content)
    if not m:
        print("PARSE_ERR:no id= in " + keylayout_file); sys.exit(1)
    kl_id = int(m.group(1))
except Exception as e:
    print("PARSE_ERR:" + str(e)); sys.exit(1)

try:
    raw = run_child(["defaults", "export", DOMAIN, "-"], capture_stdout=True)
    prefs = plistlib.loads(raw)
except Exception as e:
    print("READ_ERR:" + str(e)); sys.exit(1)

sources = prefs.get(KEY, [])

# Remove only entries that are stale for THIS variant:
#   - any Ergopti entry that still has a Bundle ID (wrong legacy format), OR
#   - the exact same KeyboardLayout Name we are about to add (dedup).
# Other Ergopti variants that are already clean are left untouched.
def is_stale_entry(s):
    bid  = s.get("Bundle ID", "")
    name = s.get("KeyboardLayout Name", "")
    if "ergopti" in bid.lower(): return True
    if name == INTERNAL_NAME: return True
    return False

sources = [s for s in sources if not is_stale_entry(s)]

# Format mirrors macOS built-in keyboard layout entries (e.g. French):
# no Bundle ID, KeyboardLayout ID is a native integer in the plist.
sources.append({
    "InputSourceKind":     "Keyboard Layout",
    "KeyboardLayout ID":   kl_id,
    "KeyboardLayout Name": INTERNAL_NAME,
})
prefs[KEY] = sources

plist_bytes = plistlib.dumps(prefs, fmt=plistlib.FMT_XML)
import tempfile
with tempfile.NamedTemporaryFile(suffix=".plist", delete=False) as f:
    f.write(plist_bytes)
    tmp = f.name

try:
    run_child(["defaults", "import", DOMAIN, tmp])
finally:
    os.unlink(tmp)

# Reload the input-source list. launchctl kickstart is safer than killall
# on Sequoia: it re-spawns the agent cleanly without flushing the cfprefsd cache.
uid = str(os.getuid())
run_child(["launchctl", "kickstart", "-k", "user/" + uid + "/com.apple.SystemUIServer"])
print("OK")
]]

	local nested_timeout = math.max(1, INPUT_SOURCE_OPERATION_TIMEOUT_SEC - 1)
	return run_bounded_process("Enable keyboard input source", "/usr/bin/python3",
		{ "-c", py_script, bundle_path, internal_name, tostring(nested_timeout) },
		function(process_ok, out, reason)
			local out_text = tostring(out or ""):gsub("[\r\n]+$", "")
			local enabled = process_ok == true
				and (out_text == "OK" or out_text == "ALREADY_PRESENT")
			if enabled then
				invalidate_active_layouts_cache()
				Logger.success(LOG, "Input source '%s' (%s) added to enabled list (%s).",
					display, raw_id, out_text)
				invoke_mutation_done("enable_source.done", on_done, true, out_text, nil)
				return
			end
			local failure_reason = reason or "invalid_output"
			Logger.warn(LOG, "Failed to add '%s' (%s) — reason=%s.",
				display, raw_id, failure_reason)
			invoke_mutation_done("enable_source.done", on_done, false, out_text, failure_reason)
		end)
end

--- Returns true if the given layout name looks like a legacy versioned Ergopti
--- identifier (pre-v2.2.2 form: 'com.apple.keyboardlayout.ergopti.v2_2_1.plus'),
--- OR the short-namespace form mistakenly used between v2.2.2 and the
--- com.apple.keylayout.* fix ('com.apple.keylayout.ergopti.*' — never registered
--- by macOS, but may be in users' active-list from a previous install attempt).
--- Both forms must be replaced by their stable third-party counterparts.
--- @param name string
--- @return boolean
local function is_legacy_ergopti_id(name)
	if type(name) ~= "string" then return false end
	local lower = name:lower()
	-- Versioned IDs (any namespace)
	if lower:find("ergopti[._]v%d", 1) ~= nil then return true end
	-- Short reserved namespace, only for Ergopti
	if lower:find("^com%.apple%.keylayout%.ergopti", 1) ~= nil then return true end
	return false
end

--- Maps a legacy Ergopti identifier to its v2.2.2+ stable equivalent.
--- com.apple.keyboardlayout.ergopti.v2_2_0[.suffix] → com.apple.keyboardlayout.ergopti[.suffix]
--- com.apple.keylayout.ergopti[.suffix]            → com.apple.keyboardlayout.ergopti[.suffix]
--- @param old string
--- @return string
local function migrate_legacy_id(old)
	if type(old) ~= "string" then return old end
	-- Lift the short reserved namespace to the third-party one.
	local m = old:gsub("^com%.apple%.keylayout%.", "com.apple.keyboardlayout.")
	-- Strip the version segment .vX_Y_Z (or .vX.Y.Z) wherever it appears.
	m = m:gsub("%.v%d+[._]%d+[._]%d+", "")
	m = m:gsub("%.v%d+[._]%d+", "")
	m = m:gsub("%.v%d+", "")
	return m
end

--- Replaces legacy Ergopti entries in the user's active input-source list with
--- their v2.2.2+ stable-id equivalents, then re-activates the appropriate
--- variant. Uses TISDisableInputSource / TISEnableInputSource via the
--- AppleScript ObjC bridge so no external tooling is required.
--- The latest bundle MUST already be installed locally — TIS only enables
--- input sources for layouts present on disk.
--- @param legacy_active table TIS ids from list_active_keyboard_layouts() that look legacy.
--- @param on_done function|nil fn(ok, output, reason).
--- @return boolean accepted True only when the child start commits.
local function upgrade_active_list_async(legacy_active, on_done)
	if type(legacy_active) ~= "table" or #legacy_active == 0 then
		invoke_mutation_done("upgrade_active_list.reject", on_done, false, nil, "invalid_entries")
		return false
	end
	-- Build the AppleScript: a sequence of disable+enable operations
	local lines = {
		"use framework \"Carbon\"",
		"use framework \"Foundation\"",
		"on findSource(theID)",
		"\tset theProps to current application's NSDictionary's dictionaryWithObjects:{theID} forKeys:{\"TISPropertyInputSourceID\"}",
		"\tset theSources to current application's TISCreateInputSourceList(theProps, true)",
		"\tif theSources is missing value then return missing value",
		"\tset theList to theSources as list",
		"\tif (count of theList) = 0 then return missing value",
		"\treturn item 1 of theList",
		"end findSource",
		"on run",
		"\tset disabled to {}",
		"\tset enabled to {}",
	}
	-- Disable each legacy id, then enable its migrated equivalent. The last
	-- migrated id is also selected so the active layout follows the upgrade.
	local last_new
	for _, old in ipairs(legacy_active) do
		local new_id = migrate_legacy_id(old)
		last_new = new_id
		table.insert(lines, text_utils.applescript_format("\tset oldSrc to my findSource(\"%s\")", old))
		table.insert(lines, "\tif oldSrc is not missing value then")
		table.insert(lines, "\t\tcurrent application's TISDisableInputSource(oldSrc)")
		table.insert(lines, "\t\tset end of disabled to oldSrc")
		table.insert(lines, "\tend if")
		table.insert(lines, text_utils.applescript_format("\tset newSrc to my findSource(\"%s\")", new_id))
		table.insert(lines, "\tif newSrc is not missing value then")
		table.insert(lines, "\t\tcurrent application's TISEnableInputSource(newSrc)")
		table.insert(lines, "\t\tset end of enabled to newSrc")
		table.insert(lines, "\tend if")
	end
	if last_new then
		table.insert(lines, text_utils.applescript_format("\tset selSrc to my findSource(\"%s\")", last_new))
		table.insert(lines, "\tif selSrc is not missing value then current application's TISSelectInputSource(selSrc)")
	end
	-- Both counts coerced to text FIRST. AppleScript's & on two non-string
	-- operands builds a LIST, so this returned "1, /, 2" rather than "1/2" and the
	-- Lua pattern below matched nothing — enabled_n stayed nil, the > 0 test
	-- failed, and every SUCCESSFUL upgrade was reported to the user as a failure.
	table.insert(lines, "\treturn ((count of disabled) as text) & \"/\" & ((count of enabled) as text)")
	table.insert(lines, "end run")
	local script = table.concat(lines, "\n")
	Logger.start(LOG, "Upgrading %d legacy Ergopti entry(ies) in the active input-source list…", #legacy_active)
	return run_osascript_isolated_async(script, function(process_ok, out, reason)
		-- osascript exits 0 even when findSource resolved nothing, so the status
		-- bit is insufficient. Require the script's own enabled count.
		local out_text = tostring(out or ""):gsub("[\r\n]+$", "")
		local _disabled_n, enabled_n = out_text:match("^(%d+)%s*/%s*(%d+)$")
		local upgraded = process_ok == true and tonumber(enabled_n or 0) ~= nil
			and tonumber(enabled_n or 0) > 0
		if upgraded then
			invalidate_active_layouts_cache()
			Logger.success(LOG, "List upgrade applied (%s).", out_text)
			invoke_mutation_done("upgrade_active_list.done", on_done, true, out_text, nil)
			return
		end
		local failure_reason = reason or "invalid_output"
		Logger.error(LOG, "List upgrade failed (reason=%s).", failure_reason)
		invoke_mutation_done("upgrade_active_list.done", on_done, false, out_text, failure_reason)
	end)
end

--- Strips the Apple keylayout / keyboardlayout / inputmethod prefixes from a
--- raw input-source identifier and reformats Ergopti entries into their
--- friendly form (e.g. "Ergopti+ v2.2.0 ANSI"). Non-Ergopti layouts keep
--- their verbose-prefix-stripped form so "com.apple.keylayout.French"
--- becomes "French".
--- @param name string Raw layout name as returned by hs.keycodes.layouts.
--- @return string Cleaned name suitable for display.
local function clean_layout_name(name)
	if type(name) ~= "string" then return tostring(name) end
	-- For Ergopti, prefer the pretty formatter so a broken-localisation bundle
	-- still renders nicely in the menu
	local pretty = format_ergopti_display(name)
	if pretty then return pretty end
	return (name
		:gsub("^com%.apple%.keylayout%.", "")
		:gsub("^com%.apple%.keyboardlayout%.", "")
		:gsub("^com%.apple%.inputmethod%.", "")
		:gsub("^com%.apple%.inputsource%.", ""))
end

--- Returns the highest Ergopti version installed across the user and system
--- keyboard-layout directories, or nil when none is present.
--- @return table|nil Numeric version components, e.g. {2,2,1}.
local function resolve_installed_ergopti_version()
	local user_best   = highest_installed(USER_LAYOUTS_DIR)
	local system_best = highest_installed(SYSTEM_LAYOUTS_DIR)
	if user_best and system_best then
		return version_gt(user_best.version, system_best.version)
			and user_best.version or system_best.version
	end
	return (user_best and user_best.version) or (system_best and system_best.version) or nil
end

--- Inspects the active input-source list and reports whether an Ergopti
--- layout is present along with the version the user is running.
---
--- v2.2.2+ bundles publish a stable TIS id (``com.apple.keylayout.ergopti.plus``)
--- with no version segment, so :func:`extract_ergopti_version` returns
--- ``{0,0,0}`` for those entries — the version lives only in the bundle
--- filename. We fall back to the highest version found on disk so the menu
--- never has to display ``v0.0.0`` for an entry that the user is happily
--- running.
--- @param records table List of records from :func:`list_active_keyboard_layouts`.
--- @return table { present = boolean, name = string|nil, id = string|nil, version = table|nil }
local function ergopti_in_active_layouts(records)
	for _, r in ipairs(records) do
		local id = (r and r.id) or ""
		if type(id) == "string" and id:lower():find("ergopti", 1, true) then
			local v = extract_ergopti_version(id)
			-- Stable-id entries (no version embedded): substitute the version
			-- of whatever bundle is installed locally.
			if v and v[1] == 0 and v[2] == 0 and v[3] == 0 then
				v = resolve_installed_ergopti_version() or v
			end
			return { present = true, name = r.name, id = id, version = v }
		end
	end
	return { present = false }
end



return {
	ERGOPTI_VARIANTS              = ERGOPTI_VARIANTS,
	extract_ergopti_version       = extract_ergopti_version,
	format_ergopti_display        = format_ergopti_display,
	parse_active_layouts          = parse_active_layouts,
	compute_active_layouts_fast   = compute_active_layouts_fast,
	refresh_active_layouts_async  = refresh_active_layouts_async,
	list_active_keyboard_layouts  = list_active_keyboard_layouts,
	set_input_source_async        = set_input_source_async,
	enable_and_select_source_async = enable_and_select_source_async,
	is_legacy_ergopti_id          = is_legacy_ergopti_id,
	migrate_legacy_id             = migrate_legacy_id,
	upgrade_active_list_async     = upgrade_active_list_async,
	clean_layout_name             = clean_layout_name,
	resolve_installed_ergopti_version = resolve_installed_ergopti_version,
	ergopti_in_active_layouts     = ergopti_in_active_layouts,
	build_kl_name_to_tis_id       = build_kl_name_to_tis_id,
	set_active_layouts_cache      = set_active_layouts_cache,
}
