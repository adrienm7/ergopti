--- ui/menu/menu_remap.lua

--- ==============================================================================
--- MODULE: Karabiner Menu
--- DESCRIPTION:
--- Provides the "Karabiner" submenu in the Hammerspoon menu bar.
---
--- FEATURES & RATIONALE:
--- 1. Status item: 🟢/🟡/🔴 reflects only Ergopti's exact lease state.
--- 2. Tap/Hold section: each key shows "Label : tap / hold" inline. Items are
---    grayed out when the integration is disabled.
--- 3. Raccourcis section: modifier combos grouped by key, also grayed when off.
--- 4. Delay pickers: configure tap/hold and sticky modifier timeouts globally.
--- 5. Explicit regeneration: changes are saved immediately, applied via "Régénérer".
--- ==============================================================================

local M = {}

local Logger      = require("infra.logger")
local Notifications = require("infra.notifications")
local LeaseController = require("platform.remap.lease_controller")
local MenuUtils   = require("ui.menu.menu_utils")
local ManifestMenu = require("infra.manifest_menu")
local LOG         = "menu.karabiner"
local i18n        = require("infra.i18n")
local text_utils  = require("infra.text_utils")




--- Builds the AppleScript for a numeric-input dialog.
---
--- Every interpolated label is i18n text from a 21-locale corpus, so it goes
--- through applescript_escape rather than Lua's %q. %q escapes for a LUA literal
--- and agrees with AppleScript only by coincidence — it diverges on control
--- characters and emits \ddd decimal escapes AppleScript cannot read. The four
--- call sites below used to carry four copies of this format string.
--- @param prompt string Dialog body text.
--- @param default_ms number Pre-filled numeric answer.
--- @param title string Window title.
--- @param btn_cancel string Cancel button label.
--- @param btn_ok string OK button label, also the default button.
--- @return string The AppleScript source.
local function delay_dialog_script(prompt, default_ms, title, btn_cancel, btn_ok)
	return text_utils.applescript_format(
		"display dialog \"%s\" default answer \"%d\" with title \"%s\" "
			.. "buttons {\"%s\", \"%s\"} default button \"%s\"",
		prompt, default_ms, title, btn_cancel, btn_ok, btn_ok)
end

-- Label displayed when both tap and hold are "none"
local NONE_DISPLAY = "—"




-- =====================================
-- =====================================
-- ======= 1/ Helper Utilities =========
-- =====================================
-- =====================================

--- Reads exact Ergopti lease state without probing any stock process.
--- @return string phase Controller lifecycle phase.
--- @return table snapshot Controller status snapshot.
local function read_lease_status()
	local ok, phase, snapshot = pcall(LeaseController.status)
	if not ok or type(phase) ~= "string" then return "failed", {} end
	return phase, type(snapshot) == "table" and snapshot or {}
end

--- Requests an exact-lease regeneration without letting a menu callback throw.
--- @param karabiner table Remap facade.
--- @param source string User action label for diagnostics.
--- @return boolean accepted
local function request_regeneration(karabiner, source)
	local ok, requested_or_err = xpcall(function()
		return karabiner.regenerate()
	end, debug.traceback)
	if not ok or requested_or_err ~= true then
		Logger.error(LOG, "%s exact lease start request failed: %s.",
			tostring(source), tostring(requested_or_err))
		return false
	end
	return true
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
		return (string.format("%.1f s", ms / 1000):gsub("%.", ","))
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
				label   = action.label,
				checked = (aid == current_id),
				action      = function()
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
		if #items > 0 then items[#items + 1] = { separator = true } end
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

