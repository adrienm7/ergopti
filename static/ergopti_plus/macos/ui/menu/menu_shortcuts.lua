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
local hs = hs
local Logger        = require("infra.logger")
local fs_dir       = require("infra.fs_dir")
local dialog        = require("infra.dialog_util")
local shortcuts_mod = require("modules.shortcuts")
local text_acts     = require("modules.shortcuts.actions.text")
local i18n          = require("infra.i18n")
local ManifestMenu  = require("infra.manifest_menu")
local ShortcutUtils = require("ui.menu.shortcut_utils")
local LOG           = "menu_shortcuts"





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
--- @param id string The shortcut identifier (e.g. "ctrl_a", "layer_scroll").
--- @param state table The current state table (used for trigger_char substitution).
--- @return string Display label for the trigger key(s).
local function pretty_key(id, state)
	if id == "at_hash" then return i18n.get("menu.shortcuts.key_at_hash") end
	if id == "layer_scroll" or id == "layer+scroll" then return i18n.get("menu.shortcuts.key_layer_scroll") end
	if id == "wrap_text_if_selected" then return i18n.get("menu.shortcuts.altgr_symbol") end

	local parts = {}
	for p in id:gmatch("[^_]+") do table.insert(parts, p) end
	if #parts == 0 then return id end

	local key = parts[#parts]
	if key == "star" or key == "asterisk" then key = (state and state.trigger_char) or "★" end
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

--- Builds a toggle menu item for a named shortcut.
--- @param s table Shortcut descriptor {id, label, enabled}.
--- @param shortcuts table The shortcuts module reference.
--- @param ctx table The menu context.
--- @return table hs.menubar-compatible item table.
local function make_shortcut_item(s, shortcuts, ctx)
	local state  = ctx.state
	local paused = ctx.paused
	local is_on  = type(shortcuts.is_enabled) == "function" and shortcuts.is_enabled(s.id) or s.enabled
	local desc   = ctx.applyTriggerChar((s.label or ""):gsub("^%s*(.-)%s*$", "%1"))
	local pk     = pretty_key(s.id, state)
	return {
		title    = pk .. (desc ~= "" and (" : " .. desc) or ""),
		checked  = is_on or nil,
		disabled = not state.shortcuts or paused or nil,
		fn       = (state.shortcuts and not paused) and (function(id)
			return function()
				local on = type(shortcuts.is_enabled) == "function" and shortcuts.is_enabled(id) or false
				if on then
					if type(shortcuts.disable) == "function" then pcall(shortcuts.disable, id) end
				else
					if type(shortcuts.enable) == "function" then pcall(shortcuts.enable, id) end
				end
				ctx.save_prefs()
				ctx.notify_feature(pretty_key(id, state), not on)
				ctx.updateMenu()
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
		title    = i18n.get("menu.shortcuts.wrap_symbols_check_all"),
		disabled = paused or nil,
		fn       = not paused and function()
			for _, pair in ipairs(_BUILTIN_SYMBOLS) do sym_states[pair.left] = true end
			state.wrap_symbol_states = sym_states
			ctx.save_prefs(); ctx.updateMenu()
		end or nil,
	}
	sub[#sub + 1] = {
		title    = i18n.get("menu.shortcuts.wrap_symbols_uncheck_all"),
		disabled = paused or nil,
		fn       = not paused and function()
			for _, pair in ipairs(_BUILTIN_SYMBOLS) do sym_states[pair.left] = false end
			state.wrap_symbol_states = sym_states
			ctx.save_prefs(); ctx.updateMenu()
		end or nil,
	}
	sub[#sub + 1] = {
		title    = i18n.get("menu.global.reset_defaults"),
		disabled = paused or nil,
		fn       = not paused and function()
			state.wrap_symbol_states  = {}
			state.custom_wrap_symbols = {}
			ctx.save_prefs(); ctx.updateMenu()
		end or nil,
	}
	sub[#sub + 1] = { title = "-" }

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
			title    = i18n.get("menu.shortcuts.wrap_symbols_check_all"),
			disabled = paused or nil,
			fn       = not paused and (function(lefts)
				return function()
					state.wrap_symbol_states = state.wrap_symbol_states or {}
					for _, k in ipairs(lefts) do state.wrap_symbol_states[k] = true end
					ctx.save_prefs(); ctx.updateMenu()
				end
			end)(group_lefts) or nil,
		}
		group_items[#group_items + 1] = {
			title    = i18n.get("menu.shortcuts.wrap_symbols_uncheck_all"),
			disabled = paused or nil,
			fn       = not paused and (function(lefts)
				return function()
					state.wrap_symbol_states = state.wrap_symbol_states or {}
					for _, k in ipairs(lefts) do state.wrap_symbol_states[k] = false end
					ctx.save_prefs(); ctx.updateMenu()
				end
			end)(group_lefts) or nil,
		}
		group_items[#group_items + 1] = { title = "-" }

		-- One toggle per opening symbol in the group
		for _, pair in ipairs(group_pairs) do
			local enabled = (sym_states[pair.left] ~= false)
			local lbl = (pair.left == pair.right)
					and pair.left
					or  (pair.left .. " … " .. pair.right)
			group_items[#group_items + 1] = {
				title    = lbl,
				checked  = enabled or nil,
				disabled = paused or nil,
				fn       = not paused and (function(k)
					return function()
						state.wrap_symbol_states      = state.wrap_symbol_states or {}
						state.wrap_symbol_states[k]   = not (state.wrap_symbol_states[k] ~= false)
						ctx.save_prefs(); ctx.updateMenu()
					end
				end)(pair.left) or nil,
			}
		end

		local group_title = (type(group.i18n) == "string" and group.i18n ~= "")
				and i18n.get(group.i18n)
				or i18n.get("menu.shortcuts.wrap_symbols_title")
		-- Check the parent group item when all of its symbols are enabled.
		sub[#sub + 1] = {
			title   = group_title,
			menu    = group_items,
			checked = group_all_on or nil,
		}
	end

	-- Custom symbols — individual entries with a delete submenu
	if #custom_syms > 0 then
		sub[#sub + 1] = { title = "-" }
		for idx, cs in ipairs(custom_syms) do
			if type(cs) == "table" and type(cs.left) == "string" and cs.left ~= "" then
				local right   = (type(cs.right) == "string" and cs.right ~= "") and cs.right or cs.left
				local cs_lbl  = (cs.left == right) and cs.left or (cs.left .. " … " .. right)
				cs_lbl = cs_lbl .. " : " .. i18n.get("menu.shortcuts.wrap_symbols_custom_label")
				local del_sub = {
					{
						title = i18n.get("button.delete"),
						fn    = (function(i) return function()
							table.remove(state.custom_wrap_symbols, i)
							ctx.save_prefs(); ctx.updateMenu()
						end end)(idx),
					},
				}
				sub[#sub + 1] = { title = cs_lbl, menu = del_sub }
			end
		end
	end

	-- Add custom symbol button
	sub[#sub + 1] = { title = "-" }
	sub[#sub + 1] = {
		title    = i18n.get("menu.shortcuts.wrap_symbols_add_custom"),
		disabled = paused or nil,
		fn       = not paused and function()
			-- 1. Ask for opening symbol
			local left_char
			while true do
				local ok_p, btn, raw = pcall(dialog.text_prompt,
					i18n.get("dialog.shortcuts.wrap_symbol_title"),
					i18n.get("dialog.shortcuts.wrap_symbol_prompt"),
					"", i18n.get("button.ok"), i18n.get("button.cancel")
				)
				if not ok_p or btn ~= i18n.get("button.ok") or type(raw) ~= "string" then return end
				local first = raw:match("^([%z\1-\127\194-\244][\128-\191]*)")
				if first and first == raw and first ~= "" then left_char = first; break end
				dialog.block_alert(
					i18n.get("dialog.shortcuts.wrap_symbol_title"),
					i18n.get("dialog.shortcuts.wrap_symbol_invalid"),
					i18n.get("button.retry")
				)
			end
			-- 2. Ask for closing symbol (optional — empty = symmetric)
			local right_char
			local ok_r, btn_r, raw_r = pcall(dialog.text_prompt,
				i18n.get("dialog.shortcuts.wrap_symbol_close_title"),
				i18n.get("dialog.shortcuts.wrap_symbol_close_prompt"),
				"", i18n.get("button.ok"), i18n.get("button.cancel")
			)
			if not ok_r or btn_r ~= i18n.get("button.ok") then return end
			if type(raw_r) == "string" and raw_r ~= "" then
				local first_r = raw_r:match("^([%z\1-\127\194-\244][\128-\191]*)")
				right_char = (first_r and first_r == raw_r) and first_r or left_char
			else
				right_char = left_char
			end
			-- 3. Persist
			if type(state.custom_wrap_symbols) ~= "table" then state.custom_wrap_symbols = {} end
			table.insert(state.custom_wrap_symbols, { left = left_char, right = right_char })
			ctx.save_prefs(); ctx.updateMenu()
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

	local item = {
		title   = i18n.get("menu.shortcuts.title"),
		checked = state.shortcuts or nil,
		-- Pause owns the bindings axis until resume: pause_all() snapshots
		-- is_bindings_started() and resume_all() restores from that snapshot, so a
		-- toggle made mid-pause is silently discarded at resume — and enabling would
		-- bind every hotkey while « tout est éteint ». Gate it like the wrap-symbols
		-- submenu above, which is pause-gated for exactly this reason. `checked` is
		-- deliberately left alone: it must keep reporting the stored preference.
		disabled = paused or nil,
		fn       = (not paused) and function()
			state.shortcuts = not state.shortcuts
			-- Toggle ONLY the user-facing bindings + keyboard shortcuts. We must NOT
			-- call shortcuts.start/stop here: stop() also tears down the script-control
			-- eventtap (AltGr+Enter/Backspace/Escape pause/reload/quit) and start() is a
			-- Bindings-only proxy that never revives it, so the feature toggle would
			-- permanently kill the panic shortcuts. resume_bindings/pause_bindings are
			-- the symmetric pair that leave the script-control tap untouched.
			if state.shortcuts then
				if type(shortcuts.resume_bindings) == "function" then pcall(shortcuts.resume_bindings) end
			else
				if type(shortcuts.pause_bindings) == "function" then pcall(shortcuts.pause_bindings) end
			end
			ctx.save_prefs()
			ctx.notify_feature(i18n.get("menu.shortcuts.title"), state.shortcuts)
			ctx.updateMenu()
		end,
	}


	-- ==============================================
	-- ===== 2.1) Shortcut Item Factory Helpers =====
	-- ==============================================

	-- Build shortcut item buckets by iterating the shortcuts module list once.
	local TOP_ORDER = { "at_hash", "layer_scroll" }
	local top_map   = {}
	local wrap_item = nil
	local ctrl_items = {}
	local cmd_items  = {}

	if type(shortcuts.list_shortcuts) == "function" then
		local ok, list = pcall(shortcuts.list_shortcuts)
		if ok and type(list) == "table" then
			for _, s in ipairs(list) do
				if type(s) == "table" and s.id then
					local mi = make_shortcut_item(s, shortcuts, ctx)
					if s.id == "at_hash" or s.id == "layer_scroll" then
						top_map[s.id] = mi
					elseif s.id == "wrap_text_if_selected" then
						wrap_item = mi
					elseif s.id:sub(1, 5) == "ctrl_" then
						table.insert(ctrl_items, mi)
						-- Inject ChatGPT URL editor inline below ctrl_g
						if s.id == "ctrl_g" then
							table.insert(ctrl_items, {
								title    = i18n.get("menu.shortcuts.chatgpt_url_item"),
								disabled = paused or nil,
								fn       = not paused and function()
									local ok_p, clicked, url = pcall(dialog.text_prompt,
										i18n.get("dialog.shortcuts.chatgpt_title"),
										i18n.get("dialog.shortcuts.chatgpt_prompt"),
										state.chatgpt_url, i18n.get("button.ok"), i18n.get("button.cancel"))
									if ok_p and clicked == i18n.get("button.ok") and type(url) == "string" and url ~= "" then
										state.chatgpt_url = url
										if type(shortcuts.set_chatgpt_url) == "function" then
											pcall(shortcuts.set_chatgpt_url, url)
										end
										ctx.save_prefs()
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

	-- group_builders return { menu = items } (or nil to skip) — the manifest
	-- renderer wraps them with the i18n label from the manifest entry.
	local function build_ctrl_shortcuts(_ctx)
		if #ctrl_items == 0 then return nil end
		return { disabled = not state.shortcuts or paused or nil, menu = ctrl_items }
	end

	local function build_cmd_shortcuts(_ctx)
		if #cmd_items == 0 then return nil end
		return { disabled = not state.shortcuts or paused or nil, menu = cmd_items }
	end

	local function dyn_script_control(items, _ctx)
		local script_control = ctx.script_control
		if not script_control then return end
		local enabled = state.script_control_enabled
		local actions = type(script_control.ACTIONS) == "table" and script_control.ACTIONS or {}

		local function get_label(act)
			if not act or act == "-" or act == "--" then return "-" end
			if act:match("^#") then return act:sub(2) end
			if ctx.gestures and type(ctx.gestures.get_action_label) == "function" then
				return ctx.gestures.get_action_label(act)
			end
			return act
		end

		local function key_submenu(keyname)
			local current = state.script_control_shortcuts[keyname] or "none"
			local sub = {}
			for _, act in ipairs(actions) do
				local label = get_label(act)
				if label == "-" then
					table.insert(sub, { title = "-" })
				elseif act:match("^#") then
					table.insert(sub, { title = i18n.decorate_section(label), disabled = true })
				else
					table.insert(sub, {
						title    = label,
						checked  = (current == act) or nil,
						disabled = not enabled or paused or nil,
						fn       = (enabled and not paused) and (function(a) return function()
							local function assign()
								state.script_control_shortcuts[keyname] = a
								if type(script_control.set_shortcut_action) == "function" then
									pcall(script_control.set_shortcut_action, keyname, a)
								end
								ctx.save_prefs()
								ctx.updateMenu()
							end

							-- open_url / search_web do nothing without their parameter:
							-- the handler reads get_action_parameter(binding, action) and
							-- silently returns when it is empty. Assigning one without
							-- prompting handed the user a key that looked configured and
							-- did nothing when pressed. Deferred like the gestures menu so
							-- the modal opens after the menu has closed.
							local gestures = ctx.gestures
							local spec = gestures and type(gestures.get_action_parameter_spec) == "function"
								and gestures.get_action_parameter_spec(a) or nil
							if spec then
								-- The parameter store is keyed by (binding, action), and the
								-- binding script_control dispatches under is the PREFIXED key —
								-- it passes "script__backspace", never "backspace". Prompting
								-- under the bare key name wrote the URL to an entry nothing ever
								-- reads, so the handler found an empty parameter and returned
								-- silently: the very inert binding this prompt exists to
								-- prevent, one layer deeper. The prefix is read from the module
								-- that dispatches it rather than re-spelled here, because a
								-- second spelling is exactly what drifted.
								local prefix = script_control.BINDING_PREFIX
								if type(prefix) ~= "string" then
									Logger.error(LOG, "script_control.BINDING_PREFIX missing — refusing to "
										.. "store '%s' under a binding key dispatch will not read.", tostring(a))
									return
								end
								hs.timer.doAfter(0.05, function()
									if ShortcutUtils.prompt_action_parameter(gestures, prefix .. keyname, a, spec) then
										assign()
									end
								end)
								return
							end

							assign()
						end end)(act) or nil,
					})
				end
			end
			return sub
		end

		local cur_return = state.script_control_shortcuts.return_key or "none"
		local cur_back   = state.script_control_shortcuts.backspace  or "none"
		local cur_escape = state.script_control_shortcuts.escape     or "none"

		table.insert(items, {
			title    = i18n.get("menu.shortcuts.script_shortcuts"),
			disabled = not enabled or paused or nil,
			menu     = {
				{
					title    = string.format(i18n.get("menu.shortcuts.right_opt_return"), get_label(cur_return)),
					disabled = not enabled or paused or nil,
					menu     = key_submenu("return_key"),
				},
				{
					title    = string.format(i18n.get("menu.shortcuts.right_opt_back"), get_label(cur_back)),
					disabled = not enabled or paused or nil,
					menu     = key_submenu("backspace"),
				},
				{
					title    = string.format(i18n.get("menu.shortcuts.right_opt_escape"), get_label(cur_escape)),
					disabled = not enabled or paused or nil,
					menu     = key_submenu("escape"),
				},
			},
		})
	end

	local function dyn_extensions_shortcuts(items, _ctx)
		local ext_root = ctx.base_dir and (ctx.base_dir .. "../extensions/")
		-- Same truncation as hotstring_counter: `and pcall() or false` keeps only
		-- the status, so attr was always nil and this branch never ran.
		local ok_attr, attr = false, nil
		if ext_root then ok_attr, attr = pcall(hs.fs.attributes, ext_root) end
		if not (ok_attr and type(attr) == "table" and attr.mode == "directory") then return end

		local ext_ids = {}
		for _, fname in ipairs(fs_dir.entries(ext_root)) do
			if fname ~= "." and fname ~= ".." then
				local ok_a2, a2 = pcall(hs.fs.attributes, ext_root .. fname)
				if ok_a2 and type(a2) == "table" and a2.mode == "directory" then
					table.insert(ext_ids, fname)
				end
			end
		end
		table.sort(ext_ids)

		local ext_menu_items = {}
		for _, ext_id in ipairs(ext_ids) do
			local ext_dir  = ext_root .. ext_id .. "/"
			local menu_lua = ext_dir .. "shortcuts/menu.lua"
			local manifest = ext_dir .. "manifest.toml"
			local ok_ml, aml = pcall(hs.fs.attributes, menu_lua)
			if not (ok_ml and type(aml) == "table" and aml.mode == "file") then goto continue_sc_ext end

			local ext_name = ext_id
			local ok_m, am = pcall(hs.fs.attributes, manifest)
			if ok_m and type(am) == "table" and am.mode == "file" then
				local fh = io.open(manifest, "r")
				if fh then
					for line in fh:lines() do
						local v = line:match('^name%s*=%s*"(.-)"')
						if v then ext_name = v; break end
					end
					fh:close()
				end
			end

			local collected = {}
			local sandbox = {
				add_item = function(it) if type(it) == "table" then table.insert(collected, it) end end,
				t        = function(k) return i18n.get(k) end,
				ext_name = ext_name,
				hs       = hs,
			}
			-- Fall through to the real global environment for standard builtins
			-- (string, math, table, pairs, …) not explicitly listed above.
			setmetatable(sandbox, { __index = _G })
			sandbox._G = sandbox

			local ok_load, chunk_or_err = pcall(loadfile, menu_lua)
			if ok_load and type(chunk_or_err) == "function" then
				setfenv(chunk_or_err, sandbox)
				local ok_run, run_err = pcall(chunk_or_err)
				if not ok_run then
					Logger.warn(LOG, "Extension '%s' menu.lua error: %s.", ext_id, tostring(run_err))
				end
			else
				Logger.warn(LOG, "Could not load '%s': %s.", menu_lua, tostring(chunk_or_err))
			end

			if #collected > 0 then
				table.insert(ext_menu_items, { title = ext_name, menu = collected })
			end
			::continue_sc_ext::
		end

		if #ext_menu_items > 0 then
			table.insert(items, { title = i18n.section("menu.extensions.header"), disabled = true })
			for _, it in ipairs(ext_menu_items) do
				table.insert(items, it)
			end
		end
	end

	local function dyn_edit_shortcuts(items, _ctx)
		table.insert(items, {
			title = i18n.get("menu.global.edit_shortcuts"),
			fn    = function()
				local acts = ctx.actions
				if type(acts) == "table" and type(acts.open_personal_shortcuts) == "function" then
					pcall(acts.open_personal_shortcuts)
				end
			end,
		})
	end

	-- Top-level items (at_hash, layer_scroll) are not in the manifest list yet;
	-- prepend them before the manifest-driven items for backward compatibility.
	local top_items = {}
	for _, id in ipairs(TOP_ORDER) do
		if top_map[id] then table.insert(top_items, top_map[id]) end
	end
	if wrap_item then
		if #top_items > 0 then table.insert(top_items, { title = "-" }) end
		-- Attach the symbols submenu so the user can toggle/add/remove symbols,
		-- and wire the live getter into the eventtap at build time.
		wrap_item.menu = build_wrap_symbols_submenu(ctx, state, paused, shortcuts)
		table.insert(top_items, wrap_item)
	end


	-- =============================================
	-- ===== 2.3) Manifest-Driven Menu Assembly =====
	-- =============================================

	local dyn_handlers = {
		script_control_shortcuts = dyn_script_control,
		extensions_shortcuts    = dyn_extensions_shortcuts,
		edit_shortcuts          = dyn_edit_shortcuts,
	}

	local group_builders = {
		ctrl_shortcuts = build_ctrl_shortcuts,
		cmd_shortcuts  = build_cmd_shortcuts,
	}

	local s_menu = ManifestMenu.build("shortcuts_menu", "Shortcuts", dyn_handlers, group_builders, ctx)

	-- Prepend the top-level feature items before the manifest section
	for i, it in ipairs(top_items) do
		table.insert(s_menu, i, it)
	end
	if #top_items > 0 and #s_menu > #top_items then
		table.insert(s_menu, #top_items + 1, { title = "-" })
	end

	item.menu = s_menu
	return item
end

return M
