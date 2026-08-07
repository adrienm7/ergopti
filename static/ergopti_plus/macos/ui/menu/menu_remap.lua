--- ui/menu/menu_remap.lua

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

local Logger      = require("infra.logger")
local KeLifecycle = require("platform.remap.ke_lifecycle")
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

-- KE process-status probes (is_remapping_active / is_grabber_running /
-- is_bridge_running) each spawn a pgrep / CLI-roundtrip subprocess (~30-100 ms,
-- variable), and build() ran ~4 of them on EVERY open — the real ~240-400 ms menu
-- cost (the picker trees above are already memoised). KE process state changes
-- only when the daemon starts/stops, so we serve the last-known status instantly
-- and refresh it OFF the menu-build path (deferred to the next runloop tick). The
-- status icon is at most one open stale; is_priming() stays a live in-memory read.
local _ke_status = nil          -- { active, grabber, bridge }
local _ke_status_ts = 0
local _ke_status_refreshing = false
local KE_STATUS_REFRESH_THROTTLE = 2  -- min seconds between background refreshes

local function _now_s()
	return (hs.timer and type(hs.timer.secondsSinceEpoch) == "function") and hs.timer.secondsSinceEpoch() or 0
end

--- Synchronously reads the subprocess-backed KE status bundle. Slow — only ever
--- called off the menu-build path (cold prime or background refresh).
local function read_ke_status()
	return {
		active  = is_remapping_active(),
		grabber = KeLifecycle.is_grabber_running(),
		bridge  = KeLifecycle.is_bridge_running(),
	}
end

--- Schedules a throttled background refresh of the KE status cache so menu opens
--- never block on pgrep. The synchronous probes run on a later runloop tick.
--- @param update_menu function|nil Menubar refresh callback.
local function refresh_ke_status_async(update_menu)
	if _ke_status_refreshing then return end
	if _ke_status and (_now_s() - _ke_status_ts) < KE_STATUS_REFRESH_THROTTLE then return end
	_ke_status_refreshing = true
	local function run()
		local fresh = read_ke_status()
		_ke_status_refreshing = false
		local changed = (not _ke_status)
			or _ke_status.active  ~= fresh.active
			or _ke_status.grabber ~= fresh.grabber
			or _ke_status.bridge  ~= fresh.bridge
		_ke_status    = fresh
		_ke_status_ts = _now_s()
		Logger.debug(LOG, "KE status refreshed (active=%s grabber=%s bridge=%s changed=%s).",
			tostring(fresh.active), tostring(fresh.grabber), tostring(fresh.bridge), tostring(changed))
		-- Refresh the menubar icon when the status changed; the already-open menu is
		-- unaffected, but the next open and the icon reflect the new state.
		if changed and type(update_menu) == "function" then pcall(update_menu) end
	end
	if hs.timer and type(hs.timer.doAfter) == "function" then
		hs.timer.doAfter(0, run)
	else
		run()
	end
end

--- Returns the KE status bundle WITHOUT blocking: serves the cached value (a
--- single cold read if empty) and schedules a background refresh.
--- @param update_menu function|nil Menubar refresh callback.
--- @return table { active, grabber, bridge }
local function get_ke_status(update_menu)
	if not _ke_status then
		_ke_status    = read_ke_status()
		_ke_status_ts = _now_s()
	end
	refresh_ke_status_async(update_menu)
	return _ke_status
end

--- Builds the complete Karabiner menu item with its submenu.
---
--- **There is no manifest key for this menu.** This docstring used to say the
--- order mirrors `karabiner_menu` in menu_manifest.json; no such key exists, in
--- that file or in the manifest.toml it is generated from, and none ever has.
--- The sequence below — status → gui → start → stop → (warnings) → --- →
--- clear/restore/copy → --- → delays/symmetric/sticky → --- → tap_hold keys →
--- --- → shortcuts — is this file's own, and nothing holds it to anything.
--- Corrected because the reference read as "already migrated" to the next person
--- to open the file, which is the opposite of true: these 36 row sites are the
--- single largest block still built outside the renderer on this driver.
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
	-- KE process status (active / grabber / bridge) is served from a cache and
	-- refreshed in the background — the probes spawn pgrep/CLI subprocesses and
	-- were the dominant menu-open cost. grabber_only distinguishes "remapping not
	-- applied because bridge unprimed" (fixable via click) from "KE not installed /
	-- daemon down". is_priming() stays a live in-memory read (no subprocess).
	local ke_status    = get_ke_status(update_menu)
	local active       = ke_status.active
	local grabber_only = ke_status.grabber
	local bridge_live  = ke_status.bridge
	local priming      = KeLifecycle.is_priming() and not bridge_live
	local tap_hold, raccourcis = build_picker_trees(karabiner, update_menu, enabled)

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

	local status_rows = {}

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

	status_rows[#status_rows + 1] = {
		label = status_title,
		action    = status_fn,
	}
	status_rows[#status_rows + 1] = {
		label = i18n.get("menu.karabiner.open_gui"),
		action    = function() karabiner.open_gui() end,
	}
	status_rows[#status_rows + 1] = {
		label    = i18n.get("menu.karabiner.start"),
		-- Force a fresh prime even if the session marker already exists.
		-- Useful when the daemon was killed manually or by macOS.
		disabled = bridge_live,
		action       = function()
			Logger.start(LOG, "User requested KE bridge start…")
			KeLifecycle.prime_ke_for_session(function(ok)
				Logger.info(LOG, "Manual start: ok=%s.", tostring(ok))
				if update_menu then hs.timer.doAfter(0.5, update_menu) end
			end, true)
		end,
	}
	status_rows[#status_rows + 1] = {
		label    = i18n.get("menu.karabiner.stop"),
		-- Grayed when bridge is not running — nothing to stop.
		disabled = not bridge_live,
		action       = function()
			Logger.start(LOG, "User requested KE bridge stop…")
			local ok_l, kl = pcall(require, "platform.remap.ke_lifecycle")
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
		status_rows[#status_rows + 1] = {
			label    = i18n.get("menu.karabiner.disabled_warning_1"),
			disabled = true,
		}
		status_rows[#status_rows + 1] = {
			label    = i18n.get("menu.karabiner.disabled_warning_2"),
			disabled = true,
		}
		status_rows[#status_rows + 1] = {
			label    = i18n.get("menu.karabiner.disabled_warning_3"),
			disabled = true,
		}
		status_rows[#status_rows + 1] = {
			label    = i18n.get("menu.karabiner.disabled_warning_4"),
			disabled = true,
		}
	end


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
			karabiner.set_enabled(not karabiner.get_enabled())
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
	-- Warm the KE process-status cache too (the pgrep/CLI probes were the dominant
	-- open cost); the cold read happens here, off the menu-open path.
	pcall(get_ke_status, ctx and ctx.updateMenu)
end

-- Perf / cache test seams.
M._picker_fingerprint  = picker_fingerprint
M._build_picker_trees  = build_picker_trees
M._reset_picker_cache  = function() _picker_cache = nil end

return M
