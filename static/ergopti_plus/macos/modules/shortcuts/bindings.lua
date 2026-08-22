--- modules/shortcuts/bindings.lua

--- ==============================================================================
--- MODULE: Shortcuts Bindings Registry
--- DESCRIPTION:
--- Declares every system-wide hotkey, wires it to the correct action module, and
--- manages the enable/disable lifecycle for each shortcut individually.
---
--- FEATURES & RATIONALE:
--- 1. Declarative Routing: Each shortcut is a one-liner in hotkey_defs, keeping
---    the registry easy to scan and extend.
--- 2. Uniform Lifecycle: All shortcut objects — whether hs.hotkey or eventtap —
---    expose a :delete() method so M.enable/M.disable works identically for all.
--- ==============================================================================

local M = {}

local hs          = hs
local text_acts   = require("modules.shortcuts.actions.text")
local sys_acts    = require("modules.shortcuts.actions.system")
local app_acts    = require("modules.shortcuts.actions.apps")
local Logger      = require("infra.logger")
local i18n        = require("infra.i18n")
local Manifest    = require("infra.manifest_reader")

local LOG = "shortcuts.bindings"





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

-- Sourced from the manifest (the cross-driver SSoT, platforms ahk+hs) rather
-- than re-declared, so a change to shortcuts.chatgpt_url cannot diverge from the
-- AHK driver (which reads the same default from its generated map). Fails fast
-- if the path is absent.
M.DEFAULT_CHATGPT_URL = Manifest.default_for("shortcuts.chatgpt_url")
local SHORTCUT_ACTION_PARENT = "shortcut_bindings"

local hotkeys       = {}   -- Active hotkey/tap objects, keyed by shortcut id
local hotkey_defs   = {}   -- Factory functions that create and return a hotkey object
local hotkey_labels = {}   -- User-facing French label for each shortcut

-- Shortcuts explicitly disabled via M.disable() survive a stop/start cycle so
-- that a resume after focus loss cannot silently re-enable a hotkey the caller
-- intentionally turned off (shortcuts-bindings-reenable-on-resume).
local _disabled_set = {}

local started = false
local awake_cleanup_pending = false
-- Logical delivery fence for hs.hotkey.bind callbacks. Native delete() can
-- refuse during a transactional rollback; the retained callback must still be
-- inert as soon as ScriptControl asks this owner to pause.
local delivery_enabled = false
-- A ScriptControl PAUSE may be retried after partial cleanup. Preserve whether
-- Bindings was actually ON at the first edge so cleanup of an already-OFF layer
-- can never manufacture a later ON transition.
local pause_restore_intent = nil
local lifecycle_paused = false
local lifecycle_epoch = 0
local start_attempt = nil
local native_acquisition_depth = 0
-- A layout replacement starts from a logically-ON layer but temporarily sets
-- `started=false` while native hotkeys are exchanged. Preserve that intent
-- independently so a re-entrant PAUSE can restore keep-awake exactly.
local rebind_recovery_intent = false

local EXACT_RELEASE_IDS = {
	at_hash = true,
	layer_scroll = true,
	cmd_star = true,
	wrap_text_if_selected = true,
}

local function invalidate_lifecycle()
	lifecycle_epoch = lifecycle_epoch + 1
end

local function admission_open(attempt)
	return lifecycle_paused ~= true
		and (attempt == nil or (start_attempt == attempt
			and lifecycle_epoch == attempt.epoch))
end

local function delivery_admitted()
	return delivery_enabled == true and lifecycle_paused ~= true
end

-- Exact child contracts stay in one ordered registry. This is the lifecycle
-- inventory, not the hotkey/action routing table: every entry is synchronously
-- fenced before Bindings can report a settled pause.
local child_owners = {
	{
		id = "text",
		subject = text_acts,
		pause = "pause_text_actions",
		resume = "resume_text_actions",
		stop = "stop_text_actions",
		is_paused = "is_text_actions_paused",
		has_pending = "has_pending_text_action",
		claim = SHORTCUT_ACTION_PARENT,
	},
	{
		id = "apps",
		subject = app_acts,
		pause = "pause_apps_actions",
		resume = "resume_apps_actions",
		stop = "stop_apps_actions",
		is_paused = "is_apps_actions_paused",
		has_pending = "has_pending_apps_action",
	},
	{
		id = "mouse",
		subject = sys_acts,
		pause = "pause_mouse_actions",
		resume = "resume_mouse_actions",
		stop = "stop_mouse_actions",
		is_paused = "is_mouse_actions_paused",
		has_pending = "has_pending_mouse_action",
		claim = SHORTCUT_ACTION_PARENT,
	},
	{
		id = "pixel",
		subject = sys_acts,
		pause = "pause_pixel_actions",
		resume = "resume_pixel_actions",
		stop = "stop_pixel_actions",
		is_paused = "is_pixel_actions_paused",
		has_pending = "has_pending_pixel_action",
	},
	{
		id = "screenshot",
		subject = sys_acts,
		pause = "pause_screenshot_actions",
		resume = "resume_screenshot_actions",
		stop = "stop_screenshot_actions",
		is_paused = "has_screenshot_pause_claim",
		has_pending = "has_pending_screenshot_action",
		claim = SHORTCUT_ACTION_PARENT,
		shared = true,
	},
}

