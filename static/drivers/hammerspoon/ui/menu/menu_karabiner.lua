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

local Logger = require("lib.logger")
local LOG    = "menu.karabiner"

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

-- karabiner_session_monitor is a user-level launchd agent that runs only when
-- KE is actively remapping. System-level daemons (DriverKit, core service) are
-- always present when KE is installed and must not be used as the active signal.
local GRABBER_CHECK_CMD = "/bin/launchctl list | /usr/bin/grep -q karabiner_session_monitor"

-- Label displayed when both tap and hold are "none"
local NONE_DISPLAY = "—"




-- =====================================
-- =====================================
-- ======= 1/ Helper Utilities =========
-- =====================================
-- =====================================

--- Returns true when any Karabiner process is currently running.
--- @return boolean
local function is_karabiner_running()
	local _, ok = hs.execute(GRABBER_CHECK_CMD)
	return ok == true
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
--- @param slot        string   "tap" or "hold".
--- @return table List of hs.menubar menu item tables.
local function build_action_picker(karabiner, set_fn, current_id, update_menu, slot)
	local items            = {}
	local current_category = nil

	for _, action in ipairs(karabiner.AVAILABLE_ACTIONS) do
		if slot == "hold" and not action.holdable       then goto continue end
		if slot == "tap"  and action.tappable == false  then goto continue end

		if action.category ~= current_category then
			if current_category ~= nil then
				items[#items + 1] = { title = "-" }
			end
			-- "Spécial" items (none, CapsWord) are shown ungrouped at the top
			if action.category ~= "Spécial" then
				items[#items + 1] = { title = action.category, disabled = true }
			end
			current_category = action.category
		end

		-- Capture action.id as a local so each closure has its own value
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

		::continue::
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
			title    = "— Rien (effacer tap et hold) —",
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
			title = string.format("Tap  ➜  %s", tap_slbl),
			menu  = build_action_picker(
				karabiner,
				function(action_id) karabiner.set_tap_action(kid, action_id) end,
				current_tap,
				update_menu,
				"tap"
			),
		},
		{
			title = string.format("Hold ➜  %s", hold_slbl),
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

	items[#items + 1] = { title = "===== Taps / Holds =====", disabled = true }
	items[#items + 1] = { title = "— Main gauche —", disabled = true }
	for _, key_def in ipairs(karabiner.TAP_HOLD_KEYS) do
		if LEFT_HAND_IDS[key_def.id] then
			items[#items + 1] = build_one_tap_hold_item(
				karabiner, action_index, update_menu, enabled, key_def)
		end
	end

	items[#items + 1] = { title = "— Main droite —", disabled = true }
	for _, key_def in ipairs(karabiner.TAP_HOLD_KEYS) do
		if not LEFT_HAND_IDS[key_def.id] then
			items[#items + 1] = build_one_tap_hold_item(
				karabiner, action_index, update_menu, enabled, key_def)
		end
	end

	return items
end




-- ==========================================
-- ==========================================
-- ======= 4/ Raccourcis (Mod Combos) =======
-- ==========================================
-- ==========================================

--- Builds a single combo menu item with tap + hold sub-pickers.
--- Mirrors the tap / hold key layout: label  :  TapLabel  /  HoldLabel.
--- @param karabiner   table    The karabiner module.
--- @param action_index table   id → action def map.
--- @param update_menu function Callback to refresh the menu bar.
--- @param enabled     boolean  Whether the integration is active.
--- @param combo_def   table    Entry from MOD_COMBOS.
--- @return table hs.menubar menu item.
local function build_one_combo_item(karabiner, action_index, update_menu, enabled, combo_def)
	local cid = combo_def.id

	local ok_tap,  current_tap  = pcall(karabiner.get_combo_tap_action,  cid)
	local ok_hold, current_hold = pcall(karabiner.get_combo_hold_action, cid)
	if not ok_tap  then current_tap  = "none" end
	if not ok_hold then current_hold = "none" end

	local tap_slbl  = short_action_label(action_index, current_tap)
	local hold_slbl = short_action_label(action_index, current_hold)
	local is_active = (current_tap ~= "none" or current_hold ~= "none")

	local combo_label = (current_tap == "none" and current_hold == "none")
		and NONE_DISPLAY
		or  (tap_slbl .. "  /  " .. hold_slbl)

	local combo_submenu = {
		{
			title    = "— Rien (effacer tap et hold) —",
			disabled = (current_tap == "none" and current_hold == "none"),
			fn       = function()
				pcall(karabiner.set_combo_tap_action,  cid, "none")
				pcall(karabiner.set_combo_hold_action, cid, "none")
				pcall(karabiner.regenerate)
				if update_menu then update_menu() end
			end,
		},
		{ title = "-" },
		{
			title = string.format("Tap  :  %s", tap_slbl),
			menu  = build_action_picker(
				karabiner,
				function(action_id) karabiner.set_combo_tap_action(cid, action_id) end,
				current_tap,
				update_menu,
				"tap"
			),
		},
		{
			title = string.format("Hold  :  %s", hold_slbl),
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

	for _, combo_def in ipairs(karabiner.MOD_COMBOS) do
		-- Skip combos handled elsewhere (e.g. script_control.lua shortcuts)
		if combo_def.menu_hidden then goto continue end

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
-- ====================================
-- ======= 5/ Delay Input Items =======
-- ====================================
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
		title = string.format("Délai tap / hold : %s", fmt_delay(timeout_ms)),
		fn    = function()
			-- Bring Hammerspoon to front so the dialog appears above other windows
			hs.focus()
			local script = string.format(
				"display dialog \"Délai tap / hold en millisecondes\\n"
				.. "(défaut Karabiner : %d ms)\" "
				.. "default answer \"%d\" "
				.. "with title \"Karabiner — Délai tap / hold\" "
				.. "buttons {\"Annuler\", \"OK\"} "
				.. "default button \"OK\"",
				karabiner.DEFAULT_TAP_HOLD_TIMEOUT_MS,
				timeout_ms or karabiner.DEFAULT_TAP_HOLD_TIMEOUT_MS
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
		title = string.format("Délai modificateur sticky : %s", fmt_delay(timeout_ms)),
		fn    = function()
			hs.focus()
			local script = string.format(
				"display dialog \"Délai d'annulation sticky (millisecondes)\\n"
				.. "Après ce délai sans frappe, le modificateur one-shot est annulé.\" "
				.. "default answer \"%d\" "
				.. "with title \"Karabiner — Délai sticky\" "
				.. "buttons {\"Annuler\", \"OK\"} "
				.. "default button \"OK\"",
				timeout_ms or karabiner.DEFAULT_STICKY_TIMEOUT_MS
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
	local running      = is_karabiner_running()
	local action_index = build_action_index(karabiner)
	local tap_hold     = build_tap_hold_items(karabiner, action_index, update_menu, enabled)
	local raccourcis   = build_raccourcis_items(karabiner, action_index, update_menu, enabled)

	-- Status icon reflects the actual process state, independent of our toggle.
	-- 🟢 running, 🟡 enabled in config but process not detected, 🔴 not running.
	local status_title
	if running then
		status_title = "🟢 Karabiner actif"
	elseif enabled then
		status_title = "🟡 Karabiner actif — processus non détecté, cliquer pour relancer"
	else
		status_title = "🔴 Karabiner inactif — cliquer pour relancer"
	end

	local submenu = {}

	-- Status item: behavior depends on enabled state.
	-- When disabled but running: clicking stops KE (no relaunch — user wants it off).
	-- Otherwise: stop all services then relaunch (restart / wake up KE).
	local status_fn
	if not enabled and running then
		status_fn = function()
			Logger.info(LOG, "Status clicked — menu disabled, KE running → stopping all KE services…")
			local out, status = hs.execute(KARABINER_KILL_CMD)
			Logger.info(LOG, "Kill done (status=%s, out=%s).", tostring(status), tostring(out))
			if update_menu then hs.timer.doAfter(2.5, update_menu) end
		end
	else
		status_fn = function()
			Logger.info(LOG, "Status clicked — stopping then relaunching KE headless…")
			local out, status = hs.execute(KARABINER_KILL_CMD)
			Logger.info(LOG, "Kill done (status=%s, out=%s).", tostring(status), tostring(out))
			hs.timer.doAfter(1.5, function() karabiner.launch_headless() end)
			if update_menu then hs.timer.doAfter(4, update_menu) end
		end
	end

	submenu[#submenu + 1] = {
		title = status_title,
		fn    = status_fn,
	}
	submenu[#submenu + 1] = {
		title = "Ouvrir Karabiner-Elements",
		-- Stop the startup suppressor first, then open — avoids the watcher killing the app
		fn    = function() karabiner.open_gui() end,
	}

	-- Warning: integration disabled in our config but KE process is still live.
	-- The user must quit KE (and optionally remove it from Login Items) to fully
	-- stop its remappings — our toggle alone does not kill the process.
	if not enabled and running then
		submenu[#submenu + 1] = {
			title    = "⚠️  Menu désactivé mais Karabiner tourne encore.",
			disabled = true,
		}
		submenu[#submenu + 1] = {
			title    = "      Les remappages sont donc toujours actifs.",
			disabled = true,
		}
		submenu[#submenu + 1] = {
			title    = "      Pour tout stopper : cliquer sur 🟢 ci-dessus,",
			disabled = true,
		}
		submenu[#submenu + 1] = {
			title    = "      et retirer Karabiner des apps au démarrage.",
			disabled = true,
		}
	end

	-- Management actions
	submenu[#submenu + 1] = {
		title = "↩  Remettre les valeurs par défaut",
		fn    = function()
			pcall(karabiner.reset_to_defaults)
			if update_menu then update_menu() end
		end,
	}

	-- Delay settings — separated from management, always configurable
	submenu[#submenu + 1] = { title = "-" }
	submenu[#submenu + 1] = build_delay_item(karabiner, update_menu)
	submenu[#submenu + 1] = build_sticky_delay_item(karabiner, update_menu)

	submenu[#submenu + 1] = { title = "-" }

	-- Section 1: tap / hold keys split by hand (grayed when disabled)
	for _, item in ipairs(tap_hold) do
		submenu[#submenu + 1] = item
	end

	submenu[#submenu + 1] = { title = "-" }

	-- Section 2: modifier combo action pickers (grayed when disabled)
	submenu[#submenu + 1] = { title = "===== Raccourcis =====", disabled = true }
	for _, item in ipairs(raccourcis) do
		submenu[#submenu + 1] = item
	end

	return {
		title   = "Karabiner ⌨️",
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