--- Reads tap_hold_keys_catalog from the shared menu manifest and returns a
--- lookup table of key_id -> true for keys with hand="left" and platforms
--- including "hs". Falls back to the hardcoded set on any load failure.
---
--- Defined BEFORE the LEFT_HAND_IDS call site below: a `local function` is not
--- hoisted, so calling it above its definition would bind the nil global and
--- crash the module at load time (project-lua-closure-before-local-nil-global).
--- @return table
local function _load_left_hand_from_catalog()
	local fallback = {
		escape        = true,
		tab           = true,
		caps_lock     = true,
		left_shift    = true,
		action            = true,
		left_control  = true,
		left_option   = true,
		left_command  = true,
		spacebar      = true,
	}
	-- The one reader of menu_manifest.json (infra/manifest_menu, cached).
	--
	-- This used to fall back to opening and decoding the file right here, "in case
	-- manifest_menu is not loaded yet". require is synchronous in Lua: if the module
	-- resolves, its accessor works, and if it does not resolve then a second copy of
	-- the same io.open would not help either. What the guard actually did was keep a
	-- third reader of this file alive on a path nothing could reach — which is how
	-- the driver came to have three of them.
	local ok_mm, mm = pcall(require, "infra.manifest_menu")
	if not ok_mm or type(mm) ~= "table" or type(mm.get_root) ~= "function" then
		Logger.error(LOG, "infra.manifest_menu unavailable — left-hand catalogue uses the built-in set.")
		return fallback
	end
	local data = mm.get_root()
	if type(data) ~= "table" then return fallback end
	local catalog = data.tap_hold_keys_catalog
	if type(catalog) ~= "table" then return fallback end
	local result = {}
	for _, key_def in ipairs(catalog) do
		if type(key_def) ~= "table" then goto continue end
		if key_def.hand ~= "left" then goto continue end
		local plats = key_def.platforms
		if type(plats) ~= "table" then goto continue end
		for _, p in ipairs(plats) do
			if p == "hs" then
				result[key_def.id] = true
				break
			end
		end
		::continue::
	end
	if next(result) == nil then return fallback end
	return result
end