-- A false/nil/throw result is ambiguous even when a diagnostic query happens to
-- look settled afterward. Retain that uncertainty until an exact compensating
-- lifecycle call and exact post-state both commit.
local child_cleanup_debt = {}

-- Callback that returns the live active-wrap-pairs table.
-- Set by M.set_wrap_pairs_getter() when the menu wires up the user's symbol state.
-- Falls back to nil so bind_wrap_text_if_selected uses the full built-in catalogue.
local _wrap_pairs_getter = nil

--- Stable indirection captured once by the native wrap eventtap. Menu rebuilds
--- only replace the preference callback above; the live eventtap resolves that
--- slot at delivery time, so a state refresh never tears down or duplicates a
--- native owner.
--- @return table|nil pairs
local function get_live_wrap_pairs()
	local getter = _wrap_pairs_getter
	if type(getter) == "function" then return getter() end
	return nil
end

-- User-configured ChatGPT URL, persisted to config.toml by the menu's save
-- callback. Set by M.set_chatgpt_url() at boot-time state restoration and on
-- every menu edit, so ctrl_g always opens the URL the user actually configured
-- instead of the hardcoded manifest default (shortcuts-ctrl-g-ignores-config).
-- Falls back to nil so ctrl_g uses M.DEFAULT_CHATGPT_URL.
local _chatgpt_url = nil

-- Canonical modifier ordering used to build display labels
local MOD_ORDER  = {"cmd", "ctrl", "alt", "shift", "fn"}
local MOD_LABELS = {cmd = "Cmd", ctrl = "Ctrl", alt = "Alt", shift = "Shift", fn = "Fn"}





-- ===========================================
-- ===========================================
-- ======= 2/ Internal Binding Helpers =======
-- ===========================================
-- ===========================================

