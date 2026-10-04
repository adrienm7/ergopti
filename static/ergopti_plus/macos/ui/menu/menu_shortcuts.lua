--- ui/menu/menu_shortcuts.lua

--- ==============================================================================
--- MODULE: Menu Shortcuts
--- DESCRIPTION:
--- Builds the shortcuts sub-menu for the Hammerspoon tray menu.
---
--- FEATURES & RATIONALE:
--- 1. Manifest-Driven: Structure (order, separators, groups) is read from
---    ``_shared/menu_manifest.json`` via ``infra/manifest_menu``.  Dynamic
---    blocks (ctrl group, cmd group, script control, extensions, edit action)
---    are supplied as handlers so platform-specific logic stays in Lua.
--- ==============================================================================

local M = {}
local ParameterLabel = require("action_parameter_label")
local hs = hs
local Logger        = require("infra.logger")
local DeferredWork  = require("infra.deferred_work")
local dialog        = require("infra.dialog_util")
local shortcuts_mod = require("modules.shortcuts")
local text_acts     = require("modules.shortcuts.actions.text")
local i18n          = require("infra.i18n")
local MenuUtils     = require("ui.menu.menu_utils")
local ManifestMenu  = require("infra.manifest_menu")
local ShortcutUtils = require("ui.menu.shortcut_utils")
local KeyboardSlots = require("ui.menu.menu_keyboard_slots")
local TapKeysMenu   = require("ui.menu.menu_tap_keys")
local ManifestReader = require("infra.manifest_reader")
local utf8_lib      = (type(utf8) == "table" and type(utf8.len) == "function")
	and utf8 or require("compat.utf8")
local LOG           = "menu_shortcuts"
-- The label of each script chord slot: this driver's AltGr is the right
-- Option key.
local SCRIPT_CHORD_LABELS = {
	script_altgr_enter     = "sg_labels.script_ropt_return",
	script_altgr_backspace = "sg_labels.script_ropt_backspace",
	script_altgr_delete    = "sg_labels.script_ropt_delete",
	script_altgr_escape    = "sg_labels.script_ropt_escape",
}
local SHORTCUT_TOGGLE_CLAIM = "feature_toggle"
local shortcut_toggle_debt = nil
local shortcut_row_debt = {}

--- Reports whether previous menu mutations have no retained inverse.
--- @return boolean idle
function M.scope_idle()
	return shortcut_toggle_debt == nil and next(shortcut_row_debt) == nil
end





-- ================================
-- ================================
-- ======= 1/ Default State =======
-- ================================
-- ================================

M.DEFAULT_STATE = {
	chatgpt_url          = shortcuts_mod.DEFAULT_STATE.chatgpt_url,
	shortcuts            = shortcuts_mod.DEFAULT_STATE.shortcuts,
	-- symbol_states: map from opening symbol → boolean (nil / true = enabled, false = disabled).
	-- custom_wrap_symbols: array of {left, right} pairs added by the user.
	wrap_symbol_states   = {},
	custom_wrap_symbols  = {},
}





-- ====================================
-- ====================================
-- ======= 2/ Menu Construction =======
-- ====================================
-- ====================================

