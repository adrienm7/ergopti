--- ui/menu/menu_karabiner.lua

--- ==============================================================================
--- MODULE: Karabiner Menu
--- DESCRIPTION:
--- Provides the "Karabiner" submenu in the Hammerspoon menu bar.
---
--- FEATURES & RATIONALE:
--- 1. Status item: 🟢/🟡/🔴 reflects actual process state + click to restart.
--- 2. Tap/Hold section: each key shows "Label : tap / hold" inline. Items are
---    grayed out when the integration is disabled.
--- 3. Raccourcis section: modifier combos grouped by key, also grayed when off.
--- 4. Delay pickers: configure tap/hold and sticky modifier timeouts globally.
--- 5. Explicit regeneration: changes are saved immediately, applied via "Régénérer".
--- ==============================================================================

local M = {}

local Logger      = require("lib.logger")
local KeLifecycle = require("modules.karabiner.ke_lifecycle")
local MenuUtils   = require("ui.menu.menu_utils")
local LOG         = "menu.karabiner"
local i18n        = require("lib.i18n")

-- Stop all KE launchd services for the current user, then kill any remaining
-- processes. launchctl bootout must run first so launchd does not restart them.
-- osascript quit alone is insufficient: KE daemons are managed by launchd and
-- get restarted immediately unless their service entries are removed first.
local KARABINER_KILL_CMD =
	"/bin/launchctl list"
	.. " | /usr/bin/grep -i karabiner"
	.. " | /usr/bin/awk '{print $3}'"
	.. " | /usr/bin/xargs -I{} /bin/launchctl bootout gui/$(/usr/bin/id -u)/{} 2>/dev/null"
	.. "; /usr/bin/pkill -if karabiner 2>/dev/null"

-- Label displayed when both tap and hold are "none"
local NONE_DISPLAY = "—"




-- =====================================
-- =====================================
-- ======= 1/ Helper Utilities =========
-- =====================================
-- =====================================

--- Returns true when KE is *actually applying* our remappings — i.e. the
--- daemon is detected AND the bridge has been primed in this boot session.
--- This is the honest signal for the green-dot status indicator: it never
--- claims success when remapping is silently inactive.
--- @return boolean
local function is_remapping_active()
	return KeLifecycle.is_remapping_active()
end

--- Builds an index of action id → action definition for fast lookup.
--- @param karabiner table The karabiner module.
--- @return table Map of id → action def.
local function build_action_index(karabiner)
	local index = {}
	for _, action in ipairs(karabiner.AVAILABLE_ACTIONS) do
		index[action.id] = action
	end
	return index
end

--- Returns the short_label (or label fallback) for an action id.
--- @param action_index table id → action def map.
--- @param action_id string The action id to look up.
--- @return string Short human-readable label.
local function short_action_label(action_index, action_id)
	local def = action_index[action_id]
	if not def then return "? " .. tostring(action_id) end
	return def.short_label or def.label
end