--- Builds a canonical display label from a modifier array and a key name.
--- @param mods table Array of modifier strings (e.g. {"ctrl", "shift"}).
--- @param key string The primary key name or character.
--- @return string Canonical label (e.g. "Ctrl+Shift+S").
local function make_label(mods, key)
	local parts = {}
	for _, m in ipairs(MOD_ORDER) do
		for _, bm in ipairs(mods) do
			if bm == m then table.insert(parts, MOD_LABELS[m] or m); break end
		end
	end
	local k = (#key == 1) and key:upper() or (key:sub(1, 1):upper() .. key:sub(2))
	table.insert(parts, k)
	return table.concat(parts, "+")
end

--- Resolves the name of the currently frontmost application.
--- Falls back to the focused window's application when frontmostApplication returns nil.
--- @return string The application name, or "Unknown" if unavailable.
local function get_frontmost_app_name()
	local app  = hs.application.frontmostApplication()
	local name = app and app:title()
	if not name or name == "" then
		local win = hs.window.focusedWindow()
		local wa  = win and win:application()
		name      = wa and wa:title()
	end
	return name or "Unknown"
end

--- Logs a shortcut invocation via the keylogger module when it is available.
--- Uses a lazy require so the keylogger is optional and need not be pre-wired.
--- @param label string The canonical shortcut label (e.g. "Ctrl+T").
--- @param app_name string The name of the app in which the shortcut fired.
local function log_shortcut(label, app_name)
	local ok_kl, kl = pcall(require, "modules.keylogger")
	if ok_kl and kl and type(kl.log_shortcut) == "function" then
		pcall(kl.log_shortcut, label, app_name)
	end
end

--- Binds a standard hotkey and logs its invocation before running the action.
--- @param mods table Modifier array.
--- @param key string Primary key.
--- @param fn function Action callback.
--- @return table The hs.hotkey object.
local function bind_log(mods, key, fn)
	local label = make_label(mods, key)
	return hs.hotkey.bind(mods, key, function()
		if delivery_enabled ~= true then return end
		log_shortcut(label, get_frontmost_app_name())
		fn()
	end)
end




-- =====================================
-- =====================================
-- ======= 3/ Hotkey Definitions ========
-- =====================================
-- =====================================

-- Screenshots & Layer (appear first in the menu, before the Ctrl block)
hotkey_labels.at_hash = i18n.get("shortcuts.label_at_hash")
hotkey_defs.at_hash   = function()
	return sys_acts.bind_instant_screenshot(delivery_admitted)
end

hotkey_labels.layer_scroll = i18n.get("shortcuts.label_layer_scroll")
hotkey_defs.layer_scroll   = function()
	return sys_acts.bind_layer_scroll(delivery_admitted)
end

hotkey_labels.wrap_text_if_selected = i18n.get("shortcuts.label_wrap_text")
hotkey_defs.wrap_text_if_selected   = function()
	return sys_acts.bind_wrap_text_if_selected(
		get_live_wrap_pairs, delivery_admitted)
end

-- Ctrl shortcuts — alphabetical by id (mirrors list_shortcuts() sort order)
hotkey_labels.ctrl_a = i18n.get("shortcuts.label_ctrl_a")
hotkey_defs.ctrl_a   = function()
	return bind_log({"ctrl"}, "a", text_acts.select_line)
end

hotkey_labels.ctrl_d = i18n.get("shortcuts.label_ctrl_d")
hotkey_defs.ctrl_d   = function()
	return bind_log({"ctrl"}, "d", app_acts.open_downloads)
end

hotkey_labels.ctrl_e = i18n.get("shortcuts.label_ctrl_e")
hotkey_defs.ctrl_e   = function()
	return bind_log({"ctrl"}, "e", app_acts.open_finder)
end

hotkey_labels.ctrl_g = i18n.get("shortcuts.label_ctrl_g")
hotkey_defs.ctrl_g   = function()
	return bind_log({"ctrl"}, "g", function()
		app_acts.open_chatgpt(_chatgpt_url or M.DEFAULT_CHATGPT_URL)
	end)
end

hotkey_labels.ctrl_h = i18n.get("shortcuts.label_ctrl_h")
hotkey_defs.ctrl_h   = function()
	return bind_log({"ctrl"}, "h", sys_acts.interactive_screenshot)
end

hotkey_labels.ctrl_i = i18n.get("shortcuts.label_ctrl_i")
hotkey_defs.ctrl_i   = function()
	return bind_log({"ctrl"}, "i", app_acts.open_settings)
end

hotkey_labels.ctrl_m = i18n.get("shortcuts.label_ctrl_m")
hotkey_defs.ctrl_m   = function()
	return bind_log({"ctrl"}, "m", sys_acts.toggle_awake)
end

hotkey_labels.ctrl_o = i18n.get("shortcuts.label_ctrl_o")
hotkey_defs.ctrl_o   = function()
	return bind_log({"ctrl"}, "o", text_acts.surround_with_parens)
end

hotkey_labels.ctrl_p = i18n.get("shortcuts.label_ctrl_p")
hotkey_defs.ctrl_p   = function()
	return bind_log({"ctrl"}, "p", sys_acts.toggle_display_mirror)
end

hotkey_labels.ctrl_s = i18n.get("shortcuts.label_ctrl_s")
hotkey_defs.ctrl_s   = function()
	return bind_log({"ctrl"}, "s", app_acts.copy_or_open_path)
end

hotkey_labels.ctrl_t = i18n.get("shortcuts.label_ctrl_t")
hotkey_defs.ctrl_t   = function()
	return bind_log({"ctrl"}, "t", sys_acts.teleport_mouse)
end

hotkey_labels.ctrl_u = i18n.get("shortcuts.label_ctrl_u")
hotkey_defs.ctrl_u   = function()
	return bind_log({"ctrl"}, "u", text_acts.toggle_uppercase)
end

hotkey_labels.ctrl_w = i18n.get("shortcuts.label_ctrl_w")
hotkey_defs.ctrl_w   = function()
	return bind_log({"ctrl"}, "w", text_acts.toggle_titlecase)
end

hotkey_labels.ctrl_x = i18n.get("shortcuts.label_ctrl_x")
hotkey_defs.ctrl_x   = function()
	return bind_log({"ctrl"}, "x", sys_acts.copy_pixel_color)
end

hotkey_labels.ctrl_capslock = i18n.get("shortcuts.label_ctrl_capslock")
hotkey_defs.ctrl_capslock   = function()
	return bind_log({"ctrl"}, "capslock", sys_acts.toggle_capslock)
end

hotkey_labels.ctrl_l = i18n.get("shortcuts.label_ctrl_l")
hotkey_defs.ctrl_l   = function()
	return bind_log({"ctrl"}, "l", sys_acts.lock_screen)
end

-- Punctuation shortcuts — after all letter-based ctrl shortcuts
hotkey_labels.ctrl_period = i18n.get("shortcuts.label_ctrl_period")
hotkey_defs.ctrl_period   = function()
	return bind_log({"ctrl"}, ".", sys_acts.open_emoji_picker)
end

hotkey_labels.ctrl_quote = i18n.get("shortcuts.label_ctrl_quote")
hotkey_defs.ctrl_quote   = function()
	return bind_log({"ctrl"}, "'", sys_acts.spotlight_mouse)
end

-- Cmd shortcuts — alphabetical by id
hotkey_labels.cmd_shift_v = i18n.get("shortcuts.label_cmd_shift_v")
hotkey_defs.cmd_shift_v   = function()
	return bind_log({"cmd", "shift"}, "v", text_acts.paste_as_plain_text)
end

hotkey_labels.cmd_star = i18n.get("shortcuts.label_cmd_star")
hotkey_defs.cmd_star   = function()
	-- Pass the log callback so bind_cmd_star can log the re-fired Cmd+S
	return sys_acts.bind_cmd_star(log_shortcut, delivery_admitted)
end





-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================

--- Releases one exact hotkey/eventtap identity.
local function release_hotkey_identity(name, owner)
	local released = false
	local exact_result_required = EXACT_RELEASE_IDS[name] == true
	if owner and type(owner.delete) == "function" then
		local ok, result = pcall(function() return owner:delete() end)
		released = ok and ((exact_result_required and result == true)
			or (not exact_result_required and result ~= false))
	elseif owner and type(owner.disable) == "function" then
		local ok, result = pcall(function() return owner:disable() end)
		released = ok and ((exact_result_required and result == true)
			or (not exact_result_required and result ~= false))
	end
	return released
end

--- Releases every live hotkey/eventtap object without forgetting cleanup debt.
--- Extracted so the two callers cannot drift apart on how an object is torn
--- down: M.stop() (a genuine subsystem shutdown) and M.rebind() (a layout
--- re-arm). Only the former owns the subsystem-level state — see M.stop().
--- @return boolean settled True only when every native owner was released.
local function release_hotkeys()
	local settled = true
	local names = {}
	for name in pairs(hotkeys) do names[#names + 1] = name end
	for _, name in ipairs(names) do
		local v = hotkeys[name]
		local released = release_hotkey_identity(name, v)
		if released then
			hotkeys[name] = nil
			Logger.debug(LOG, "Hotkey '%s' unbound.", name)
		else
			settled = false
			Logger.error(LOG, "Hotkey '%s' teardown did not settle — native handle retained for retry.", name)
		end
	end
	return settled
end

--- Invokes one child lifecycle edge with an exact literal-true contract.
--- @param owner table Child descriptor.
--- @param edge string Descriptor field (`pause`, `resume`, or `stop`).
--- @param boundary string Diagnostic boundary.
--- @return boolean settled
local function call_child_lifecycle(owner, edge, boundary)
	local function_name = owner[edge]
	local fn = owner.subject and owner.subject[function_name]
	if type(fn) ~= "function" then
		child_cleanup_debt[owner.id] = true
		Logger.error(LOG, "Shortcut child '%s' has no '%s' lifecycle API.",
			owner.id, tostring(function_name))
		return false
	end
	local ok, result = xpcall(function()
		if owner.claim then return fn(owner.claim) end
		return fn()
	end, debug.traceback)
	if not ok or result ~= true then
		child_cleanup_debt[owner.id] = true
		Logger.error(LOG, "Shortcut child '%s' %s did not settle: %s.",
			owner.id, boundary, tostring(result))
		return false
	end
	return true
end

--- Reads one exact boolean child query without normalizing ambiguity.
--- @param owner table Child descriptor.
--- @param query string Descriptor field (`is_paused` or `has_pending`).
--- @return boolean readable
--- @return boolean|nil value
local function read_child_boolean(owner, query)
	local function_name = owner[query]
	local fn = owner.subject and owner.subject[function_name]
	if type(fn) ~= "function" then
		child_cleanup_debt[owner.id] = true
		Logger.error(LOG, "Shortcut child '%s' has no '%s' query API.",
			owner.id, tostring(function_name))
		return false, nil
	end
	local ok, value = xpcall(function()
		if owner.claim then return fn(owner.claim) end
		return fn()
	end, debug.traceback)
	if not ok or type(value) ~= "boolean" then
		child_cleanup_debt[owner.id] = true
		Logger.error(LOG, "Shortcut child '%s' query '%s' is ambiguous: %s.",
			owner.id, tostring(function_name), tostring(value))
		return false, nil
	end
	return true, value
end

--- Reads both observable child ownership dimensions exactly.
--- @param owner table Child descriptor.
--- @return boolean readable
--- @return boolean|nil paused
--- @return boolean|nil pending
local function read_child_state(owner)
	local paused_ok, paused = read_child_boolean(owner, "is_paused")
	local pending_ok, pending = read_child_boolean(owner, "has_pending")
	return paused_ok and pending_ok, paused, pending
end

--- Verifies that one child is fenced and owns no unfinished capability.
--- @param owner table Child descriptor.
--- @return boolean settled
local function child_is_parked(owner)
	local readable, paused, pending = read_child_state(owner)
	return readable == true and paused == true and pending == false
end

--- Verifies that one child is open and owns no pre-transition capability.
--- @param owner table Child descriptor.
--- @return boolean settled
local function child_is_open(owner)
	local readable, paused, pending = read_child_state(owner)
	return readable == true and paused == false and pending == false
end

--- Calls every child teardown edge before evaluating aggregate settlement.
--- @param edge string Descriptor field (`pause` or `stop`).
--- @param boundary string Diagnostic boundary.
--- @param reverse boolean|nil Whether to compensate in reverse order.
--- @return boolean settled
local function settle_all_children(edge, boundary, reverse)
	local outcomes = {}
	if reverse == true then
		for index = #child_owners, 1, -1 do
			local owner = child_owners[index]
			outcomes[index] = call_child_lifecycle(owner, edge, boundary)
		end
	else
		for index, owner in ipairs(child_owners) do
			outcomes[index] = call_child_lifecycle(owner, edge, boundary)
		end
	end

	local settled = true
	for index, owner in ipairs(child_owners) do
		local parked = child_is_parked(owner)
		if outcomes[index] == true and parked == true then
			child_cleanup_debt[owner.id] = nil
		else
			child_cleanup_debt[owner.id] = true
			settled = false
		end
	end
	return settled
end

--- Re-fences every child touched by an incomplete open transaction.
--- The attempted child is recorded before its call so mutate-then-refuse is
--- compensated along with every child that returned true before it.
--- @param reopened table Ordered child descriptors.
--- @param boundary string Diagnostic boundary.
--- @return boolean settled
local function rollback_reopened_children(reopened, boundary)
	local outcomes = {}
	for index = #reopened, 1, -1 do
		local owner = reopened[index]
		outcomes[index] = call_child_lifecycle(owner, "pause", boundary)
	end
	local settled = true
	for index, owner in ipairs(reopened) do
		local parked = child_is_parked(owner)
		if outcomes[index] == true and parked == true then
			child_cleanup_debt[owner.id] = nil
		else
			child_cleanup_debt[owner.id] = true
			settled = false
		end
	end
	return settled
end

--- Reconciles every paused/debt-bearing child before native hotkeys are exposed.
--- @return boolean committed
--- @return table reopened Children that must be compensated if startup fails.
local function reopen_children_for_start()
	local snapshots = {}
	local readable = true
	for index, owner in ipairs(child_owners) do
		local state_ok, paused, pending = read_child_state(owner)
		snapshots[index] = {paused = paused, pending = pending}
		if state_ok ~= true then readable = false end
	end
	if not readable then return false, {} end

	local reopened = {}
	for index, owner in ipairs(child_owners) do
		local snapshot = snapshots[index]
		local needs_reconcile = snapshot.paused == true
			or child_cleanup_debt[owner.id] == true
			or (snapshot.pending == true and owner.shared ~= true)
		if needs_reconcile then
			reopened[#reopened + 1] = owner
			if snapshot.paused ~= true then
				local cleanup_committed = call_child_lifecycle(
					owner, "pause", "startup cleanup")
				local parked = child_is_parked(owner)
				if cleanup_committed ~= true or parked ~= true then
					rollback_reopened_children(reopened, "startup cleanup rollback")
					return false, reopened
				end
			end
			local resumed = call_child_lifecycle(owner, "resume", "startup resume")
			local opened = child_is_open(owner)
			if resumed == true and opened == true then
				child_cleanup_debt[owner.id] = nil
			else
				child_cleanup_debt[owner.id] = true
				rollback_reopened_children(reopened, "startup resume rollback")
				return false, reopened
			end
		end
	end
	return true, reopened
end

--- Reports state mismatch, pending ownership, or retained ambiguity as debt.
--- @return boolean pending
local function children_have_pause_debt()
	local debt = false
	for _, owner in ipairs(child_owners) do
		local readable, paused, pending = read_child_state(owner)
		if readable ~= true or pending ~= false
			or child_cleanup_debt[owner.id] == true then
			debt = true
		elseif started == true and paused ~= false then
			debt = true
		elseif started ~= true and paused ~= true then
			debt = true
		end
	end
	return debt
end

--- Binds all configured hotkeys and opens every child owner transactionally.
--- @param preserve_pause_intent boolean Keep the reversible PAUSE snapshot live.
--- @param hotkeys_only boolean Rebind native hotkeys without touching child state.
--- @return boolean committed True only when every enabled binding is owned.
local function start_bindings(preserve_pause_intent, hotkeys_only)
	if not admission_open() or start_attempt ~= nil then
		delivery_enabled = false
		return false
	end
	local attempt = { epoch = lifecycle_epoch }
	start_attempt = attempt
	local function finish_attempt()
		if start_attempt == attempt then start_attempt = nil end
	end
	local function reject_start(reopened_children, reason)
		delivery_enabled = false
		Logger.error(LOG, "Shortcuts bindings startup rejected: %s.", tostring(reason))
		if release_hotkeys() ~= true then
			Logger.error(LOG, "Shortcuts bindings startup rollback is incomplete.")
		end
		if rollback_reopened_children(
			reopened_children or {}, "hotkey startup rollback") ~= true then
			Logger.error(LOG, "Shortcut child admission rollback is incomplete.")
		end
		started = false
		finish_attempt()
		return false
	end
	if started then
		-- A second start() per boot is the intended reconciliation, not a bug:
		-- init.lua starts the bindings early so hotkeys work during boot, then
		-- menu_state re-starts them to apply the saved on/off preference. Mirror
		-- keymap.start's silently-idempotent restart and log at DEBUG so a normal
		-- boot stays warning-free (a WARNING every boot trains users to ignore them)
		Logger.debug(LOG, "M.start() already active — ignoring duplicate start (boot reconciliation).")
		delivery_enabled = true
		if preserve_pause_intent ~= true then pause_restore_intent = nil end
		finish_attempt()
		return true
	end
	delivery_enabled = false
	if awake_cleanup_pending then
		Logger.error(LOG, "Shortcuts bindings cannot start while keep-awake cleanup is pending.")
		finish_attempt()
		return false
	end
	if next(hotkeys) ~= nil and release_hotkeys() ~= true then
		Logger.error(LOG, "Shortcuts bindings cannot start while native cleanup is pending.")
		finish_attempt()
		return false
	end
	if not admission_open(attempt) then
		return reject_start({}, "lifecycle changed during predecessor cleanup")
	end
	Logger.start(LOG, "Starting shortcuts bindings…")
	local reopened_children = {}
	if hotkeys_only ~= true then
		local children_committed
		children_committed, reopened_children = reopen_children_for_start()
		if children_committed ~= true then
			Logger.error(LOG, "Shortcuts bindings cannot start while child cleanup is pending.")
			finish_attempt()
			return false
		end
		if not admission_open(attempt) then
			return reject_start(reopened_children,
				"lifecycle changed during child admission")
		end
	end

	for name, def in pairs(hotkey_defs) do
		-- Skip hotkeys that are already active OR that were explicitly disabled
		-- via M.disable() — the _disabled_set persists across stop/start cycles
		-- so that resume after focus loss cannot silently re-enable them
		-- (shortcuts-bindings-reenable-on-resume).
		if not hotkeys[name] and not _disabled_set[name] then
			native_acquisition_depth = native_acquisition_depth + 1
			local ok, obj = xpcall(def, debug.traceback)
			native_acquisition_depth = native_acquisition_depth - 1
			local object_type = type(obj)
			if ok and obj ~= nil and (object_type == "table" or object_type == "userdata") then
				hotkeys[name] = obj
				Logger.debug(LOG, "Hotkey '%s' bound.", name)
				if not admission_open(attempt) then
					return reject_start(reopened_children,
						"lifecycle changed during factory '" .. tostring(name) .. "'")
				end
			else
				return reject_start(reopened_children,
					"factory '" .. tostring(name) .. "' returned " .. tostring(obj))
			end
		end
	end
	if not admission_open(attempt) then
		return reject_start(reopened_children, "lifecycle changed before final commit")
	end

	-- Seed random for keep-awake jitter on first start
	math.randomseed(os.time())

	local count = 0
	for _ in pairs(hotkeys) do count = count + 1 end
	started = true
	delivery_enabled = true
	if preserve_pause_intent ~= true then pause_restore_intent = nil end
	finish_attempt()
	Logger.success(LOG, "Shortcuts bindings started (%d hotkey(s)).", count)
	return true
end

--- Binds all configured hotkeys and starts background tasks transactionally.
--- @return boolean committed True only when every enabled binding is owned.
function M.start()
	if not admission_open() then return false end
	local committed = start_bindings(false, false)
	if committed == true then rebind_recovery_intent = false end
	return committed
end

--- Releases only the module-local PAUSE admission fence before an aggregate
--- Shortcuts.start() transaction.  A real stop following a pause deliberately
--- leaves this fence closed; the aggregate owner is the only authority allowed
--- to reopen it after it has proved that no feature/script-control claim remains.
--- @return boolean committed
function M.release_pause_admission()
	lifecycle_paused = false
	invalidate_lifecycle()
	return true
end

--- Unbinds all hotkeys and stops background tasks.
--- @return boolean settled True only when every owned resource was released.
function M.stop()
	delivery_enabled = false
	invalidate_lifecycle()
	start_attempt = nil
	if not started and next(hotkeys) == nil and not awake_cleanup_pending
		and not rebind_recovery_intent
		and native_acquisition_depth == 0
		and not children_have_pause_debt() then
		pause_restore_intent = nil
		Logger.debug(LOG, "M.stop() called when not started — nothing to do.")
		return true
	end
	Logger.start(LOG, "Stopping shortcuts bindings…")
	local children_settled = settle_all_children("stop", "stop", false)

	-- Only a genuine shutdown owns the keep-awake teardown. Keep-awake is
	-- subsystem-level state (jiggler timer + persistent banner the user armed for
	-- a meeting), not a hotkey object, so a layout re-arm has no business
	-- cancelling it. M.rebind() must NEVER reach this line — routing the layout
	-- rebind through stop() is what silently killed keep-awake, and the laptop
	-- slept, on every input-source change (shortcuts-rebind-kills-keep-awake).
	local awake_settled = true
	if started or rebind_recovery_intent or awake_cleanup_pending then
		awake_cleanup_pending = true
		local ok, result = xpcall(sys_acts.stop_awake, debug.traceback)
		awake_settled = ok and result == true
		if awake_settled then awake_cleanup_pending = false end
		if not awake_settled then
			Logger.error(LOG, "Keep-awake teardown did not settle: %s.", tostring(result))
		end
	end

	local hotkeys_settled = release_hotkeys()
	started = false
	pause_restore_intent = nil
	if native_acquisition_depth ~= 0
		or not children_settled or not awake_settled or not hotkeys_settled then
		Logger.error(LOG, "Shortcuts bindings stop is incomplete and remains retryable.")
		return false
	end
	rebind_recovery_intent = false
	Logger.success(LOG, "Shortcuts bindings stopped.")
	return true
end

--- Quiesces user bindings for ScriptControl while retaining the keep-awake
--- preference as a reversible child owner.
--- @return boolean settled
function M.pause()
	delivery_enabled = false
	lifecycle_paused = true
	invalidate_lifecycle()
	start_attempt = nil
	if started == true or rebind_recovery_intent == true then
		pause_restore_intent = true
	elseif pause_restore_intent == nil then
		pause_restore_intent = false
	end
	local children_settled = settle_all_children("pause", "pause", false)
	local awake_fn = type(sys_acts.pause_awake) == "function"
		and sys_acts.pause_awake or sys_acts.stop_awake
	local ok_awake, awake_result = xpcall(awake_fn, debug.traceback)
	local awake_settled = ok_awake and awake_result == true
	if not awake_settled then
		Logger.error(LOG, "Keep-awake pause did not settle: %s.", tostring(awake_result))
	end
	local hotkeys_settled = release_hotkeys()
	started = false
	return native_acquisition_depth == 0
		and children_settled and awake_settled and hotkeys_settled
end

--- Fences and releases only layout-dependent hotkeys.  Child actions and
--- keep-awake belong to the feature lifecycle and must not churn on a keyboard
--- layout rebind or its recovery transaction.
--- @return boolean settled
function M.pause_hotkeys_only()
	if started == true then rebind_recovery_intent = true end
	delivery_enabled = false
	lifecycle_paused = true
	invalidate_lifecycle()
	start_attempt = nil
	local settled = release_hotkeys()
	started = false
	return settled == true and native_acquisition_depth == 0
end

--- Re-arms only layout-dependent hotkeys after pause_hotkeys_only().
--- @return boolean committed
function M.resume_hotkeys_after_pause()
	lifecycle_paused = false
	invalidate_lifecycle()
	local committed = start_bindings(false, true)
	if committed == true then rebind_recovery_intent = false end
	return committed
end

--- Restores a logically-ON layout-rebind snapshot after a global PAUSE. The
--- aggregate recovery claim remains authoritative while M.rebind() temporarily
--- exposes `started=false` during handle replacement.
--- @return boolean committed
function M.resume_rebind_after_pause()
	rebind_recovery_intent = true
	pause_restore_intent = true
	return M.resume_after_pause()
end

--- Restores hotkeys and the exact keep-awake intent captured by M.pause().
--- @return boolean committed
function M.resume_after_pause()
	lifecycle_paused = false
	invalidate_lifecycle()
	if started == true and pause_restore_intent ~= true then
		delivery_enabled = true
		return true
	end
	if pause_restore_intent ~= true then
		delivery_enabled = false
		local children_settled = settle_all_children(
			"pause", "cleanup-only resume fence", false)
		local hotkeys_settled = release_hotkeys()
		started = false
		if children_settled and hotkeys_settled then
			pause_restore_intent = nil
			return true
		end
		return false
	end
	if start_bindings(true, false) ~= true then return false end
	if type(sys_acts.resume_awake) ~= "function" then
		pause_restore_intent = nil
		rebind_recovery_intent = false
		return true
	end
	local ok_awake, awake_result = xpcall(sys_acts.resume_awake, debug.traceback)
	if not ok_awake or awake_result ~= true then
		delivery_enabled = false
		Logger.error(LOG, "Keep-awake resume did not commit: %s.", tostring(awake_result))
		local awake_fn = type(sys_acts.pause_awake) == "function"
			and sys_acts.pause_awake or sys_acts.stop_awake
		local ok_pause, pause_result = xpcall(awake_fn, debug.traceback)
		if not ok_pause or pause_result ~= true then
			Logger.error(LOG, "Keep-awake resume rollback did not settle: %s.",
				tostring(pause_result))
		end
		if settle_all_children("pause", "resume rollback", true) ~= true then
			Logger.error(LOG, "Shortcut child resume rollback is incomplete.")
		end
		if release_hotkeys() ~= true then
			Logger.error(LOG, "Hotkey resume rollback is incomplete.")
		end
		started = false
		return false
	end
	pause_restore_intent = nil
	rebind_recovery_intent = false
	return true
end

--- Re-creates every hotkey object in place, WITHOUT touching subsystem-level
--- state. hs.hotkey.bind resolves key names to physical scancodes at bind time,
--- so after a keyboard-layout change the live bindings still point at the old
--- layout's positions and must be rebuilt.
--- Deliberately not M.stop() followed by M.start(): stop() also tears down
--- keep-awake, which a layout switch must leave running. Hotkeys the caller
--- turned off via M.disable() stay off, because M.start() honours _disabled_set.
function M.rebind()
	if not started or not admission_open() then
		-- A rebind is meaningless on a stopped layer, and re-arming from here
		-- would resurrect hotkeys the user deliberately turned off
		-- (shortcuts-layout-rebind-reenables).
		Logger.debug(LOG, "M.rebind() called when not started — nothing to re-arm.")
		return false
	end
	rebind_recovery_intent = true
	Logger.trace(LOG, "Rebinding shortcuts hotkeys…")
	delivery_enabled = false
	started = false
	if release_hotkeys() ~= true then
		Logger.error(LOG, "Shortcuts hotkey rebind could not release every prior owner.")
		return false
	end
	if not admission_open() then
		Logger.error(LOG, "Shortcuts hotkey rebind lost lifecycle admission during release.")
		return false
	end
	if start_bindings(false, true) ~= true then
		Logger.error(LOG, "Shortcuts hotkey rebind could not commit replacement owners.")
		return false
	end
	rebind_recovery_intent = false
	Logger.done(LOG, "Shortcuts hotkeys rebound.")
	return true
end

--- Returns true when bindings have been started and not yet stopped.
--- @return boolean
function M.is_started() return started end

--- Reports exact native child debt even after the hotkey layer has been fenced.
--- ScriptControl uses this to retry cleanup as a one-way step without restoring
--- bindings that were already OFF before the pause request.
--- @return boolean pending
function M.has_pause_debt()
	return native_acquisition_depth ~= 0
		or rebind_recovery_intent == true
		or (started ~= true and next(hotkeys) ~= nil)
		or children_have_pause_debt()
end

--- Enables a single named hotkey by running its factory function.
--- @param name string The shortcut identifier.
--- @return boolean committed
function M.enable(name)
	if type(name) ~= "string" then
		Logger.error(LOG, "M.enable(): name must be a string.")
		return false
	end
	if not admission_open() or start_attempt ~= nil then
		Logger.error(LOG, "M.enable(): lifecycle admission is paused.")
		return false
	end
	if hotkeys[name] then
		Logger.debug(LOG, "Hotkey '%s' already enabled — skipping.", name)
		return true
	end
	local def = hotkey_defs[name]
	if type(def) ~= "function" then
		Logger.error(LOG, "M.enable(): unknown hotkey '%s'.", name)
		return false
	end
	_disabled_set[name] = nil
	local acquisition_epoch = lifecycle_epoch
	native_acquisition_depth = native_acquisition_depth + 1
	local ok, obj = xpcall(def, debug.traceback)
	native_acquisition_depth = native_acquisition_depth - 1
	local object_type = type(obj)
	if ok and obj ~= nil and (object_type == "table" or object_type == "userdata") then
		hotkeys[name] = obj
		if lifecycle_epoch ~= acquisition_epoch or not admission_open() then
			if release_hotkey_identity(name, obj) == true then
				if hotkeys[name] == obj then hotkeys[name] = nil end
			else
				Logger.error(LOG,
					"M.enable(): superseded factory cleanup remains pending for '%s'.", name)
			end
			_disabled_set[name] = true
			return false
		end
		Logger.debug(LOG, "Hotkey '%s' enabled.", name)
		return true
	end
	_disabled_set[name] = true
	Logger.error(LOG, "M.enable(): factory for '%s' failed: %s.", name, tostring(obj))
	return false
end

--- Disables a single named hotkey.
--- @param name string The shortcut identifier.
--- @return boolean committed
function M.disable(name)
	if type(name) ~= "string" then
		Logger.error(LOG, "M.disable(): name must be a string.")
		return false
	end
	local h = hotkeys[name]
	if not h then
		_disabled_set[name] = true
		Logger.debug(LOG, "Hotkey '%s' not active — nothing to disable.", name)
		return true
	end
	local released = false
	if type(h.delete) == "function" then
		local ok, result = xpcall(function() return h:delete() end, debug.traceback)
		local exact_result_required = EXACT_RELEASE_IDS[name] == true
		released = ok and ((exact_result_required and result == true)
			or (not exact_result_required and result ~= false))
	elseif type(h.disable) == "function" then
		local ok, result = xpcall(function() return h:disable() end, debug.traceback)
		local exact_result_required = EXACT_RELEASE_IDS[name] == true
		released = ok and ((exact_result_required and result == true)
			or (not exact_result_required and result ~= false))
	end
	if not released then
		Logger.error(LOG, "Hotkey '%s' disable refused; exact handle retained.", name)
		return false
	end
	hotkeys[name] = nil
	_disabled_set[name] = true
	Logger.debug(LOG, "Hotkey '%s' disabled.", name)
	return true
end

--- Returns whether a specific hotkey is currently active.
--- @param name string The shortcut identifier.
--- @return boolean True if the hotkey is bound.
function M.is_enabled(name)
	return hotkeys[name] ~= nil
end

--- Builds a sort key that groups shortcuts in display order:
---   1) ctrl + single letter (ctrl_a … ctrl_z)
---   2) ctrl + punctuation word (ctrl_period, ctrl_quote, …)
---   3) cmd shortcuts (cmd_shift_v, cmd_star, …)
---   4) everything else (at_hash, layer_scroll — extracted separately by the menu)
--- Within each group items sort alphabetically by id.
--- @param id string The shortcut identifier.
--- @return string Opaque sort key.
local function sort_key(id)
	if id:match("^ctrl_%a$") then return "1_" .. id end
	if id:match("^ctrl_")    then return "2_" .. id end
	if id:match("^cmd_")     then return "3_" .. id end
	return "4_" .. id