-- Keys belonging to the left hand (including spacebar, typically thumb-left).
-- Right-hand keys are everything else.
--
-- **Derived from _shared/modules/menu/menu_manifest.json tap_hold_keys_catalog
-- (MENU-4).** Keys with hand="left" and platforms including "hs" are left-hand;
-- everything else is right-hand. The catalog is the single source of truth.
local LEFT_HAND_IDS = _load_left_hand_from_catalog()

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

	-- Per-key tap/hold threshold: the effective value is the per-key override when
	-- set, otherwise the single global timeout (no duplicated literal when unset).
	local global_ms = karabiner.get_tap_hold_timeout() or karabiner.DEFAULT_TAP_HOLD_TIMEOUT_MS
	local ok_to, per_key_ms = pcall(karabiner.get_tap_timeout, kid)
	if not ok_to then per_key_ms = nil end
	local effective_ms = per_key_ms or global_ms

	-- Show "—" when nothing is configured on this key
	local combo_label = (current_tap == "none" and current_hold == "none")
		and NONE_DISPLAY
		or  (tap_slbl .. "  /  " .. hold_slbl)

	local key_submenu = {
		{
			label    = i18n.get("menu.karabiner.nothing_tap_hold"),
			disabled = (current_tap == "none" and current_hold == "none"),
			action       = function()
				pcall(karabiner.set_tap_action,  kid, "none")
				pcall(karabiner.set_hold_action, kid, "none")
				pcall(karabiner.regenerate)
				if update_menu then update_menu() end
			end,
		},
		{ separator = true },
		{
			label = string.format(i18n.get("menu.karabiner.tap_arrow"), tap_slbl),
			items  = build_action_picker(
				karabiner,
				function(action_id) karabiner.set_tap_action(kid, action_id) end,
				current_tap,
				update_menu,
				"tap"
			),
		},
		{
			label = string.format(i18n.get("menu.karabiner.hold_arrow"), hold_slbl),
			items  = build_action_picker(
				karabiner,
				function(action_id) karabiner.set_hold_action(kid, action_id) end,
				current_hold,
				update_menu,
				"hold"
			),
		},
		{ separator = true },
		-- Per-key tap/hold delay: open a free-text dialog to set a custom value, or
		-- revert to the single global delay. The title shows the effective value.
		{
			label = string.format(i18n.get("menu.karabiner.key_tap_delay"), fmt_delay(effective_ms)),
			items  = {
				{
					label = i18n.get("menu.karabiner.key_tap_delay_set"),
					action    = function()
						hs.focus()
						local prompt = string.format(
							i18n.get("menu.karabiner.key_tap_delay_dialog_prompt"), global_ms)
						local title_d    = i18n.get("menu.karabiner.key_tap_delay_dialog_title")
						local btn_ok     = i18n.get("button.ok")
						local btn_cancel = i18n.get("button.cancel")
						local script = delay_dialog_script(prompt, effective_ms, title_d, btn_cancel, btn_ok)
						local ok, result = hs.osascript.applescript(script)
						if not ok or type(result) ~= "table" then return end
						local ms = tonumber(result["text returned"])
						if not ms or ms <= 0 then
							Logger.warn(LOG, "Invalid per-key delay '%s' — ignored.", tostring(result["text returned"]))
							return
						end
						karabiner.set_tap_timeout(kid, math.floor(ms))
						pcall(karabiner.regenerate)
						if update_menu then update_menu() end
					end,
				},
				{
					label   = string.format(i18n.get("menu.karabiner.key_tap_delay_use_global"), fmt_delay(global_ms)),
					checked = (per_key_ms == nil),
					disabled = (per_key_ms == nil),
					action      = function()
						karabiner.set_tap_timeout(kid, nil)
						pcall(karabiner.regenerate)
						if update_menu then update_menu() end
					end,
				},
			},
		},
	}

	return {
		label    = string.format("%s  :  %s", key_def.label, combo_label),
		checked  = is_active or nil,
		disabled = not enabled or nil,
		items     = enabled and key_submenu or nil,
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

	-- `label`, not `title`: these three go into the `karabiner_tap_holds` provider
	-- array, and a row the renderer finds no label on is dropped — so all three
	-- headers were missing and the two hands ran together in one undivided list.
	items[#items + 1] = { label = i18n.section("menu.karabiner.header_taps_holds"), disabled = true }
	items[#items + 1] = { label = i18n.section("menu.karabiner.left_hand"),         disabled = true }
	for _, key_def in ipairs(karabiner.TAP_HOLD_KEYS) do
		if LEFT_HAND_IDS[key_def.id] then
			items[#items + 1] = build_one_tap_hold_item(
				karabiner, action_index, update_menu, enabled, key_def)
		end
	end

	items[#items + 1] = { label = i18n.section("menu.karabiner.right_hand"), disabled = true }
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
			label    = i18n.get("menu.karabiner.nothing_combo"),
			disabled = is_empty,
			action       = function()
				pcall(karabiner.set_combo_combo_action, cid, "none")
				pcall(karabiner.set_combo_tap_action,   cid, "none")
				pcall(karabiner.set_combo_hold_action,  cid, "none")
				pcall(karabiner.regenerate)
				if update_menu then update_menu() end
			end,
		},
		{ separator = true },
		{
			label = string.format(i18n.get("menu.karabiner.combo_arrow"), combo_slbl),
			items  = build_action_picker(
				karabiner,
				function(action_id) karabiner.set_combo_combo_action(cid, action_id) end,
				current_combo,
				update_menu,
				"combo"
			),
		},
		{
			label = string.format(i18n.get("menu.karabiner.tap_colon"), tap_slbl),
			items  = build_action_picker(
				karabiner,
				function(action_id) karabiner.set_combo_tap_action(cid, action_id) end,
				current_tap,
				update_menu,
				"tap"
			),
		},
		{
			label = string.format(i18n.get("menu.karabiner.hold_colon"), hold_slbl),
			items  = build_action_picker(
				karabiner,
				function(action_id) karabiner.set_combo_hold_action(cid, action_id) end,
				current_hold,
				update_menu,
				"hold"
			),
		},
	}

	return {
		label    = string.format("%s  :  %s", combo_def.label, combo_label),
		checked  = is_active or nil,
		disabled = not enabled or nil,
		items     = enabled and combo_submenu or nil,
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
			items[#items + 1] = MenuUtils.build_section_header(combo_def.group)
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
		label = string.format(i18n.get("menu.karabiner.tap_hold_title"), fmt_delay(timeout_ms)),
		action    = function()
			-- Bring Hammerspoon to front so the dialog appears above other windows
			hs.focus()
			local prompt = string.format(i18n.get("menu.karabiner.tap_hold_dialog_prompt"), karabiner.DEFAULT_TAP_HOLD_TIMEOUT_MS)
			local title_d = i18n.get("menu.karabiner.tap_hold_dialog_title")
			local btn_ok = i18n.get("button.ok")
			local btn_cancel = i18n.get("button.cancel")
			local script = delay_dialog_script(prompt,
				timeout_ms or karabiner.DEFAULT_TAP_HOLD_TIMEOUT_MS, title_d, btn_cancel, btn_ok)
			local ok, result = hs.osascript.applescript(script)
			Logger.debug(LOG, "Delay input dialog: ok=%s result=%s.", tostring(ok), hs.inspect(result))
			if not ok or type(result) ~= "table" then return end
			local ms = tonumber(result["text returned"])
			if not ms or ms <= 0 then
				Logger.warn(LOG, "Invalid delay input '%s' — ignored.", tostring(result["text returned"]))
				return
			end
			karabiner.set_tap_hold_timeout(math.floor(ms))
			-- The setter only persists to the user config; without this the menu
			-- would show the new threshold while typing kept the old one until an
			-- unrelated click regenerated karabiner.json (every sibling item here
			-- regenerates explicitly for exactly that reason).
			pcall(karabiner.regenerate)
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
		label = string.format(i18n.get("menu.karabiner.sticky_title"), fmt_delay(timeout_ms)),
		action    = function()
			hs.focus()
			local prompt = i18n.get("menu.karabiner.sticky_dialog_prompt")
			local title_d = i18n.get("menu.karabiner.sticky_dialog_title")
			local btn_ok = i18n.get("button.ok")
			local btn_cancel = i18n.get("button.cancel")
			local script = delay_dialog_script(prompt,
				timeout_ms or karabiner.DEFAULT_STICKY_TIMEOUT_MS, title_d, btn_cancel, btn_ok)
			local ok, result = hs.osascript.applescript(script)
			Logger.debug(LOG, "Sticky delay input: ok=%s result=%s.", tostring(ok), hs.inspect(result))
			if not ok or type(result) ~= "table" then return end
			local ms = tonumber(result["text returned"])
			if not ms or ms <= 0 then
				Logger.warn(LOG, "Invalid sticky delay '%s' — ignored.", tostring(result["text returned"]))
				return
			end
			karabiner.set_sticky_timeout(math.floor(ms))
			-- Same rationale as the tap/hold delay above: the setter persists but
			-- never regenerates, so without this the new value only reaches the
			-- keyboard on some later, unrelated click.
			pcall(karabiner.regenerate)
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
		label = string.format(i18n.get("menu.karabiner.simultaneous_title"), fmt_delay(threshold_ms)),
		action    = function()
			hs.focus()
			local prompt = string.format(i18n.get("menu.karabiner.simultaneous_dialog_prompt"), karabiner.DEFAULT_SIMULTANEOUS_THRESHOLD_MS)
			local title_d = i18n.get("menu.karabiner.simultaneous_dialog_title")
			local btn_ok = i18n.get("button.ok")
			local btn_cancel = i18n.get("button.cancel")
			local script = delay_dialog_script(prompt,
				threshold_ms or karabiner.DEFAULT_SIMULTANEOUS_THRESHOLD_MS, title_d, btn_cancel, btn_ok)
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
		label   = i18n.get("menu.karabiner.symmetric"),
		checked = is_symmetric,
		action      = function()
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
-- Cached tap/hold + raccourcis picker trees. Building them is the dominant cost
-- of opening the menubar (~300-380 ms measured): 182 modifier combos × a 73-action
-- picker each is ~40k menu tables + closures, and the old code rebuilt the whole
-- lot on EVERY click. The trees depend only on the per-slot action bindings, the
-- symmetric-combo toggle and the enabled flag, so we memoise them under a
-- fingerprint of exactly those inputs and rebuild only when a binding actually
-- changes. A click that edits a binding changes the fingerprint, so the next open
-- rebuilds with fresh checkmarks. update_menu is a stable upvalue (set once in
-- ui.menu.init), so the cached closures stay valid across opens.
local _picker_cache = nil
local _toggle_in_flight = false

--- Cheap fingerprint of every input that affects the picker trees. Reads in-memory
--- config accessors only (no I/O), so it is far cheaper than a rebuild.
--- @param karabiner table The karabiner module.
--- @param enabled boolean Whether the integration is active.
--- @return string
local function picker_fingerprint(karabiner, enabled)
	local parts = { enabled and "1" or "0" }
	local ok_sym, sym = pcall(karabiner.get_combo_symmetric)
	parts[#parts + 1] = (ok_sym and sym) and "1" or "0"
	-- The global tap/hold timeout is rendered in every per-key delay submenu
	-- (the "use global (%s)" label and the effective value when no override), so a
	-- global change must invalidate the cached picker trees as well.
	local ok_g, g = pcall(karabiner.get_tap_hold_timeout)
	parts[#parts + 1] = (ok_g and g ~= nil) and tostring(g) or "none"
	local function add(getter, id)
		local ok, v = pcall(getter, id)
		parts[#parts + 1] = (ok and v ~= nil) and tostring(v) or "none"
	end
	for _, kd in ipairs(karabiner.TAP_HOLD_KEYS or {}) do
		add(karabiner.get_tap_action,  kd.id)
		add(karabiner.get_hold_action, kd.id)
		add(karabiner.get_tap_timeout, kd.id)  -- per-key delay shows in the submenu label
	end
	for _, cd in ipairs(karabiner.MOD_COMBOS or {}) do
		add(karabiner.get_combo_combo_action, cd.id)
		add(karabiner.get_combo_tap_action,   cd.id)
		add(karabiner.get_combo_hold_action,  cd.id)
	end
	return table.concat(parts, "|")
end

--- Returns the (memoised) tap/hold and raccourcis picker trees, rebuilding only
--- when the binding fingerprint changes. See _picker_cache rationale above.
--- @return table tap_hold, table raccourcis
local function build_picker_trees(karabiner, update_menu, enabled)
	local fp = picker_fingerprint(karabiner, enabled)
	if _picker_cache and _picker_cache.fp == fp then
		Logger.debug(LOG, "Picker trees served from cache.")
		return _picker_cache.tap_hold, _picker_cache.raccourcis
	end
	Logger.debug(LOG, "Picker trees rebuilt (binding fingerprint changed).")
	local action_index = build_action_index(karabiner)
	local tap_hold   = build_tap_hold_items(karabiner, action_index, update_menu, enabled)
	local raccourcis = build_raccourcis_items(karabiner, action_index, update_menu, enabled)
	_picker_cache = { fp = fp, tap_hold = tap_hold, raccourcis = raccourcis }
	return tap_hold, raccourcis
end

--- Builds the complete Karabiner menu item with its submenu.
---
--- `karabiner_menu` in the shared manifest owns the structural sequence:
--- status/lifecycle rows, destructive Ergopti configuration commands, timings,
--- tap/hold bindings, then modifier shortcuts. This module supplies only the
--- dynamic provider rows and command capabilities consumed by that manifest.
--- @param ctx table Global UI context (must contain ctx.karabiner).
--- @return table|nil A hs.menubar menu item with a submenu, or nil on failure.
function M.build(ctx)
	local karabiner   = ctx and ctx.karabiner
	local update_menu = ctx and ctx.updateMenu

	if not karabiner then
		Logger.warn(LOG, "Karabiner module absent from context — submenu skipped.")
		return nil
	end

	local enabled = karabiner.get_enabled()
	-- Status is an in-memory lease-controller read. Opening this submenu while
	-- disabled never probes, launches or otherwise touches stock Karabiner.
	local phase, snapshot = read_lease_status()
	local active        = enabled and phase == "active"
	local transitioning = enabled and (phase == "starting" or phase == "pausing"
		or phase == "resuming" or phase == "stopping")
	local lease_attached = phase == "starting" or phase == "active" or phase == "paused"
		or phase == "pausing" or phase == "resuming" or phase == "stopping"
	local guardian_approval_required = enabled
		and snapshot.guardian_status == "requires_approval"
	local tap_hold, raccourcis = build_picker_trees(karabiner, update_menu, enabled)

	-- The icon reports only facts Ergopti owns: exact lease active, transitioning,
	-- enabled-but-inactive, or disabled. It never infers ownership from a shared PID.
	local status_title
	if guardian_approval_required then
		status_title = i18n.get("menu.karabiner.status_guardian_approval_required")
	elseif active then
		status_title = i18n.get("menu.karabiner.status_active")
	elseif transitioning then
		status_title = i18n.get("menu.karabiner.status_priming")
	elseif enabled then
		status_title = i18n.get("menu.karabiner.status_not_primed")
	else
		status_title = i18n.get("menu.karabiner.status_inactive")
	end

	local status_rows = {}

	local status_action = nil
	if guardian_approval_required then
		status_action = function()
			-- Menu closures can outlive the state they rendered. Re-read the facade
			-- before any native launch so disabling the integration makes this inert.
			local enabled_ok, still_enabled = pcall(karabiner.get_enabled)
			if not enabled_ok or still_enabled ~= true then
				Logger.debug(LOG,
					"Ignoring stale guardian approval action after Karabiner integration disable.")
				return
			end

			local callback_fired = false
			local function finish(ok, reason)
				if callback_fired then return end
				callback_fired = true
				if ok ~= true then
					Logger.error(LOG, "Could not open Login Items settings: %s.", tostring(reason))
					Notifications.notify(
						i18n.get("karabiner.guardian_settings_open_failed"), nil, "error")
				end
				if update_menu then pcall(update_menu) end
			end
			local call_ok, accepted_or_err = xpcall(function()
				return karabiner.open_guardian_settings(finish)
			end, debug.traceback)
			if not call_ok then
				finish(false, "settings-action-raised: " .. tostring(accepted_or_err))
			elseif accepted_or_err ~= true and not callback_fired then
				finish(false, "settings-action-rejected")
			end
		end
	elseif enabled then
		status_action = function()
			Logger.info(LOG, "Status clicked — rebuilding inert rules and requesting exact lease activation.")
			request_regeneration(karabiner, "Status rebuild")
			if update_menu then pcall(update_menu) end
		end
	end
	status_rows[#status_rows + 1] = {
		label    = status_title,
		disabled = not enabled,
		action   = status_action,
	}
	status_rows[#status_rows + 1] = {
		label  = i18n.get("menu.karabiner.open_gui"),
		action = function() karabiner.open_gui() end,
	}
	status_rows[#status_rows + 1] = {
		label    = i18n.get("menu.karabiner.start"),
		disabled = not enabled or lease_attached,
		action   = function()
			Logger.start(LOG, "User requested exact Ergopti Karabiner lease start…")
			request_regeneration(karabiner, "Menu Start")
			if update_menu then pcall(update_menu) end
		end,
	}
	status_rows[#status_rows + 1] = {
		label    = i18n.get("menu.karabiner.stop"),
		disabled = not enabled or not lease_attached,
		action   = function()
			local stop_ok, requested_or_err = xpcall(function()
				return karabiner.stop_lease(function()
					if update_menu then pcall(update_menu) end
				end)
			end, debug.traceback)
			if not stop_ok or requested_or_err ~= true then
				Logger.error(LOG, "Exact lease stop request was not accepted: %s.",
					tostring(requested_or_err))
			end
		end,
	}


	-- The rows this driver still assembles, handed to the SHARED renderer as
	-- provider data. The manifest describes the menu's shape — process control,
	-- the destructive resets, the timings, then tap-holds and chords under their
	-- own headers — and this file answers with the rows for each slot.
	local providers = {
		["karabiner_status"] = function() return status_rows end,
		["karabiner_delays"] = function()
			local rows = {}
			for _, item in ipairs({
				build_delay_item(karabiner, update_menu),
				build_simultaneous_threshold_item(karabiner, update_menu),
				build_combo_symmetric_item(karabiner, update_menu),
				build_sticky_delay_item(karabiner, update_menu),
			}) do
				rows[#rows + 1] = item
			end
			return rows
		end,
		["karabiner_tap_holds"] = function()
			local rows = {}
			for _, item in ipairs(tap_hold) do rows[#rows + 1] = item end
			return rows
		end,
		["karabiner_shortcuts"] = function()
			local rows = {}
			for _, item in ipairs(raccourcis) do rows[#rows + 1] = item end
			return rows
		end,
	}

	local commands = {
		["karabiner_clear_all"] = function()
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
		["karabiner_restore_defaults"] = function()
			pcall(karabiner.reset_to_defaults)
			pcall(karabiner.regenerate)
			if update_menu then update_menu() end
		end,
		["karabiner_copy_tap_to_combo"] = function()
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

	local render_ctx = {}
	for key, value in pairs(ctx or {}) do render_ctx[key] = value end
	render_ctx.commands = commands

	local submenu = ManifestMenu.build("karabiner_menu", "Karabiner", nil, nil, render_ctx, providers)

	return {
		label   = "⌨️ Karabiner",
		checked = enabled,
		-- Clicking the item title toggles enabled state
		action      = function()
			if _toggle_in_flight then return end
			_toggle_in_flight = true
			local target_enabled = not enabled
			local callback_fired = false
			local ok_request, accepted_or_err = pcall(karabiner.set_enabled, target_enabled, function(ok)
				callback_fired = true
				_toggle_in_flight = false
				if ok ~= true then
					local key = target_enabled and "karabiner.enable_failed" or "karabiner.disable_failed"
					Notifications.notify(i18n.get(key), nil, "error")
				end
				if update_menu then update_menu() end
			end)
			if not ok_request or accepted_or_err ~= true then
				if not callback_fired then
					_toggle_in_flight = false
					Logger.error(LOG, "Karabiner integration toggle request failed: %s.", tostring(accepted_or_err))
					local key = target_enabled and "karabiner.enable_failed" or "karabiner.disable_failed"
					Notifications.notify(i18n.get(key), nil, "error")
				end
			end
			if update_menu then update_menu() end
		end,
		items    = submenu,
	}
end

--- Warms the picker-tree cache off the menu-open path so the first click renders
--- instantly instead of paying the ~300-380 ms build. Called from ui.menu.init
--- once boot settles. Safe to call repeatedly.
--- @param ctx table Menu context (provides karabiner + updateMenu).
function M.prime(ctx)
	local karabiner = ctx and ctx.karabiner
	if not karabiner or type(karabiner.get_enabled) ~= "function" then return end
	local ok, enabled = pcall(karabiner.get_enabled)
	pcall(build_picker_trees, karabiner, ctx and ctx.updateMenu, ok and enabled or false)
end

-- Perf / cache test seams.
M._picker_fingerprint  = picker_fingerprint
M._build_picker_trees  = build_picker_trees
M._reset_picker_cache  = function() _picker_cache = nil end

return M