--- Formats a timeout value in ms as a human-readable string.
--- @param ms number Milliseconds.
--- @return string e.g. "500 ms" or "1 s" or "1,5 s".
local function fmt_delay(ms)
	if not ms then return "?" end
	if ms < 1000 then
		return tostring(ms) .. " ms"
	elseif ms % 1000 == 0 then
		return tostring(ms // 1000) .. " s"
	else
		return string.format("%.1f s", ms / 1000):gsub("%.", ",")
	end
end




-- =========================================
-- =========================================
-- ======= 2/ Action Picker Submenu =========
-- =========================================
-- =========================================

--- Builds the list of action items for any picker submenu.
--- Uses full labels grouped by category. The active choice is checked.
---
--- Slot modes control which actions are shown:
---   "tap"  — excludes actions with tappable == false (modifiers, combos, layer-hold).
---   "hold" — shows only actions with holdable == true (modifiers, combos, layer-hold).
---
--- @param karabiner   table    The karabiner module.
--- @param set_fn      function Called with (action_id) when user picks.
--- @param current_id  string   Currently selected action id.
--- @param update_menu function Callback to refresh the menu bar.
--- @param slot        string   "tap", "hold", or "combo".
--- @return table List of hs.menubar menu item tables.
local function build_action_picker(karabiner, set_fn, current_id, update_menu, slot)
	-- Filter: exclude actions that don't match the slot mode
	local function slot_filter(action)
		if slot == "hold" and not action.holdable      then return false end
		if slot == "tap"  and action.tappable == false then return false end
		return true
	end

	-- "Spécial" items (none, CapsWord) are shown ungrouped at the top — skip the header
	local function special_filter(action)
		return action.category ~= "Spécial"
	end

	-- Collect Spécial actions first (ungrouped), then the rest via MenuUtils
	local items = {}
	local non_special = {}
	for _, action in ipairs(karabiner.AVAILABLE_ACTIONS) do
		if not slot_filter(action) then goto continue end
		if not special_filter(action) then
			-- Spécial: show directly without category header
			local aid = action.id
			items[#items + 1] = {
				title   = action.label,
				checked = (aid == current_id),
				fn      = function()
					pcall(set_fn, aid)
					pcall(karabiner.regenerate)
					if update_menu then update_menu() end
				end,
			}
		else
			table.insert(non_special, action)
		end
		::continue::
	end

	-- Now use MenuUtils for the grouped, non-Spécial actions
	if #non_special > 0 then
		if #items > 0 then items[#items + 1] = { title = "-" } end
		local grouped = MenuUtils.build_action_picker(non_special, current_id, function(aid)
			pcall(set_fn, aid)
			pcall(karabiner.regenerate)
			if update_menu then update_menu() end
		end)
		for _, it in ipairs(grouped) do
			items[#items + 1] = it
		end
	end

	return items
end




-- =========================================
-- =========================================
-- ======= 3/ Tap/Hold Key Submenus =========
-- =========================================
-- =========================================

-- Keys belonging to the left hand (including spacebar, typically thumb-left).
-- Right-hand keys are everything else. Order follows tap_hold_keys.json.
local LEFT_HAND_IDS = {
	escape        = true,
	tab           = true,
	caps_lock     = true,
	left_shift    = true,
	fn            = true,
	left_control  = true,
	left_option   = true,
	left_command  = true,
	spacebar      = true,
}

--- Builds a single tap / hold menu item for one key definition.
--- @param karabiner   table    The karabiner module.
--- @param action_index table   id → action def map.
--- @param update_menu function Callback to refresh the menu bar.
--- @param enabled     boolean  Whether the integration is active.
--- @param key_def     table    Entry from TAP_HOLD_KEYS.
--- @return table hs.menubar menu item.
local function build_one_tap_hold_item(karabiner, action_index, update_menu, enabled, key_def)
	local kid = key_def.id

	local ok_tap,  current_tap  = pcall(karabiner.get_tap_action,  kid)
	local ok_hold, current_hold = pcall(karabiner.get_hold_action, kid)

	if not ok_tap  then current_tap  = "none" end
	if not ok_hold then current_hold = "none" end

	local tap_slbl  = short_action_label(action_index, current_tap)
	local hold_slbl = short_action_label(action_index, current_hold)
	local is_active = (current_tap ~= "none" or current_hold ~= "none")

	-- Show "—" when nothing is configured on this key
	local combo_label = (current_tap == "none" and current_hold == "none")
		and NONE_DISPLAY
		or  (tap_slbl .. "  /  " .. hold_slbl)

	local key_submenu = {
		{
			title    = i18n.get("menu.karabiner.nothing_tap_hold"),
			disabled = (current_tap == "none" and current_hold == "none"),
			fn       = function()
				pcall(karabiner.set_tap_action,  kid, "none")
				pcall(karabiner.set_hold_action, kid, "none")
				pcall(karabiner.regenerate)
				if update_menu then update_menu() end
			end,
		},
		{ title = "-" },
		{
			title = string.format(i18n.get("menu.karabiner.tap_arrow"), tap_slbl),
			menu  = build_action_picker(
				karabiner,
				function(action_id) karabiner.set_tap_action(kid, action_id) end,
				current_tap,
				update_menu,
				"tap"
			),
		},
		{
			title = string.format(i18n.get("menu.karabiner.hold_arrow"), hold_slbl),
			menu  = build_action_picker(
				karabiner,
				function(action_id) karabiner.set_hold_action(kid, action_id) end,
				current_hold,
				update_menu,
				"hold"
			),
		},
	}

	return {
		title    = string.format("%s  :  %s", key_def.label, combo_label),
		checked  = is_active or nil,
		disabled = not enabled or nil,
		menu     = enabled and key_submenu or nil,
	}
end

--- Builds all tap / hold entries split into "Main gauche" / "Main droite" sections.
--- Items are grayed out when the integration is disabled.
---
--- @param karabiner   table    The karabiner module.
--- @param action_index table   id → action def map.
--- @param update_menu function Callback to refresh the menu bar.
--- @param enabled     boolean  Whether the integration is active.
--- @return table List of hs.menubar menu item tables.
local function build_tap_hold_items(karabiner, action_index, update_menu, enabled)
	local items = {}

	items[#items + 1] = { title = i18n.section("menu.karabiner.header_taps_holds"), disabled = true }
	items[#items + 1] = { title = i18n.section("menu.karabiner.left_hand"),         disabled = true }
	for _, key_def in ipairs(karabiner.TAP_HOLD_KEYS) do
		if LEFT_HAND_IDS[key_def.id] then
			items[#items + 1] = build_one_tap_hold_item(
				karabiner, action_index, update_menu, enabled, key_def)
		end
	end

	items[#items + 1] = { title = i18n.section("menu.karabiner.right_hand"), disabled = true }
	for _, key_def in ipairs(karabiner.TAP_HOLD_KEYS) do
		if not LEFT_HAND_IDS[key_def.id] then
			items[#items + 1] = build_one_tap_hold_item(
				karabiner, action_index, update_menu, enabled, key_def)
		end
	end

	return items
end




-- ==========================================
--- ==========================================
-- ======= 4/ Raccourcis (Mod Combos) =======
--- ==========================================
-- ==========================================

--- Builds a single combo menu item with combo / tap / hold sub-pickers.
--- Shows "ComboLabel  /  TapLabel  /  HoldLabel" next to the combo label.
--- @param karabiner   table    The karabiner module.
--- @param action_index table   id → action def map.
--- @param update_menu function Callback to refresh the menu bar.
--- @param enabled     boolean  Whether the integration is active.
--- @param combo_def   table    Entry from MOD_COMBOS.
--- @return table hs.menubar menu item.
local function build_one_combo_item(karabiner, action_index, update_menu, enabled, combo_def)
	local cid = combo_def.id

	local ok_tap,   current_tap   = pcall(karabiner.get_combo_tap_action,   cid)
	local ok_hold,  current_hold  = pcall(karabiner.get_combo_hold_action,  cid)
	local ok_combo, current_combo = pcall(karabiner.get_combo_combo_action, cid)
	if not ok_tap   then current_tap   = "none" end
	if not ok_hold  then current_hold  = "none" end
	if not ok_combo then current_combo = "none" end

	local tap_slbl   = short_action_label(action_index, current_tap)
	local hold_slbl  = short_action_label(action_index, current_hold)
	local combo_slbl = short_action_label(action_index, current_combo)
	local is_empty   = (current_tap == "none" and current_hold == "none" and current_combo == "none")
	local is_active  = not is_empty

	local combo_label = is_empty and NONE_DISPLAY
		or string.format("%s  /  %s  /  %s", combo_slbl, tap_slbl, hold_slbl)

	local combo_submenu = {
		{
			title    = i18n.get("menu.karabiner.nothing_combo"),
			disabled = is_empty,
			fn       = function()
				pcall(karabiner.set_combo_combo_action, cid, "none")
				pcall(karabiner.set_combo_tap_action,   cid, "none")
				pcall(karabiner.set_combo_hold_action,  cid, "none")
				pcall(karabiner.regenerate)
				if update_menu then update_menu() end
			end,
		},
		{ title = "-" },
		{
			title = string.format(i18n.get("menu.karabiner.combo_arrow"), combo_slbl),
			menu  = build_action_picker(
				karabiner,
				function(action_id) karabiner.set_combo_combo_action(cid, action_id) end,
				current_combo,
				update_menu,
				"combo"
			),
		},
		{
			title = string.format(i18n.get("menu.karabiner.tap_colon"), tap_slbl),
			menu  = build_action_picker(
				karabiner,
				function(action_id) karabiner.set_combo_tap_action(cid, action_id) end,
				current_tap,
				update_menu,
				"tap"
			),
		},
		{
			title = string.format(i18n.get("menu.karabiner.hold_colon"), hold_slbl),
			menu  = build_action_picker(
				karabiner,
				function(action_id) karabiner.set_combo_hold_action(cid, action_id) end,
				current_hold,
				update_menu,
				"hold"
			),
		},
	}

	return {
		title    = string.format("%s  :  %s", combo_def.label, combo_label),
		checked  = is_active or nil,
		disabled = not enabled or nil,
		menu     = enabled and combo_submenu or nil,
	}
end

--- Builds all modifier combo items grouped by their "group" field.
--- Items are grayed out when the integration is disabled.
---
--- @param karabiner   table    The karabiner module.
--- @param action_index table   id → action def map.
--- @param update_menu function Callback to refresh the menu bar.
--- @param enabled     boolean  Whether the integration is active.
--- @return table List of hs.menubar menu item tables.
local function build_raccourcis_items(karabiner, action_index, update_menu, enabled)
	local items         = {}
	local current_group = nil
	local is_symmetric  = karabiner.get_combo_symmetric()
	local non_canonical = karabiner.NON_CANONICAL_COMBOS or {}

	for _, combo_def in ipairs(karabiner.MOD_COMBOS) do
		-- Skip combos handled elsewhere (e.g. script_control.lua shortcuts)
		if combo_def.menu_hidden then goto continue end
		-- In symmetric mode, non-canonical combos (reverse-order duplicates of a
		-- canonical entry) are hidden: the canonical half configures the chord for
		-- both press orders, so showing the reverse would confuse the user.
		if is_symmetric and non_canonical[combo_def.id] then goto continue end

		if combo_def.group ~= current_group then
			items[#items + 1] = { title = "— " .. combo_def.group .. " —", disabled = true }
			current_group = combo_def.group
		end
		items[#items + 1] = build_one_combo_item(
			karabiner, action_index, update_menu, enabled, combo_def)

		::continue::
	end

	return items
end




-- ====================================
--- ====================================
-- ======= 5/ Delay Input Items =======
--- ====================================
-- ====================================

--- Builds the tap / hold delay item. Clicking it opens an AppleScript input dialog
--- so the user can type any value freely, not limited to a preset list.
--- The value is set globally in complex_modifications.parameters and applies to
--- ALL tap / hold rules without per-manipulator overrides.
--- The default displayed in the dialog comes from the module — single source of truth.
--- @param karabiner   table    The karabiner module.
--- @param update_menu function Callback to refresh the menu bar.
--- @return table hs.menubar menu item.
local function build_delay_item(karabiner, update_menu)
	local timeout_ms = karabiner.get_tap_hold_timeout()

	return {
		title = string.format(i18n.get("menu.karabiner.tap_hold_title"), fmt_delay(timeout_ms)),
		fn    = function()
			-- Bring Hammerspoon to front so the dialog appears above other windows
			hs.focus()
			local prompt = string.format(i18n.get("menu.karabiner.tap_hold_dialog_prompt"), karabiner.DEFAULT_TAP_HOLD_TIMEOUT_MS)
			local title_d = i18n.get("menu.karabiner.tap_hold_dialog_title")
			local btn_ok = i18n.get("button.ok")
			local btn_cancel = i18n.get("button.cancel")
			local script = string.format(
				"display dialog %q default answer \"%d\" with title %q buttons {%q, %q} default button %q",
				prompt, timeout_ms or karabiner.DEFAULT_TAP_HOLD_TIMEOUT_MS,
				title_d, btn_cancel, btn_ok, btn_ok
			)
			local ok, result = hs.osascript.applescript(script)
			Logger.debug(LOG, "Delay input dialog: ok=%s result=%s.", tostring(ok), hs.inspect(result))
			if not ok or type(result) ~= "table" then return end
			local ms = tonumber(result["text returned"])
			if not ms or ms <= 0 then
				Logger.warn(LOG, "Invalid delay input '%s' — ignored.", tostring(result["text returned"]))
				return
			end
			karabiner.set_tap_hold_timeout(math.floor(ms))
			if update_menu then update_menu() end
		end,
	}
end

--- Builds the sticky modifier timeout item. Clicking opens a free-text input dialog.
--- The default displayed in the dialog comes from the module — single source of truth.
--- @param karabiner   table    The karabiner module.
--- @param update_menu function Callback to refresh the menu bar.
--- @return table hs.menubar menu item.
local function build_sticky_delay_item(karabiner, update_menu)
	local timeout_ms = karabiner.get_sticky_timeout()

	return {
		title = string.format(i18n.get("menu.karabiner.sticky_title"), fmt_delay(timeout_ms)),
		fn    = function()
			hs.focus()
			local prompt = i18n.get("menu.karabiner.sticky_dialog_prompt")
			local title_d = i18n.get("menu.karabiner.sticky_dialog_title")
			local btn_ok = i18n.get("button.ok")
			local btn_cancel = i18n.get("button.cancel")
			local script = string.format(
				"display dialog %q default answer \"%d\" with title %q buttons {%q, %q} default button %q",
				prompt, timeout_ms or karabiner.DEFAULT_STICKY_TIMEOUT_MS,
				title_d, btn_cancel, btn_ok, btn_ok
			)
			local ok, result = hs.osascript.applescript(script)
			Logger.debug(LOG, "Sticky delay input: ok=%s result=%s.", tostring(ok), hs.inspect(result))
			if not ok or type(result) ~= "table" then return end
			local ms = tonumber(result["text returned"])
			if not ms or ms <= 0 then
				Logger.warn(LOG, "Invalid sticky delay '%s' — ignored.", tostring(result["text returned"]))
				return
			end
			karabiner.set_sticky_timeout(math.floor(ms))
			if update_menu then update_menu() end
		end,
	}
end

--- Builds the combo activation window item. Clicking opens a free-text input dialog.
--- Controls `basic.simultaneous_threshold_milliseconds` — the maximum delay
--- between the two keys of a shortcut for KE to fire the combo (chord) slot.
--- @param karabiner   table    The karabiner module.
--- @param update_menu function Callback to refresh the menu bar.
--- @return table hs.menubar menu item.
local function build_simultaneous_threshold_item(karabiner, update_menu)
	local threshold_ms = karabiner.get_simultaneous_threshold()

	return {
		title = string.format(i18n.get("menu.karabiner.simultaneous_title"), fmt_delay(threshold_ms)),
		fn    = function()
			hs.focus()
			local prompt = string.format(i18n.get("menu.karabiner.simultaneous_dialog_prompt"), karabiner.DEFAULT_SIMULTANEOUS_THRESHOLD_MS)
			local title_d = i18n.get("menu.karabiner.simultaneous_dialog_title")
			local btn_ok = i18n.get("button.ok")
			local btn_cancel = i18n.get("button.cancel")
			local script = string.format(
				"display dialog %q default answer \"%d\" with title %q buttons {%q, %q} default button %q",
				prompt, threshold_ms or karabiner.DEFAULT_SIMULTANEOUS_THRESHOLD_MS,
				title_d, btn_cancel, btn_ok, btn_ok
			)
			local ok, result = hs.osascript.applescript(script)
			Logger.debug(LOG, "Simultaneous threshold input: ok=%s result=%s.", tostring(ok), hs.inspect(result))
			if not ok or type(result) ~= "table" then return end
			local ms = tonumber(result["text returned"])
			if not ms or ms <= 0 then
				Logger.warn(LOG, "Invalid threshold '%s' — ignored.", tostring(result["text returned"]))
				return
			end
			karabiner.set_simultaneous_threshold(math.floor(ms))
			pcall(karabiner.regenerate)
			if update_menu then update_menu() end
		end,
	}
end

--- Builds the symmetric-shortcut toggle item.
--- When on, "touche 1 + touche 2" and "touche 2 + touche 1" fire the same action;
--- the reverse half of each pair is hidden from the Raccourcis section to avoid duplicates.
--- @param karabiner   table    The karabiner module.
--- @param update_menu function Callback to refresh the menu bar.
--- @return table hs.menubar menu item.
local function build_combo_symmetric_item(karabiner, update_menu)
	local is_symmetric = karabiner.get_combo_symmetric()

	return {
		title   = i18n.get("menu.karabiner.symmetric"),
		checked = is_symmetric,
		fn      = function()
			karabiner.set_combo_symmetric(not is_symmetric)
			pcall(karabiner.regenerate)
			if update_menu then update_menu() end
		end,
	}
end





-- ======================================
-- ======================================
-- ======= 6/ Top-Level Builder =========
-- ======================================
-- ======================================

--- Builds the complete Karabiner menu item with its submenu.
--- @param ctx table Global UI context (must contain ctx.karabiner).
--- @return table|nil A hs.menubar menu item with a submenu, or nil on failure.
function M.build(ctx)
	local karabiner   = ctx and ctx.karabiner
	local update_menu = ctx and ctx.updateMenu

	if not karabiner then
		Logger.warn(LOG, "Karabiner module absent from context — submenu skipped.")
		return nil
	end

	local enabled      = karabiner.get_enabled()
	local active       = is_remapping_active()
	-- Daemon-only signal so we can distinguish "remapping not applied because
	-- bridge unprimed" (fixable via click) from "remapping not applied because
	-- KE is not installed / daemon down" (user must install/check KE itself).
	local grabber_only = KeLifecycle.is_grabber_running()
	-- Transient state during the ~2 s prime cycle. Only meaningful when the
	-- bridge is not yet alive; if the bridge is already running the priming
	-- cycle is a no-op and the icon should stay green.
	local bridge_live  = KeLifecycle.is_bridge_running()
	local priming      = KeLifecycle.is_priming() and not bridge_live
	local action_index = build_action_index(karabiner)
	local tap_hold     = build_tap_hold_items(karabiner, action_index, update_menu, enabled)
	local raccourcis   = build_raccourcis_items(karabiner, action_index, update_menu, enabled)

	-- Status icon reflects whether KE is *actually applying* our remappings.
	-- 🟢 daemon detected AND bridge primed — remapping is genuinely active.
	-- 🔵 prime cycle currently in flight — transient (~2 s); will resolve to 🟢.
	-- 🟡 daemon detected but bridge not primed — rules are NOT pushed yet,
	--    cliquer pour amorcer (re-prime) Core-Service via le GUI silencieux.
	-- 🟡 enabled but daemon not detected — KE not installed or not started.
	-- 🔴 integration disabled in our config (independent of KE state).
	local status_title
	if active then
		status_title = i18n.get("menu.karabiner.status_active")
	elseif priming then
		status_title = i18n.get("menu.karabiner.status_priming")
	elseif enabled and grabber_only then
		status_title = i18n.get("menu.karabiner.status_not_primed")
	elseif enabled then
		status_title = i18n.get("menu.karabiner.status_no_daemon")
	else
		status_title = i18n.get("menu.karabiner.status_inactive")
	end

	local submenu = {}

	-- Status item: behavior depends on enabled state.
	-- When disabled but daemon still running: clicking stops KE (no relaunch — user wants it off).
	-- Otherwise: stop legacy user agents, force a fresh prime via the silent GUI bridge.
	local status_fn
	if not enabled and grabber_only then
		status_fn = function()
			Logger.info(LOG, "Status clicked — menu disabled, KE running → stopping all KE services…")
			local out, status = hs.execute(KARABINER_KILL_CMD)
			Logger.info(LOG, "Kill done (status=%s, out=%s).", tostring(status), tostring(out))
			if update_menu then hs.timer.doAfter(2.5, update_menu) end
		end
	else
		status_fn = function()
			Logger.info(LOG, "Status clicked — stopping legacy agents then forcing a re-prime…")
			local out, status = hs.execute(KARABINER_KILL_CMD)
			Logger.info(LOG, "Kill done (status=%s, out=%s).", tostring(status), tostring(out))
			-- Force re-prime so Core-Service re-ingests the on-disk config,
			-- ignoring the per-session marker. This is the user's escape
			-- hatch when the green dot is wrong or KE was restarted by macOS.
			hs.timer.doAfter(1.0, function()
				KeLifecycle.prime_ke_for_session(function(ok)
					Logger.info(LOG, "Re-prime callback: ok=%s.", tostring(ok))
					if update_menu then hs.timer.doAfter(0.5, update_menu) end
				end, true)
			end)
		end
	end

	submenu[#submenu + 1] = {
		title = status_title,
		fn    = status_fn,
	}
	submenu[#submenu + 1] = {
		title = i18n.get("menu.karabiner.open_gui"),
		fn    = function() karabiner.open_gui() end,
	}
	submenu[#submenu + 1] = {
		title    = i18n.get("menu.karabiner.start"),
		-- Force a fresh prime even if the session marker already exists.
		-- Useful when the daemon was killed manually or by macOS.
		disabled = bridge_live,
		fn       = function()
			Logger.start(LOG, "User requested KE bridge start…")
			KeLifecycle.prime_ke_for_session(function(ok)
				Logger.info(LOG, "Manual start: ok=%s.", tostring(ok))
				if update_menu then hs.timer.doAfter(0.5, update_menu) end
			end, true)
		end,
	}
	submenu[#submenu + 1] = {
		title    = i18n.get("menu.karabiner.stop"),
		-- Grayed when bridge is not running — nothing to stop.
		disabled = not bridge_live,
		fn       = function()
			Logger.start(LOG, "User requested KE bridge stop…")
			local ok_l, kl = pcall(require, "modules.karabiner.ke_lifecycle")
			if ok_l and kl and type(kl.run_total_reset_async) == "function" then
				local out, ok = kl.run_total_reset_async()
				Logger.info(LOG, "KE stop async: ok=%s out=%s.", tostring(ok), tostring(out))
			else
				pcall(function() hs.execute(KARABINER_KILL_CMD) end)
			end
			if update_menu then hs.timer.doAfter(2.5, update_menu) end
		end,
	}

	-- Warning: integration disabled in our config but KE process is still live.
	-- The user must quit KE (and optionally remove it from Login Items) to fully
	-- stop its remappings — our toggle alone does not kill the process.
	if not enabled and grabber_only then
		submenu[#submenu + 1] = {
			title    = i18n.get("menu.karabiner.disabled_warning_1"),
			disabled = true,
		}
		submenu[#submenu + 1] = {
			title    = i18n.get("menu.karabiner.disabled_warning_2"),
			disabled = true,
		}
		submenu[#submenu + 1] = {
			title    = i18n.get("menu.karabiner.disabled_warning_3"),
			disabled = true,
		}
		submenu[#submenu + 1] = {
			title    = i18n.get("menu.karabiner.disabled_warning_4"),
			disabled = true,
		}
	end

	-- Separator between process-control items and configuration-reset items.
	submenu[#submenu + 1] = { title = "-" }

	-- Management actions: clear-all first (destructive reset), then restore defaults,
	-- then the tap→combo propagation helper.
	submenu[#submenu + 1] = {
		title = i18n.get("menu.karabiner.clear_all"),
		fn    = function()
			Logger.start(LOG, "Clearing every tap/hold and combo slot…")
			local cleared = 0
			for _, key_def in ipairs(karabiner.TAP_HOLD_KEYS) do
				pcall(karabiner.set_tap_action,  key_def.id, "none")
				pcall(karabiner.set_hold_action, key_def.id, "none")
				cleared = cleared + 1
			end
			for _, combo_def in ipairs(karabiner.MOD_COMBOS) do
				pcall(karabiner.set_combo_combo_action, combo_def.id, "none")
				pcall(karabiner.set_combo_tap_action,   combo_def.id, "none")
				pcall(karabiner.set_combo_hold_action,  combo_def.id, "none")
				cleared = cleared + 1
			end
			pcall(karabiner.regenerate)
			Logger.success(LOG, "Cleared %d entry/entries — all slots are now 'none'.", cleared)
			if update_menu then update_menu() end
		end,
	}
	submenu[#submenu + 1] = {
		title = i18n.get("menu.karabiner.restore_defaults"),
		fn    = function()
			pcall(karabiner.reset_to_defaults)
			pcall(karabiner.regenerate)
			if update_menu then update_menu() end
		end,
	}
	submenu[#submenu + 1] = {
		title = i18n.get("menu.karabiner.copy_tap_to_combo"),
		fn    = function()
			Logger.start(LOG, "Propagating tap → combo for all modifier combos…")
			local changed = 0
			for _, combo_def in ipairs(karabiner.MOD_COMBOS) do
				local cid              = combo_def.id
				local ok_tap, tap_id   = pcall(karabiner.get_combo_tap_action,   cid)
				local ok_cmb, combo_id = pcall(karabiner.get_combo_combo_action, cid)
				if ok_tap and ok_cmb and tap_id ~= combo_id then
					pcall(karabiner.set_combo_combo_action, cid, tap_id)
					changed = changed + 1
				end
			end
			pcall(karabiner.regenerate)
			Logger.success(LOG, "Tap → combo propagation done (%d combo(s) updated).", changed)
			if update_menu then update_menu() end
		end,
	}

	-- Timing and shortcut behaviour — always configurable regardless of enabled state.
	-- Trigger-side settings first (tap/hold delay, combo window, symmetry), then the
	-- sticky-modifier delay at the bottom — the only one that acts on the output.
	submenu[#submenu + 1] = { title = "-" }
	submenu[#submenu + 1] = build_delay_item(karabiner, update_menu)
	submenu[#submenu + 1] = build_simultaneous_threshold_item(karabiner, update_menu)
	submenu[#submenu + 1] = build_combo_symmetric_item(karabiner, update_menu)
	submenu[#submenu + 1] = build_sticky_delay_item(karabiner, update_menu)

	submenu[#submenu + 1] = { title = "-" }

	-- Section 1: tap / hold keys split by hand (grayed when disabled)
	for _, item in ipairs(tap_hold) do
		submenu[#submenu + 1] = item
	end

	submenu[#submenu + 1] = { title = "-" }

	-- Section 2: modifier combo action pickers (grayed when disabled)
	submenu[#submenu + 1] = { title = i18n.section("menu.karabiner.header_shortcuts"), disabled = true }
	for _, item in ipairs(raccourcis) do
		submenu[#submenu + 1] = item
	end

	return {
		title   = "⌨️ Karabiner",
		checked = enabled,
		-- Clicking the item title toggles enabled state
		fn      = function()
			karabiner.set_enabled(not karabiner.get_enabled())
			if update_menu then update_menu() end
		end,
		menu    = submenu,
	}
end

return M