end

--- Sets the callback used by the wrap-text eventtap to resolve the active symbol table.
--- Call this whenever the user changes the symbol list so the tap uses the new table
--- on the very next keystroke without needing a restart.
--- @param getter function|nil Returns the live {[char]={left,right}} table, or nil to use defaults.
--- @return boolean committed True when the live preference callback was stored.
function M.set_wrap_pairs_getter(getter)
	_wrap_pairs_getter = type(getter) == "function" and getter or nil
	Logger.debug(LOG, "wrap_pairs_getter updated.")
	-- get_live_wrap_pairs is the stable closure captured by every native owner.
	-- Publishing this slot therefore cannot lose a just-released handle or arm a
	-- sibling while ScriptControl is PAUSED/rolling back.
	return true
end

--- Sets the ChatGPT URL that Ctrl+G opens. Call this whenever the user edits the
--- URL from the menu, and once at boot-time state restoration, so ctrl_g always
--- reflects config.toml (the SSoT) instead of the hardcoded manifest default.
--- No re-arm is needed here: like the wrap-pairs indirection, ctrl_g's closure
--- reads _chatgpt_url fresh on every keypress rather than capturing it once.
--- @param url string|nil The configured URL, or nil to fall back to the default.
function M.set_chatgpt_url(url)
	_chatgpt_url = (type(url) == "string" and url ~= "") and url or nil
	Logger.debug(LOG, "chatgpt_url updated: %s.", tostring(_chatgpt_url))
end

--- Returns a sorted array of all registered shortcuts with their current status.
--- @return table Array of {id, label, enabled} tables.
function M.list_shortcuts()
	local out = {}
	for name in pairs(hotkey_defs) do
		table.insert(out, {
			id      = name,
			label   = hotkey_labels[name] or name,
			enabled = (hotkeys[name] ~= nil),
		})
	end
	table.sort(out, function(a, b) return sort_key(a.id) < sort_key(b.id) end)
	return out
end

return M