--- Translates a shortcut identifier into a human-readable trigger label.
--- @param id string The shortcut identifier (e.g. "ctrl_a", "wrap_text_if_selected").
--- @param state table The current state table (used for trigger_char substitution).
--- @return string Display label for the trigger key(s).
local function pretty_key(id, state)
	-- Any symbol the layout types wraps the selection, AltGr or not: Ergopti puts
	-- them on AltGr, other layouts elsewhere, so the trigger names no key.
	if id == "wrap_text_if_selected" then return i18n.get("menu.shortcuts.selection_symbol") end

	local parts = {}
	for p in id:gmatch("[^_]+") do table.insert(parts, p) end
	if #parts == 0 then return id end

	local key = parts[#parts]
	if key == "star" or key == "asterisk" then key = (state and state.trigger_char) or ManifestReader.default_for("hotstrings.trigger_char") end
	if key == "period"   then key = "." end
	if key == "quote"    then key = "'" end
	if key == "capslock" then key = "CapsLock" end

	local mods = {}
	for i = 1, #parts - 1 do
		local p   = parts[i]
		local lbl = ({ ctrl = "Ctrl", cmd = "Cmd", alt = "Alt", option = "Alt", shift = "Shift" })[p]
		table.insert(mods, lbl or (p:sub(1, 1):upper() .. p:sub(2)))
	end
	return (#mods > 0 and table.concat(mods, " + ") .. " + " or "") .. key:upper()
end

--- Returns a candidate only when it is one exact Unicode scalar.
--- @param value any User-provided symbol candidate.
--- @return string|nil scalar
local function exact_unicode_scalar(value)
	if type(value) ~= "string" or value == "" then return nil end
	local ok, length = pcall(utf8_lib.len, value)
	if not ok or length ~= 1 then return nil end
	return value
end

--- Reads one shortcut's current preference without trusting the menu snapshot.
--- `is_enabled` is the preference, not the native binding, so a row toggle
--- flips what the user chose even while the layer holds no hotkey.
--- @param shortcuts table Shortcut lifecycle owner.
--- @param id string Shortcut identifier.
--- @param fallback boolean|nil Descriptor posture for legacy providers.
--- @return boolean|nil enabled
local function read_shortcut_posture(shortcuts, id, fallback)
	if type(shortcuts.is_enabled) ~= "function" then
		return type(fallback) == "boolean" and fallback or nil
	end
	local ok, enabled = xpcall(shortcuts.is_enabled, debug.traceback, id)
	if ok and type(enabled) == "boolean" then return enabled end
	Logger.error(LOG, "Shortcut '%s' posture could not be read: %s.",
		tostring(id), tostring(enabled))
	return nil
end

--- Applies one per-shortcut lifecycle edge under the exact-true contract.
--- @param shortcuts table Shortcut lifecycle owner.
--- @param id string Shortcut identifier.
--- @param enabled boolean Desired posture.
--- @param phase string Diagnostic phase.
--- @return boolean committed
local function apply_shortcut_row_posture(shortcuts, id, enabled, phase)
	local lifecycle = enabled and shortcuts.enable or shortcuts.disable
	if type(lifecycle) ~= "function" then
		Logger.error(LOG, "Shortcut '%s' %s refused because its lifecycle is unavailable.",
			tostring(id), tostring(phase))
		return false
	end
	local ok, result = xpcall(lifecycle, debug.traceback, id)
	if ok and result == true then return true end
	Logger.error(LOG, "Shortcut '%s' %s did not commit: %s.",
		tostring(id), tostring(phase), tostring(result))
	return false
end

--- Retries an exact rollback debt before allowing a new row mutation.
--- @param shortcuts table Shortcut lifecycle owner.
--- @param id string Shortcut identifier.
--- @return boolean settled
local function settle_shortcut_row_debt(shortcuts, id)
	local debt = shortcut_row_debt[id]
	if not debt then return true end
	if apply_shortcut_row_posture(shortcuts, id, debt.enabled, "rollback retry") ~= true then
		return false
	end
	if shortcut_row_debt[id] == debt then shortcut_row_debt[id] = nil end
	return true
end

--- Restores the previously committed posture after an ambiguous refusal.
--- @param shortcuts table Shortcut lifecycle owner.
--- @param id string Shortcut identifier.
--- @param enabled boolean Previously committed posture.
--- @return boolean restored
local function rollback_shortcut_row(shortcuts, id, enabled)
	if apply_shortcut_row_posture(shortcuts, id, enabled, "rollback") == true then
		return true
	end
	shortcut_row_debt[id] = { enabled = enabled }
	return false
end

--- Builds a toggle menu item for a named shortcut.
--- @param s table Shortcut descriptor {id, label, enabled, bound}.
--- @param shortcuts table The shortcuts module reference.
--- @param ctx table The menu context.
--- @return table hs.menubar-compatible item table.
local function make_shortcut_item(s, shortcuts, ctx)
	local state  = ctx.state
	local paused = ctx.paused
	-- The checkmark is the preference: with the layer off or paused no hotkey is
	-- bound, and a binding-based mark hid which shortcuts will come back.
	local is_on  = s.enabled == true
	local desc   = ctx.applyTriggerChar((s.label or ""):gsub("^%s*(.-)%s*$", "%1"))
	local pk     = pretty_key(s.id, state)
	-- The wrap row reads as its behaviour alone, « Taper un symbole encadre la
	-- sélection », as on Windows and Linux: its trigger is any typed symbol, so
	-- a trigger prefix only repeated it (the maintainer's wording, 2026-09-30).
	if s.id == "wrap_text_if_selected" and desc ~= "" then pk, desc = desc, "" end
	-- Provider data since 2026-08-07: the shared renderer's `group` branch
	-- materialises `items` the same way a `list` row's provider rows are, so a
	-- group builder no longer has to assemble the driver's own tree.
	return {
		label    = pk .. (desc ~= "" and (" : " .. desc) or ""),
		checked  = is_on or nil,
		disabled = not state.shortcuts or paused or nil,
		action   = (state.shortcuts and not paused) and (function(id)
			return function()
				if settle_shortcut_row_debt(shortcuts, id) ~= true then return false end
				local previous = read_shortcut_posture(shortcuts, id, s.enabled)
				if previous == nil then return false end
				local desired = not previous
				if apply_shortcut_row_posture(shortcuts, id, desired, "toggle") ~= true then
					rollback_shortcut_row(shortcuts, id, previous)
					return false
				end
				local save_ok, save_result = xpcall(ctx.save_prefs, debug.traceback)
				if not save_ok or save_result ~= true then
					rollback_shortcut_row(shortcuts, id, previous)
					Logger.error(LOG, "Shortcut '%s' preference publication did not commit: %s.",
						tostring(id), tostring(save_result))
					return false
				end
				ctx.notify_feature(pretty_key(id, state), desired)
				ctx.updateMenu()
				return true
			end
		end)(s.id) or nil,
	}
end

-- Flattened, order-preserving list of unique opening symbols, derived from the
-- shared catalogue's groups (text_acts.WRAP_GROUPS). Used by the bulk check/
-- uncheck-all actions; the per-symbol menu rows iterate the groups directly so
-- the shared grouping and order are mirrored without being hardcoded here.
local _BUILTIN_SYMBOLS = (function()
	local seen, out = {}, {}
	for _, group in ipairs(text_acts.WRAP_GROUPS or {}) do
		for _, pair in ipairs(group.pairs or {}) do
			if not seen[pair.left] then
				seen[pair.left] = true
				table.insert(out, pair)
			end
		end
	end
	return out
end)()

--- Builds the "Symboles encadrant la sélection" submenu and wires the live getter.
--- @param ctx table Menu context.
--- @param state table Mutable state table (uses state.wrap_symbol_states, state.custom_wrap_symbols).
--- @param paused boolean Whether the script is currently paused.
--- @param shortcuts table The shortcuts module (for set_wrap_pairs_getter).
--- @return table hs.menubar submenu items list.
local function build_wrap_symbols_submenu(ctx, state, paused, shortcuts)
	local sym_states   = type(state.wrap_symbol_states)  == "table" and state.wrap_symbol_states  or {}
	local custom_syms  = type(state.custom_wrap_symbols) == "table" and state.custom_wrap_symbols or {}

	-- Wire the live getter so the eventtap always reflects current state
	if type(shortcuts.set_wrap_pairs_getter) == "function" then
		pcall(shortcuts.set_wrap_pairs_getter, function()
			return text_acts.build_active_wrap_pairs(
				state.wrap_symbol_states  or {},
				state.custom_wrap_symbols or {}
			)
		end)
	end

	local sub = {}

	-- Bulk actions
	sub[#sub + 1] = {
		label    = i18n.get("menu.shortcuts.wrap_symbols_check_all"),
		disabled = paused or nil,
		action       = not paused and function()
			for _, pair in ipairs(_BUILTIN_SYMBOLS) do sym_states[pair.left] = true end
			state.wrap_symbol_states = sym_states
			if ctx.save_prefs() ~= true then return false end
			ctx.updateMenu()
		end or nil,
	}
	sub[#sub + 1] = {
		label    = i18n.get("menu.shortcuts.wrap_symbols_uncheck_all"),
		disabled = paused or nil,
		action       = not paused and function()
			for _, pair in ipairs(_BUILTIN_SYMBOLS) do sym_states[pair.left] = false end
			state.wrap_symbol_states = sym_states
			if ctx.save_prefs() ~= true then return false end
			ctx.updateMenu()
		end or nil,
	}
	sub[#sub + 1] = {
		label    = i18n.get("common.restore_recommended"),
		disabled = paused or nil,
		action       = not paused and function()
			state.wrap_symbol_states  = {}
			state.custom_wrap_symbols = {}
			if ctx.save_prefs() ~= true then return false end
			ctx.updateMenu()
		end or nil,
	}
	sub[#sub + 1] = { separator = true }

	-- Built-in symbols — each shared-catalogue group becomes its own named nested
	-- sub-submenu so the top-level list stays short. Every group sub-submenu also
	-- carries its own « check all / uncheck all » so a whole family can be flipped
	-- at once. Order, grouping and labels all come from the shared catalogue.
	for _, group in ipairs(text_acts.WRAP_GROUPS or {}) do
		local group_pairs = group.pairs or {}
		local group_lefts = {}
		local group_all_on = true
		for _, pair in ipairs(group_pairs) do
			group_lefts[#group_lefts + 1] = pair.left
			if sym_states[pair.left] == false then group_all_on = false end
		end

		local group_items = {}
		-- Per-group bulk actions
		group_items[#group_items + 1] = {
			label    = i18n.get("menu.shortcuts.wrap_symbols_check_all"),
			disabled = paused or nil,
			action       = not paused and (function(lefts)
				return function()
					state.wrap_symbol_states = state.wrap_symbol_states or {}
					for _, k in ipairs(lefts) do state.wrap_symbol_states[k] = true end
					if ctx.save_prefs() ~= true then return false end
					ctx.updateMenu()
				end
			end)(group_lefts) or nil,
		}
		group_items[#group_items + 1] = {
			label    = i18n.get("menu.shortcuts.wrap_symbols_uncheck_all"),
			disabled = paused or nil,
			action       = not paused and (function(lefts)
				return function()
					state.wrap_symbol_states = state.wrap_symbol_states or {}
					for _, k in ipairs(lefts) do state.wrap_symbol_states[k] = false end
					if ctx.save_prefs() ~= true then return false end
					ctx.updateMenu()
				end
			end)(group_lefts) or nil,
		}
		group_items[#group_items + 1] = { separator = true }

		-- One toggle per opening symbol in the group
		for _, pair in ipairs(group_pairs) do
			local enabled = (sym_states[pair.left] ~= false)
			local lbl = (pair.left == pair.right)
					and pair.left
					or  (pair.left .. " … " .. pair.right)
			group_items[#group_items + 1] = {
				label    = lbl,
				checked  = enabled or nil,
				disabled = paused or nil,
				action       = not paused and (function(k)
					return function()
						state.wrap_symbol_states      = state.wrap_symbol_states or {}
						state.wrap_symbol_states[k]   = not (state.wrap_symbol_states[k] ~= false)
						if ctx.save_prefs() ~= true then return false end
						ctx.updateMenu()
					end
				end)(pair.left) or nil,
			}
		end

		local group_title = (type(group.i18n) == "string" and group.i18n ~= "")
				and i18n.get(group.i18n)
				or i18n.get("menu.shortcuts.wrap_symbols_title")
		-- Check the parent group item when all of its symbols are enabled.
		-- `items`: the renderer never reads `menu` on a provider row, so the
		-- group used to open empty.
		sub[#sub + 1] = {
			label   = group_title,
			items   = group_items,
			checked = group_all_on or nil,
		}
	end

	-- Custom symbols — individual entries with a delete submenu
	if #custom_syms > 0 then
		sub[#sub + 1] = { separator = true }
		for idx, cs in ipairs(custom_syms) do
			if type(cs) == "table" and type(cs.left) == "string" and cs.left ~= "" then
				local right   = (type(cs.right) == "string" and cs.right ~= "") and cs.right or cs.left
				local cs_lbl  = (cs.left == right) and cs.left or (cs.left .. " … " .. right)
				cs_lbl = cs_lbl .. " : " .. i18n.get("menu.shortcuts.wrap_symbols_custom_label")
				local del_sub = {
					{
						label = i18n.get("button.delete"),
						action    = (function(i) return function()
							table.remove(state.custom_wrap_symbols, i)
							if ctx.save_prefs() ~= true then return false end
							ctx.updateMenu()
						end end)(idx),
					},
				}
				sub[#sub + 1] = { label = cs_lbl, menu = del_sub }
			end
		end
	end

	-- Add custom symbol button
	sub[#sub + 1] = { separator = true }
	sub[#sub + 1] = {
		label    = i18n.get("menu.shortcuts.wrap_symbols_add_custom"),
		disabled = paused or nil,
		action       = not paused and function()
			-- 1. Ask for opening symbol
			local left_char
			while true do
				local ok_p, btn, raw = pcall(dialog.text_prompt,
					i18n.get("dialog.shortcuts.wrap_symbol_title"),
					i18n.get("dialog.shortcuts.wrap_symbol_prompt"),
					"", i18n.get("button.ok"), i18n.get("button.cancel")
				)
				if not ok_p or btn ~= i18n.get("button.ok") or type(raw) ~= "string" then return end
				local scalar = exact_unicode_scalar(raw)
				if scalar then left_char = scalar; break end
				dialog.block_alert(
					i18n.get("dialog.shortcuts.wrap_symbol_title"),
					i18n.get("dialog.shortcuts.wrap_symbol_invalid"),
					i18n.get("button.retry")
				)
			end
			-- 2. Ask for closing symbol (optional — empty = symmetric)
			local right_char
			while true do
				local ok_r, btn_r, raw_r = pcall(dialog.text_prompt,
					i18n.get("dialog.shortcuts.wrap_symbol_close_title"),
					i18n.get("dialog.shortcuts.wrap_symbol_close_prompt"),
					"", i18n.get("button.ok"), i18n.get("button.cancel")
				)
				if not ok_r or btn_r ~= i18n.get("button.ok") then return end
				if raw_r == "" then right_char = left_char; break end
				local scalar = exact_unicode_scalar(raw_r)
				if scalar then right_char = scalar; break end
				dialog.block_alert(
					i18n.get("dialog.shortcuts.wrap_symbol_close_title"),
					i18n.get("dialog.shortcuts.wrap_symbol_invalid"),
					i18n.get("button.retry")
				)
			end
			-- 3. Persist
			if type(state.custom_wrap_symbols) ~= "table" then state.custom_wrap_symbols = {} end
			table.insert(state.custom_wrap_symbols, { left = left_char, right = right_char })
			if ctx.save_prefs() ~= true then return false end
			ctx.updateMenu()
			return true
		end or nil,
	}

	return sub
end

--- Builds the shortcuts sub-menu.
--- @param ctx table Context.
--- @return table|nil
function M.build(ctx)
	local shortcuts = ctx.shortcuts
	if not shortcuts then return nil end

	local state  = ctx.state
	local paused = ctx.paused

	--- Applies the requested binding posture and restores the old one on refusal.
	--- @param enabled boolean Desired binding state.
	--- @param previous boolean Previously committed binding state.
	--- @return boolean committed True only after exact runtime commitment.
	local function apply_shortcut_posture(enabled, label)
		local lifecycle = enabled and shortcuts.resume_bindings or shortcuts.pause_bindings
		if type(lifecycle) ~= "function" then
			Logger.error(LOG, "Shortcuts toggle refused because its lifecycle contract is incomplete.")
			return false
		end
		local apply_ok, result_or_err = xpcall(
			lifecycle, debug.traceback, SHORTCUT_TOGGLE_CLAIM)
		if apply_ok and result_or_err == true then return true end
		Logger.error(LOG, "Shortcuts runtime %s did not commit: %s.",
			tostring(label), tostring(result_or_err))
		return false
	end

	local function commit_shortcuts_runtime(enabled, previous)
		if apply_shortcut_posture(enabled, "toggle") == true then return true end
		if apply_shortcut_posture(previous, "rollback") ~= true then
			shortcut_toggle_debt = { restore_enabled = previous }
		end
		return false
	end

	local function settle_shortcut_toggle_debt()
		local debt = shortcut_toggle_debt
		if not debt then return true end
		if apply_shortcut_posture(debt.restore_enabled, "rollback retry") ~= true then
			return false
		end
		if shortcut_toggle_debt == debt then shortcut_toggle_debt = nil end
		return true
	end

	--- The category switch: the shortcuts submenu's first row (the manifest's
	--- shortcuts_toggle). It used to be the parent row's action, which AppKit
	--- never sends for an item that opens a submenu, so Shortcuts could not be
	--- switched on from the menu bar at all.
	---
	--- Refused while the script is paused. Pause owns the bindings axis until
	--- resume: pause_all() snapshots is_bindings_started() and resume_all()
	--- restores from that snapshot, so a toggle made mid-pause is silently
	--- discarded at resume — and enabling would bind every hotkey while « tout est
	--- éteint ».
	--- @return boolean committed
	local function toggle_shortcuts()
		if paused then
			Logger.warn(LOG, "Shortcuts switch refused: the script is paused.")
			return false
		end
		if settle_shortcut_toggle_debt() ~= true then return false end
		local previous = state.shortcuts == true
		local desired = not previous
		-- Toggle ONLY the user-facing bindings + keyboard shortcuts. We must NOT
		-- call shortcuts.start/stop here: stop() also tears down the script-control
		-- eventtap (AltGr+Enter/Backspace/Escape pause/reload/quit) and start() is a
		-- Bindings-only proxy that never revives it, so the feature toggle would
		-- permanently kill the panic shortcuts. resume_bindings/pause_bindings are
		-- the symmetric pair that leave the script-control tap untouched.
		if commit_shortcuts_runtime(desired, previous) ~= true then return false end
		state.shortcuts = desired
		local save_ok, save_result = xpcall(ctx.save_prefs, debug.traceback)
		if not save_ok or save_result ~= true then
			state.shortcuts = previous
			if apply_shortcut_posture(previous, "preference rollback") ~= true then
				shortcut_toggle_debt = { restore_enabled = previous }
			end
			Logger.error(LOG, "Shortcut preference publication did not commit: %s.",
				tostring(save_result))
			return false
		end
		ctx.notify_feature(i18n.get("menu.shortcuts.title"), state.shortcuts)
		ctx.updateMenu()
		return true
	end

	-- The parent carries the stored preference as its tick and is greyed while
	-- paused; it has no action, since a row that opens a submenu is never clicked.
	local item = {
		label    = i18n.get("menu.shortcuts.title"),
		checked  = state.shortcuts or nil,
		disabled = paused or nil,
	}


	-- ==============================================
	-- ===== 2.1) Shortcut Item Factory Helpers =====
	-- ==============================================

	-- Build shortcut item buckets by iterating the shortcuts module list once.
	-- The navigation layer's wheel is no shortcut: it is edited with the layer
	-- (Tap-Holds › Edit the layer) and never listed here.
	local wrap_item = nil
	local ctrl_items = {}
	local cmd_items  = {}

	if type(shortcuts.list_shortcuts) == "function" then
		local ok, list = pcall(shortcuts.list_shortcuts)
		if ok and type(list) == "table" then
			for _, s in ipairs(list) do
				if type(s) == "table" and s.id then
					local mi = make_shortcut_item(s, shortcuts, ctx)
					if s.id == "wrap_text_if_selected" then
						wrap_item = mi
					elseif s.id:sub(1, 5) == "ctrl_" then
						table.insert(ctrl_items, mi)
						-- Inject ChatGPT URL editor inline below ctrl_g
						if s.id == "ctrl_g" then
							table.insert(ctrl_items, {
								label    = i18n.get("menu.shortcuts.chatgpt_url_item"),
								disabled = paused or nil,
								action   = not paused and function()
									local ok_p, clicked, url = pcall(dialog.text_prompt,
										i18n.get("dialog.shortcuts.chatgpt_title"),
										i18n.get("dialog.shortcuts.chatgpt_prompt"),
										state.chatgpt_url, i18n.get("button.ok"), i18n.get("button.cancel"))
									if ok_p and clicked == i18n.get("button.ok") and type(url) == "string" and url ~= "" then
										state.chatgpt_url = url
										if type(shortcuts.set_chatgpt_url) == "function" then
											pcall(shortcuts.set_chatgpt_url, url)
										end
										if ctx.save_prefs() ~= true then return false end
										ctx.updateMenu()
									end
								end or nil,
							})
						end
					elseif s.id:sub(1, 4) == "cmd_" then
						table.insert(cmd_items, mi)
					end
				end
			end
		end
	end


	-- =====================================================
	-- ===== 2.2) Dynamic Handlers for Manifest Items =====
	-- =====================================================

	-- Each handler appends its items into the ``items`` list it receives.

	--- « Raccourcis de gestion du script », declared by script_control_group
	--- as on every driver: the chords' switch, the restore of their preset,
	--- the clear to the system's behaviour, then one row per slot. The restore
	--- and the clear apply at once, without a question, through the Shortcuts
	--- scope owner and its backup. The title is ticked from the switch.
	--- @return table|nil rows Rendered rows for the group, nil without the module.
	local function script_control_group()
		local script_control = ctx.script_control
		if type(script_control) ~= "table" or type(script_control.script_chord_slots) ~= "function" then
			Logger.warn(LOG, "Script control absent from the menu context — its submenu is skipped.")
			return nil
		end
		local actions = type(script_control.ACTIONS) == "table" and script_control.ACTIONS or {}
		local prefix = script_control.SCRIPT_BINDING_PREFIX

		local function get_label(act, slot_id)
			if not act or act == "-" or act == "--" then return "-" end
			if act:match("^#") then return act:sub(2) end
			if ctx.gestures and type(ctx.gestures.get_action_label) == "function" then
				local binding = slot_id and act ~= "none" and type(prefix) == "string"
					and type(ctx.gestures.get_action_parameter) == "function"
					and prefix .. slot_id or nil
				return ParameterLabel.for_binding(ctx.gestures.get_action_label(act), ctx.gestures, binding, act)
			end
			return act
		end

		-- Row DATA: the renderer draws all three levels, and this only answers
		-- what the rows are.
		local function slot_submenu_rows(slot_id)
			local current = state.script_control_shortcuts[slot_id] or "none"
			local sub = {}
			for _, act in ipairs(actions) do
				local label = get_label(act, slot_id)
				if label == "-" then
					table.insert(sub, { separator = true })
				elseif act:match("^#") then
					table.insert(sub, { label = i18n.decorate_section(label), disabled = true })
				else
					table.insert(sub, {
						label    = label,
						checked  = (current == act) or nil,
						disabled = paused or nil,
						action   = (not paused) and (function(a) return function()
							local function assign()
								if a == "run_program" then ctx.updateMenu(); return true end
								state.script_control_shortcuts[slot_id] = a
								if type(script_control.set_shortcut_action) == "function" then
									pcall(script_control.set_shortcut_action, slot_id, a)
								end
								if ctx.save_prefs() ~= true then return false end
								ctx.updateMenu()
							end

							-- open_url / search_web do nothing without their parameter:
							-- prompting under the PREFIXED binding dispatch reads
							-- (script__<slot>) keeps the configured key from staying
							-- silently inert. Deferred so the modal opens after the
							-- menu has closed.
							local gestures = ctx.gestures
							local spec = gestures and type(gestures.get_action_parameter_spec) == "function"
								and gestures.get_action_parameter_spec(a) or nil
							if spec then
								if type(prefix) ~= "string" then
									Logger.error(LOG, "The script binding prefix is missing — refusing to "
										.. "store '%s' under a binding key dispatch will not read.", tostring(a))
									return
								end
								DeferredWork.after(0.05, function()
									local mutation = spec == "program" and {
										section = "shortcuts.script_control", key = slot_id,
										read = function()
											if type(script_control.get_shortcut_actions) ~= "function" then return nil end
											local actions = script_control.get_shortcut_actions()
											return type(actions) == "table" and (actions[slot_id] or "none") or nil
										end,
										read_menu = function() return state.script_control_shortcuts[slot_id] or "none" end,
										apply = function()
											if type(script_control.set_shortcut_action) ~= "function"
												or script_control.set_shortcut_action(slot_id, a) ~= true then return false end
											state.script_control_shortcuts[slot_id] = a
											return true
										end,
										restore = function(previous)
											state.script_control_shortcuts[slot_id] = previous
											return script_control.set_shortcut_action(slot_id, previous) == true
										end,
									} or nil
									local transaction = ctx.commit_program_parameter
									if ShortcutUtils.prompt_action_parameter(gestures, prefix .. slot_id, a, spec, nil, mutation, transaction) then
										assign()
									end
								end, "menu_shortcuts.action_parameter")
								return
							end

							assign()
						end end)(act) or nil,
					})
				end
			end
			return sub
		end

		local providers = {
			["script_control_shortcuts"] = function()
				local rows = {}
				for _, slot in ipairs(script_control.script_chord_slots()) do
					local current = state.script_control_shortcuts[slot.id] or "none"
					rows[#rows + 1] = {
						label    = string.format("%s → %s", i18n.get(SCRIPT_CHORD_LABELS[slot.id]),
							get_label(current, slot.id)),
						disabled = paused or nil,
						items    = slot_submenu_rows(slot.id),
					}
				end
				return rows
			end,
		}

		local chords_on = state.script_control_enabled == true
		local render_ctx = {}
		for key, value in pairs(ctx) do render_ctx[key] = value end
		render_ctx.commands = {
			["script_control_toggle"] = function()
				if type(ctx.commit_script_chords) ~= "function"
					or ctx.commit_script_chords() ~= true then return false end
				ctx.updateMenu()
				return true
			end,
			["scope_restore"] = function()
				return type(ctx.apply_script_chords_scope) == "function"
					and ctx.apply_script_chords_scope("recommended") == true
			end,
			["scope_clear"] = function()
				return type(ctx.apply_script_chords_scope) == "function"
					and ctx.apply_script_chords_scope("clear") == true
			end,
		}
		render_ctx.state_getters = {}
		for key, value in pairs(ctx.state_getters or {}) do render_ctx.state_getters[key] = value end
		render_ctx.state_getters["script_control_enabled"] = function() return chords_on end
		return ManifestMenu.build("script_control_group", "Shortcuts", nil, nil, render_ctx, providers)
	end

	-- `list` since 2026-08-07: the separator, the header and one row per
	-- extension are the renderer's now, and only the submenu each extension
	-- declares for itself stays this driver's.
	local function extension_shortcut_rows()
		local items = {}
		local ext_menu_items = {}
		-- The packs this boot discovered — the bundled ones, installed layouts and
		-- the user's folder — so an extension's shortcuts come from the same roots
		-- as its hotstrings, named by the shared manifest reader. A context without
		-- the catalogue is a partial test fixture and lists none.
		local packs = type(ctx.extension_packs) == "table" and ctx.extension_packs or {}
		for _, pack in ipairs(packs) do
			local menu_lua = pack.dir .. "/shortcuts/menu.lua"
			local ok_ml, aml = pcall(hs.fs.attributes, menu_lua)
			if ok_ml and type(aml) == "table" and aml.mode == "file" then
				local collected = {}
				local sandbox = {
					add_item = function(it) if type(it) == "table" then table.insert(collected, it) end end,
					t        = function(k) return i18n.get(k) end,
					ext_name = pack.name,
					hs       = hs,
				}
				-- Fall through to the real global environment for standard builtins
				-- (string, math, table, pairs, …) not explicitly listed above.
				setmetatable(sandbox, { __index = _G })
				sandbox._G = sandbox

				-- Lua 5.4 receives a chunk environment at compile time; setfenv was
				-- removed after Lua 5.1 and cannot safely retrofit this sandbox.
				local ok_load, chunk_or_err = pcall(loadfile, menu_lua, "t", sandbox)
				if ok_load and type(chunk_or_err) == "function" then
					local ok_run, run_err = pcall(chunk_or_err)
					if not ok_run then
						Logger.warn(LOG, "Extension '%s' menu.lua error: %s.", pack.id, tostring(run_err))
					end
				else
					Logger.warn(LOG, "Could not load '%s': %s.", menu_lua, tostring(chunk_or_err))
				end

				if #collected > 0 then
					table.insert(ext_menu_items, { title = pack.name, menu = collected })
				end
			end
		end

		if #ext_menu_items > 0 then
			table.insert(items, { separator = true })
			table.insert(items, { label = i18n.section("menu.extensions.header"), disabled = true })
			for _, it in ipairs(ext_menu_items) do
				table.insert(items, MenuUtils.as_provider_row(it))
			end
		end
		return items
	end

	--- Opens the personal-shortcuts file. The ROW is the manifest's — a `command`
	--- since 2026-08-08, because a static label and a click is exactly what a
	--- declaration carries — so this is only the behaviour behind it.
	local function cmd_edit_shortcuts()
		local acts = ctx.actions
		if type(acts) == "table" and type(acts.open_personal_shortcuts) == "function" then
			pcall(acts.open_personal_shortcuts)
		end
	end

	-- The feature toggle (the wrap-text toggle) opens the submenu. It is row
	-- DATA handed over by the wrap-symbols list provider, which the manifest
	-- places first, so the renderer draws it like every other row: prepended
	-- after rendering, the wrap-text toggle reached the tray with no title and
	-- hs.menubar drew nothing.
	local top_items = {}
	if wrap_item then
		-- The symbols submenu USED to hang off this toggle. It is a manifest row of
		-- its own now (`list:wrap_symbols_menu`), which is where Windows and Linux
		-- have always shown it — the same feature was sitting in two different
		-- places depending on the OS.
		table.insert(top_items, wrap_item)
	end


	-- =============================================
	-- ===== 2.3) Manifest-Driven Menu Assembly =====
	-- =============================================

	local dyn_handlers = {
	}

	-- « Combinaisons de touches »: the Karabiner chords moved here from the
	-- Tap-Holds submenu, with their own first-row switch. The remap menu owns
	-- their rows, as it owns the engine they configure.
	local group_builders = {
		["key_combinations"] = function()
			return require("ui.menu.menu_tap_holds").build_key_combinations(ctx)
		end,
		["script_control"] = script_control_group,
	}

	-- The keyboard slots are a list, not a group: their rows are the user's own
	-- assignments, so the manifest can name the section but not enumerate it. The
	-- provider returns row DATA and the renderer draws it.
	local list_providers = {
		-- Its rows are the user's own symbol pairs, so no static entry can
		-- enumerate them — and the manifest called this Windows-only until
		-- 2026-08-06 while this driver had been building it all along.
		-- The wrap toggle and its symbols form one group, with no line between
		-- them (the maintainer's request of 2026-09-30), as the manifest declares
		-- the same pair for Windows and Linux.
		["wrap_symbols_menu"] = function()
			local rows = {}
			for _, row in ipairs(top_items) do rows[#rows + 1] = row end
			rows[#rows + 1] = { label = i18n.get("menu.shortcuts.wrap_symbols"),
			                    disabled = not state.shortcuts or paused or nil,
			                    items = build_wrap_symbols_submenu(ctx, state, paused, shortcuts) }
			return rows
		end,
		keyboard_slots = function(_ctx)
			-- The built-in Ctrl and Cmd shortcuts open the group of their own
			-- modifier: as groups of their own they drew a second "Ctrl" and
			-- "Cmd" submenu beside the configurable one.
			return KeyboardSlots.provide_rows(ctx, (not state.shortcuts) or paused or nil, {
				hs_ctrl_ = ctrl_items,
				cmd_     = cmd_items,
			})
		end,
		-- The number-row tap keys, named by what each types under the current
		-- input source. Greyed only by a pause: with the category off they stay
		-- editable, so a key can be set up before shortcuts are switched on.
		tap_keys = function(_ctx)
			return TapKeysMenu.provide_rows(ctx, paused or nil)
		end,
		["extensions_shortcuts"] = extension_shortcut_rows,
	}

	-- The category switch is the manifest's first row, drawn by the renderer from
	-- this command and the state getter below. A tray parent cannot carry it:
	-- AppKit never sends the action of an item that opens a submenu.
	local sc_ctx = {}
	for key, value in pairs(ctx) do sc_ctx[key] = value end
	sc_ctx.commands = {}
	for key, value in pairs(ctx.commands or {}) do sc_ctx.commands[key] = value end
	sc_ctx.commands["shortcuts_toggle"] = toggle_shortcuts
	sc_ctx.commands["edit_shortcuts"] = cmd_edit_shortcuts
	sc_ctx.state_getters = {}
	for key, value in pairs(ctx.state_getters or {}) do sc_ctx.state_getters[key] = value end
	sc_ctx.state_getters["shortcuts_enabled"] = function() return state.shortcuts and true or false end
	-- Ticks « Raccourcis de gestion du script » while its switch is on.
	sc_ctx.state_getters["script_control_enabled"] = function() return state.script_control_enabled == true end
	-- Ticks the « Combinaisons de touches » title while its own switch is on.
	sc_ctx.state_getters["key_combinations_enabled"] = function()
		local karabiner = ctx.karabiner
		return type(karabiner) == "table" and type(karabiner.get_mod_combos_enabled) == "function"
			and karabiner.get_mod_combos_enabled() == true
	end

	local s_menu = ManifestMenu.build("shortcuts_menu", "Shortcuts", dyn_handlers, group_builders, sc_ctx, list_providers)

	item.submenu = s_menu
	return item
end

return M
