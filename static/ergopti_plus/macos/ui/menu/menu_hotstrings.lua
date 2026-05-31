--- ui/menu/menu_hotstrings.lua

--- ==============================================================================
--- MODULE: Menu Hotstrings
--- DESCRIPTION:
--- Builds the hotstrings and personal info sub-menus for the tray menu.
--- ==============================================================================

local M = {}
local hs            = hs
local Logger        = require("lib.logger")
local dialog        = require("lib.dialog_util")
local notifications = require("lib.notifications")
local i18n          = require("lib.i18n")
local LOG           = "menu_hotstrings"

--- Resolves a description value that may be a plain string or a multilingual table.
--- Falls back to the "fr" locale, then to an empty string.
--- @param desc string|table|nil The raw description field.
--- @return string The resolved description.
local function resolve_desc(desc)
	if type(desc) == "table" then
		local code = i18n.get_locale()
		return desc[code] or desc["fr"] or ""
	end
	return type(desc) == "string" and desc or ""
end

local dh_mod = require("modules.dynamic_hotstrings")
-- Keymap is already loaded by init.lua before this module is required;
-- require() returns the cached module with no side-effects.
local keymap  = require("modules.keymap")




-- ================================
--- ================================
-- ======= 1/ Default State =======
--- ================================
-- ================================

-- Preview defaults are the canonical values owned by modules/keymap/init.lua.
-- We read them here so there is a single source of truth — never re-declare them.
local KM = keymap.DEFAULT_STATE

M.DEFAULT_STATE = {
	-- Preview toggle defaults — read from keymap, never duplicated here.
	preview_star_enabled          = KM.preview_star_enabled,
	preview_autocorrect_enabled   = KM.preview_autocorrect_enabled,
	preview_ai_enabled            = KM.preview_ai_enabled,
	preview_colored_tooltips      = KM.preview_colored_tooltips,
	-- Editor & UI preferences — owned by this menu module.
	custom_close_on_add           = false,
	custom_default_section        = nil,
	custom_editor_shortcut        = nil,
	sections_order_overrides      = {},
	terminator_states             = {},
	custom_terminators            = {},
	hotstrings                    = {},
	delays                        = {},
	-- Dynamic hotstrings defaults — read from their canonical module.
	personal_info                 = dh_mod.DEFAULT_STATE.personal_info,
	dynamichotstrings_enabled     = dh_mod.DEFAULT_STATE.dynamichotstrings_enabled,
}

local function open_toml_path(path)
	if type(path) ~= "string" or path == "" then return end
	hs.timer.doAfter(0, function()
		pcall(hs.execute, string.format("open %q", path))
	end)
end

local function toml_path_for_group(ctx, group_name)
	local paths = type(ctx.hotfile_paths) == "table" and ctx.hotfile_paths or {}
	local path = paths[group_name]
	return type(path) == "string" and path ~= "" and path or nil
end

local function split_personal_ext_stem(stem)
	local parts = {}
	if type(stem) ~= "string" or stem == "" then return parts end
	for part in (stem .. "__"):gmatch("(.-)__") do
		if part ~= "" then table.insert(parts, part) end
	end
	return parts
end





-- ====================================
--- ====================================
-- ======= 2/ Menu Construction =======
--- ====================================
-- ====================================

--- Formats a number with spaces as thousands separators.
--- @param n number|string The number to format.
--- @return string The formatted number.
local function fmt_count(n)
	local num = tonumber(n) or 0
	local s = tostring(math.floor(num + 0.5))
	local r = ""
	for i = 1, #s do
		if i > 1 and (#s - i + 1) % 3 == 0 then r = r .. " " end
		r = r .. s:sub(i, i)
	end
	return r
end

--- Checks if a hotstring group is enabled.
--- @param ctx table Context.
--- @param name string Group name.
--- @return boolean
local function groupEnabled(ctx, name)
	return (ctx.keymap and type(ctx.keymap.is_group_enabled) == "function" and ctx.keymap.is_group_enabled(name))
		or (ctx.state.hotstrings[name] ~= false)
end

--- Gets the display label for a group.
--- @param ctx table Context.
--- @param name string Group name.
--- @return string
local function groupLabel(ctx, name)
	local meta = ctx.keymap and type(ctx.keymap.get_meta_description) == "function" and ctx.keymap.get_meta_description(name)
	local lbl = (type(meta) == "string" and meta ~= "") and meta or tostring(name):gsub("_", " ")
	return ctx.applyTriggerChar(lbl)
end

--- Generates a function to toggle a hotstring group.
--- @param ctx table Context.
--- @param name string Group name.
--- @return function
local function toggleGroupFn(ctx, name)
	return function()
		ctx.state.hotstrings[name] = not groupEnabled(ctx, name)
		if ctx.state.hotstrings[name] then
			if ctx.keymap and type(ctx.keymap.enable_group) == "function" then pcall(ctx.keymap.enable_group, name) end
			if not ctx.state.keymap then 
				ctx.state.keymap = true
				if ctx.keymap and type(ctx.keymap.start) == "function" then pcall(ctx.keymap.start) end 
			end
		else
			if ctx.keymap and type(ctx.keymap.disable_group) == "function" then pcall(ctx.keymap.disable_group, name) end
		end
		ctx.save_prefs()
		ctx.notify_feature(groupLabel(ctx, name), ctx.state.hotstrings[name])
		ctx.updateMenu()
	end
end

--- Generates a function to toggle a specific section.
--- @param ctx table Context.
--- @param group_name string Group name.
--- @param sec_name string Section name.
--- @param sec_label string Section display label.
--- @return function
local function toggleSectionFn(ctx, group_name, sec_name, sec_label)
	return function()
		local will_enable = not (ctx.keymap and type(ctx.keymap.is_section_enabled) == "function" and ctx.keymap.is_section_enabled(group_name, sec_name) or false)
		if will_enable then
			if ctx.keymap and type(ctx.keymap.enable_section) == "function" then pcall(ctx.keymap.enable_section, group_name, sec_name) end
			if not ctx.state.keymap then 
				ctx.state.keymap = true
				if ctx.keymap and type(ctx.keymap.start) == "function" then pcall(ctx.keymap.start) end 
			end
		else
			if ctx.keymap and type(ctx.keymap.disable_section) == "function" then pcall(ctx.keymap.disable_section, group_name, sec_name) end
		end
		ctx.save_prefs()
		ctx.notify_feature(ctx.applyTriggerChar(sec_label or sec_name), will_enable)
		ctx.updateMenu()
	end
end

--- Builds menu items for personal information.
--- @param ctx table Context.
--- @param description string Description of the item.
--- @return table|nil
local function buildPersonalInfoItems(ctx, description)
	if not ctx.personal_info then return nil end
	description = ctx.applyTriggerChar(description)
	return {
		{
			title   = description,
			checked = ctx.state.personal_info or nil,
			fn      = function()
				ctx.state.personal_info = not ctx.state.personal_info
				if ctx.state.personal_info then 
					if type(ctx.personal_info.enable) == "function" then pcall(ctx.personal_info.enable) end
				else 
					if type(ctx.personal_info.disable) == "function" then pcall(ctx.personal_info.disable) end 
				end
				ctx.save_prefs()
				ctx.notify_feature(description or i18n.get("notify.personal_info"), ctx.state.personal_info)
				ctx.updateMenu()
			end,
		},
		{
			title = i18n.get("menu.hotstrings.edit_personal_info"),
			fn    = function() hs.timer.doAfter(0.1, function() pcall(ctx.personal_info.open_editor) end) end,
		},
	}
end

--- Builds the main hotstring groups menu.
--- @param ctx table Context.
--- @param only table|nil Optional set of group names to include (nil = all common groups).
--- @return table
function M.build_groups(ctx, only)
	local top_names = {}
	for _, f in ipairs(type(ctx.hotfiles) == "table" and ctx.hotfiles or {}) do
		top_names[#top_names + 1] = ctx.get_group_name(f)
	end
	if #top_names == 0 then return {} end

	local items = {}
	for _, name in ipairs(top_names) do
		if name == "custom" or name == "personal" or name:sub(1, 13) == "personal_ext_" then goto continue_group end
		if type(only) == "table" and not only[name] then goto continue_group end

		local enabled  = groupEnabled(ctx, name)
		local sections = ctx.keymap and type(ctx.keymap.get_sections) == "function" and ctx.keymap.get_sections(name) or nil
		local has_secs = type(sections) == "table" and #sections > 0

		local total = 0
		local is_sec_enabled = ctx.keymap and type(ctx.keymap.is_section_enabled) == "function"
			and ctx.keymap.is_section_enabled or nil
		if has_secs then
			for _, sec in ipairs(sections) do
				if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then
					if sec.count ~= nil then
						local active = not is_sec_enabled or is_sec_enabled(name, sec.name)
						if active then total = total + tonumber(sec.count) end
					end
				end
			end
		end

		local base_label = groupLabel(ctx, name)
		local item = {
			-- Always show count (even 0) — only enabled sections contribute
			title   = base_label .. " (" .. fmt_count(total) .. ")",
			checked = (enabled and not ctx.paused) or nil,
			fn      = toggleGroupFn(ctx, name),
		}

		if has_secs then
			local override    = (type(ctx.state.sections_order_overrides) == "table" and ctx.state.sections_order_overrides)[name]
			local ordered_secs

			if type(override) == "table" then
				local by_name = {}
				for _, sec in ipairs(sections) do if type(sec) == "table" then by_name[sec.name] = sec end end
				local seen = {}
				ordered_secs = {}
				for _, entry in ipairs(override) do
					if entry == "-" then table.insert(ordered_secs, { name = "-" })
					elseif by_name[entry] then
						table.insert(ordered_secs, by_name[entry]); seen[entry] = true
					end
				end
				for _, sec in ipairs(sections) do
					if type(sec) == "table" and not seen[sec.name] and sec.name ~= "-" then
						table.insert(ordered_secs, sec)
					end
				end
			else
				ordered_secs = sections
			end

			local sec_menu = {}
			local toml_path = toml_path_for_group(ctx, name)
			if toml_path then
				sec_menu[#sec_menu + 1] = {
					title = i18n.get("menu.hotstrings.open_file"),
					fn    = function() open_toml_path(toml_path) end,
				}
				sec_menu[#sec_menu + 1] = { title = "-" }
			end
			for _, sec in ipairs(ordered_secs) do
				if type(sec) == "table" then
					if sec.name == "-" then
						sec_menu[#sec_menu + 1] = { title = "-" }
					elseif sec.is_module_placeholder then
						local ms       = type(ctx.module_sections) == "table" and ctx.module_sections[name]
						local ms_entry = type(ms) == "table" and ms[sec.name]
						local mod_id   = type(ms_entry) == "table" and ms_entry.mod_id or ms_entry
						if mod_id == "personal_info" then
							local desc = resolve_desc((type(ms_entry) == "table" and ms_entry.description) or sec.description)
							local pi_items = buildPersonalInfoItems(ctx, desc)
							if pi_items then
								for _, pi in ipairs(pi_items) do
									sec_menu[#sec_menu + 1] = pi
								end
							end
						end
					else
						local sec_on = ctx.keymap and type(ctx.keymap.is_section_enabled) == "function" and ctx.keymap.is_section_enabled(name, sec.name) or false
						local lbl    = resolve_desc(sec.description) ~= "" and resolve_desc(sec.description)
									   or tostring(sec.name):gsub("_", " ")
						lbl = ctx.applyTriggerChar(lbl)
						sec_menu[#sec_menu + 1] = {
							title    = sec.count ~= nil and (lbl .. " (" .. fmt_count(sec.count) .. ")") or lbl,
							checked  = (sec_on and not ctx.paused) or nil,
							fn       = (enabled and not ctx.paused)
									   and toggleSectionFn(ctx, name, sec.name, lbl) or nil,
							disabled = not enabled or ctx.paused or nil,
						}
					end
				end
			end
			item.menu = sec_menu
		end
		items[#items + 1] = item
		::continue_group::
	end
	return items
end

--- Builds a toggle item for one preview bubble type.
--- @param ctx table Context.
--- @param label string Display label for the toggle item.
--- @param enabled_key string State key for the enabled flag.
--- @param set_enabled_fn string Keymap setter name for the enabled flag.
--- @param notify_label string Label used in the notification.
--- @return table The toggle menu item.
local function buildBubbleItem(ctx, label, enabled_key, set_enabled_fn, notify_label)
	local state  = ctx.state
	local paused = ctx.paused

	return {
		title    = label,
		checked  = (state[enabled_key] and not paused) or nil,
		disabled = paused or nil,
		fn       = not paused and function()
			state[enabled_key] = not state[enabled_key]
			if ctx.keymap and type(ctx.keymap[set_enabled_fn]) == "function" then
				pcall(ctx.keymap[set_enabled_fn], state[enabled_key])
			end
			ctx.save_prefs()
			ctx.notify_feature(notify_label, state[enabled_key])
			ctx.updateMenu()
		end or nil,
	}
end

--- Builds the management sub-menu.
--- @param ctx table Context.
--- @return table
function M.build_management(ctx)
	local state  = ctx.state
	local paused = ctx.paused
	local menu   = {}
	local bubble_item = nil
	local exp_item = nil
	local delays_item = nil

	local c_star        = M.DEFAULT_STATE.preview_star_color
	local c_autocorrect = M.DEFAULT_STATE.preview_autocorrect_color
	local c_ai          = M.DEFAULT_STATE.preview_ai_color

	local bubble_sub = {}

	table.insert(bubble_sub, buildBubbleItem(ctx,
		i18n.get("menu.hotstrings.tooltip_magic"),
		"preview_star_enabled",
		"set_preview_star_enabled",
		i18n.get("menu.hotstrings.notify_bubble_star")))

	table.insert(bubble_sub, buildBubbleItem(ctx,
		i18n.get("menu.hotstrings.tooltip_autocorrect"),
		"preview_autocorrect_enabled",
		"set_preview_autocorrect_enabled",
		i18n.get("menu.hotstrings.notify_bubble_autocorrect")))

	table.insert(bubble_sub, buildBubbleItem(ctx,
		i18n.get("menu.hotstrings.tooltip_ai"),
		"preview_ai_enabled",
		"set_preview_ai_enabled",
		i18n.get("menu.hotstrings.notify_bubble_ai")))

	table.insert(bubble_sub, { title = "-" })

	table.insert(bubble_sub, buildBubbleItem(ctx,
		i18n.get("menu.hotstrings.tooltip_colored"),
		"preview_colored_tooltips",
		"set_preview_colored_tooltips",
		i18n.get("menu.hotstrings.notify_bubble_colored")))

	bubble_item = { title = i18n.get("menu.hotstrings.preview_bubbles"), disabled = paused or nil, menu = bubble_sub }

	local defs    = ctx.keymap and type(ctx.keymap.get_terminator_defs) == "function" and ctx.keymap.get_terminator_defs() or {}
	local exp_sub = {}

	-- Built-in terminators (non-custom), with consume indicator
	for _, def in ipairs(defs) do
		if type(def) == "table" and not def.custom then
			if def.type == "separator" then
				exp_sub[#exp_sub + 1] = { title = "-" }
			elseif def.key then
				local enabled_t = ctx.keymap and type(ctx.keymap.is_terminator_enabled) == "function" and ctx.keymap.is_terminator_enabled(def.key) or false

				local lbl = def.label or ""
				lbl = lbl:gsub("Guillemets fermants", "Guillemet fermant")
				lbl = lbl:gsub("tiret bas", "underscore")
				lbl = lbl:gsub("Tiret bas", "Underscore")
				if def.consume then lbl = lbl .. " " .. i18n.get("menu.hotstrings.consumed_suffix") end

				exp_sub[#exp_sub + 1] = {
					title    = ctx.applyTriggerChar(lbl),
					checked  = (enabled_t and not paused) or nil,
					disabled = paused or nil,
					fn       = not paused and (function(k, l) return function()
						local nv = true
						if ctx.keymap and type(ctx.keymap.is_terminator_enabled) == "function" then
							nv = not ctx.keymap.is_terminator_enabled(k)
							if type(ctx.keymap.set_terminator_enabled) == "function" then
								pcall(ctx.keymap.set_terminator_enabled, k, nv)
							end
						end
						state.terminator_states[k] = nv
						ctx.save_prefs()
						ctx.notify_feature(string.format(i18n.get("notify.word_expander_prefix"), ctx.applyTriggerChar(l)), nv)
						ctx.updateMenu()
					end end)(def.key, lbl) or nil,
				}
			end
		end
	end

	-- Custom terminators + add button, grouped together at the bottom
	exp_sub[#exp_sub + 1] = { title = "-" }

	for _, ct in ipairs(type(state.custom_terminators) == "table" and state.custom_terminators or {}) do
		if type(ct) ~= "table" or type(ct.char) ~= "string" or ct.char == "" then goto continue_ct end
		local enabled_t = ctx.keymap and type(ctx.keymap.is_terminator_enabled) == "function" and ctx.keymap.is_terminator_enabled(ct.key) or false
		local consume_sfx = ct.consume and (" (" .. i18n.get("menu.hotstrings.consumed") .. ")") or ""
		local ct_lbl = ct.char .. " : " .. i18n.get("menu.hotstrings.custom_label") .. consume_sfx

		local ct_sub = {
			{
				title    = i18n.get("menu.hotstrings.delete_expander"),
				disabled = paused or nil,
				fn       = not paused and (function(k) return function()
					local res = dialog.block_alert(
						i18n.get("dialog.hotstrings.delete_title"),
						i18n.get("dialog.hotstrings.delete_body"),
						i18n.get("button.delete"), i18n.get("button.cancel")
					)
					if res ~= i18n.get("button.delete") then return end
					if ctx.keymap and type(ctx.keymap.remove_custom_terminator) == "function" then
						pcall(ctx.keymap.remove_custom_terminator, k)
					end
					if type(state.custom_terminators) == "table" then
						for i, ct_e in ipairs(state.custom_terminators) do
							if ct_e.key == k then table.remove(state.custom_terminators, i); break end
						end
					end
					if type(state.terminator_states) == "table" then state.terminator_states[k] = nil end
					ctx.save_prefs()
					ctx.updateMenu()
				end end)(ct.key) or nil,
			},
		}

		exp_sub[#exp_sub + 1] = {
			title    = ct_lbl,
			checked  = (enabled_t and not paused) or nil,
			menu     = ct_sub,
			disabled = paused or nil,
		}
		::continue_ct::
	end

	exp_sub[#exp_sub + 1] = {
		title    = i18n.get("menu.hotstrings.add_custom"),
		disabled = paused or nil,
		fn       = not paused and function()
			-- 1. Ask for the trigger character (loop until exactly one character is entered)
			local char
			while true do
				local ok_p, btn, char_raw = pcall(dialog.text_prompt,
					i18n.get("dialog.hotstrings.new_title"),
					i18n.get("dialog.hotstrings.new_prompt"),
					"", i18n.get("button.ok"), i18n.get("button.cancel")
				)
				if not ok_p or btn ~= "OK" or type(char_raw) ~= "string" then return end
				-- Extract first UTF-8 character and check nothing follows
				local first = char_raw:match("^([%z\1-\127\194-\244][\128-\191]*)")
				if first and first ~= "" and first == char_raw then
					char = first
					break
				end
				dialog.block_alert(i18n.get("dialog.hotstrings.invalid_title"), i18n.get("dialog.hotstrings.invalid_body"), i18n.get("button.retry"))
			end

			-- 2. Ask consume behaviour (default: non consommé)
			local consume_res = dialog.block_alert(
				i18n.get("dialog.hotstrings.consume_title"),
				i18n.get("dialog.hotstrings.consume_body"),
				i18n.get("dialog.hotstrings.consume_no"), i18n.get("dialog.hotstrings.consume_yes"), i18n.get("button.cancel")
			)
			if consume_res == i18n.get("button.cancel") then return end
			local consume = (consume_res == i18n.get("dialog.hotstrings.consume_yes"))

			-- 3. Generate a unique key
			local existing_keys = {}
			if ctx.keymap and type(ctx.keymap.get_terminator_defs) == "function" then
				for _, d in ipairs(ctx.keymap.get_terminator_defs()) do
					if d.key then existing_keys[d.key] = true end
				end
			end
			local idx = 1
			local key = "custom_" .. idx
			while existing_keys[key] do idx = idx + 1; key = "custom_" .. idx end

			local label = char .. " : " .. (consume and i18n.get("hotstrings.custom_terminator_consumed") or i18n.get("hotstrings.custom_terminator"))

			-- 4. Register in the live engine
			if ctx.keymap and type(ctx.keymap.add_custom_terminator) == "function" then
				pcall(ctx.keymap.add_custom_terminator, key, char, label, consume)
			end
			if ctx.keymap and type(ctx.keymap.set_terminator_enabled) == "function" then
				pcall(ctx.keymap.set_terminator_enabled, key, true)
			end

			-- 5. Persist in state
			if type(state.custom_terminators) ~= "table" then state.custom_terminators = {} end
			table.insert(state.custom_terminators, { key = key, char = char, label = label, consume = consume })
			state.terminator_states[key] = true
			ctx.save_prefs()
			ctx.updateMenu()
		end or nil,
	}

	exp_item = { title = i18n.get("menu.hotstrings.word_expanders"), disabled = paused or nil, menu = exp_sub }

	local delay_menu = {}
	local function make_delay_item(title, key, default_val, is_base)
		if type(default_val) ~= "number" then
			Logger.error(LOG, "make_delay_item(): default_val nil for '%s' — keymap.DELAYS_DEFAULT may be outdated.", title)
			return { title = title .. " : " .. i18n.get("menu.hotstrings.missing_value"), disabled = true }
		end
		local cur_val = is_base and state.expansion_delay or (state.delays[key] or default_val)
		local cur_ms = math.floor(cur_val * 1000 + 0.5)
		local def_ms = math.floor(default_val * 1000 + 0.5)
		local display_ms = (cur_ms == 0) and i18n.get("menu.hotstrings.infinite") or (cur_ms .. " ms")
		
		return {
			title    = title .. " : " .. display_ms .. (cur_ms == def_ms and (" " .. i18n.get("menu.hotstrings.default_indicator")) or ""),
			disabled = paused or nil,
			fn       = not paused and function()
				local ok_p, btn, raw = pcall(dialog.text_prompt,
					title,
					i18n.get("menu.hotstrings.delay_prompt"),
					tostring(cur_ms), "OK", i18n.get("common.cancel")
				)
				if not ok_p or btn ~= "OK" then return end

				local val = tonumber(raw)
				if not val or val < 0 or val ~= math.floor(val) then
					pcall(notifications.notify, i18n.get("menu.hotstrings.delay_invalid_title"), i18n.get("menu.hotstrings.delay_invalid_body"), "error")
					return
				end
				
				local new_sec = val / 1000
				if is_base then
					state.expansion_delay = new_sec
					if ctx.keymap and type(ctx.keymap.set_base_delay) == "function" then pcall(ctx.keymap.set_base_delay, new_sec) end
				else
					state.delays[key] = new_sec
					if ctx.keymap and type(ctx.keymap.set_delay) == "function" then pcall(ctx.keymap.set_delay, key, new_sec) end
				end
				ctx.save_prefs()
				ctx.updateMenu()
			end or nil,
		}
	end

	-- expansion_delay lives in keymap.DEFAULT_STATE; BASE_DELAY_SEC_DEFAULT is a legacy alias
	local def_base = ctx.keymap and (
		ctx.keymap.BASE_DELAY_SEC_DEFAULT
		or (type(ctx.keymap.DEFAULT_STATE) == "table" and ctx.keymap.DEFAULT_STATE.expansion_delay)
	)
	if not def_base then
		Logger.warn(LOG, "keymap.DEFAULT_STATE.expansion_delay missing — base delay undefined.")
	end
	local def_delays = ctx.keymap and type(ctx.keymap.DELAYS_DEFAULT) == "table" and ctx.keymap.DELAYS_DEFAULT
	if not def_delays then
		Logger.warn(LOG, "keymap.DELAYS_DEFAULT missing — individual delays undefined.")
	end

	-- The per-group delays for TOML-backed categories (rolls, autocorrection,
	-- magickey, sfbsreduction, distancesreduction, personal) live in the
	-- dedicated configuration window where colors can also be tuned. Categories
	-- that do not have a TOML counterpart (llm_prediction, dynamichotstrings)
	-- and the global baseline keep their per-prompt menu items as quick access.
	table.insert(delay_menu, {
		title    = i18n.get("menu.hotstrings.config_item"),
		disabled = paused or nil,
		fn       = not paused and function()
			local ok, win = pcall(require, "ui.hotstrings_config_window")
			if ok and win and type(win.open) == "function" then pcall(win.open) end
		end or nil,
	})
	table.insert(delay_menu, { title = "-" })
	if def_delays then
		table.insert(delay_menu, make_delay_item(i18n.get("menu.hotstrings.tooltip_ai_acceptance"), "llm_prediction", def_delays.llm_prediction, false))
		table.insert(delay_menu, make_delay_item(i18n.get("menu.hotstrings.tooltip_autocompletion"), "dynamichotstrings", def_delays.dynamichotstrings, false))
	end
	if def_base then
		table.insert(delay_menu, make_delay_item(i18n.get("menu.hotstrings.tooltip_default"), nil, def_base, true))
	end

	delays_item = { title = i18n.get("menu.hotstrings.delays_colors"), disabled = paused or nil, menu = delay_menu }

	if exp_item then table.insert(menu, exp_item) end
	if delays_item then table.insert(menu, delays_item) end
	table.insert(menu, { title = "-" })
	if bubble_item then table.insert(menu, bubble_item) end

	return { title = i18n.get("menu.hotstrings.params"), menu = menu }
end

--- Returns the list of personal extension group names present in hotfiles,
--- sorted alphabetically (excludes "personal" itself and "custom").
--- @param ctx table Context.
--- @return table List of group name strings.
local function get_personal_ext_groups(ctx)
	local ext = {}
	for _, f in ipairs(type(ctx.hotfiles) == "table" and ctx.hotfiles or {}) do
		local name = ctx.get_group_name(f)
		if name:sub(1, 13) == "personal_ext_" then
			table.insert(ext, name)
		end
	end
	table.sort(ext)
	return ext
end

--- Builds the unified personal hotstrings menu (personal_hotstrings.toml sections +
--- extension TOMLs from the hotstrings/ folder + custom/dynamic hotstrings),
--- with editor button, shortcut, and per-section toggles and counts for all groups.
--- @param ctx table Context.
--- @return table|nil
function M.build_custom(ctx)
	local state  = ctx.state
	local paused = ctx.paused

	local custom_enabled   = groupEnabled(ctx, "custom")
	local custom_secs      = ctx.keymap and type(ctx.keymap.get_sections) == "function" and ctx.keymap.get_sections("custom") or nil

	-- Collect all personal groups: "personal" first, then extension groups alphabetically
	local personal_group_names = {}
	local has_personal = false
	for _, f in ipairs(type(ctx.hotfiles) == "table" and ctx.hotfiles or {}) do
		if ctx.get_group_name(f) == "personal" then has_personal = true; break end
	end
	if has_personal then table.insert(personal_group_names, "personal") end
	for _, ext_name in ipairs(get_personal_ext_groups(ctx)) do
		table.insert(personal_group_names, ext_name)
	end

	-- Gather all sections across all personal groups
	local all_personal_secs_by_group = {}
	for _, gname in ipairs(personal_group_names) do
		local secs = ctx.keymap and type(ctx.keymap.get_sections) == "function" and ctx.keymap.get_sections(gname) or nil
		all_personal_secs_by_group[gname] = secs
	end
	-- Keep the personal group's sections for the default-section picker (personal only)
	local personal_secs = all_personal_secs_by_group["personal"]

	-- Total count across all personal groups + custom (for the top-level title).
	-- Only enabled sections contribute so the count reflects what is active.
	local total_count, has_count = 0, false
	local is_sec_enabled_fn = ctx.keymap and type(ctx.keymap.is_section_enabled) == "function"
		and ctx.keymap.is_section_enabled or nil
	local function add_counts(secs, gname)
		if type(secs) ~= "table" then return end
		for _, sec in ipairs(secs) do
			if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder
				and sec.count ~= nil then
				local active = not is_sec_enabled_fn or is_sec_enabled_fn(gname, sec.name)
				if active then
					has_count = true
					total_count = total_count + tonumber(sec.count)
				end
			end
		end
	end
	for _, gname in ipairs(personal_group_names) do
		add_counts(all_personal_secs_by_group[gname], gname)
	end
	add_counts(custom_secs, "custom")

	-- Strip leading "— " section marker for use as a plain notification label
	local base_title = (i18n.get("menu.hotstrings.personal_header"):gsub("^— ", ""))
	-- Always show count (even 0) — only enabled sections contribute
	local title_str  = base_title .. " (" .. fmt_count(total_count) .. ")"


	-- =====================
	-- Shortcut helpers
	-- =====================

	local function default_sc()
		return { mods = {"ctrl"}, key = state.trigger_char }
	end

	local function sc_is_default(sc)
		if not sc or sc == false or type(sc) ~= "table" then return false end
		local def = default_sc()
		if sc.key ~= def.key then return false end
		if #(sc.mods or {}) ~= 1 then return false end
		return sc.mods[1] == "ctrl"
	end

	local function sc_label()
		local sc = state.custom_editor_shortcut
		if not sc or sc == false then return i18n.get("menu.hotstrings.shortcut_none") end
		if sc_is_default(sc) then
			return string.format(i18n.get("menu.hotstrings.shortcut_default_ctrl"), state.trigger_char)
		end
		local mods_str = table.concat(sc.mods or {}, "+")
		return mods_str ~= "" and (mods_str .. " + " .. (sc.key or "?"):upper())
				or (sc.key or "?"):upper()
	end

	local function apply_shortcut(mods, key)
		if mods and key then
			state.custom_editor_shortcut = { mods = mods, key = key }
			if ctx.hotstring_editor and type(ctx.hotstring_editor.set_shortcut) == "function" then pcall(ctx.hotstring_editor.set_shortcut, mods, key) end
		else
			state.custom_editor_shortcut = false
			if ctx.hotstring_editor and type(ctx.hotstring_editor.clear_shortcut) == "function" then pcall(ctx.hotstring_editor.clear_shortcut) end
		end
		ctx.save_prefs(); ctx.updateMenu()
	end

	-- Shortcut item: clicking it opens the customisation dialog directly
	local function sc_fn()
		local current_str = ""
		if type(state.custom_editor_shortcut) == "table" then
			current_str = table.concat(state.custom_editor_shortcut.mods or {}, "+")
				.. "+" .. (state.custom_editor_shortcut.key or "")
		end
		local ok_p, btn, raw = pcall(dialog.text_prompt,
			i18n.get("hotstrings.shortcut_custom"),
			i18n.get("menu.hotstrings.shortcut_prompt"),
			current_str, "OK", i18n.get("common.cancel")
		)
		if not ok_p or btn ~= "OK" or type(raw) ~= "string" then return end
		raw = raw:match("^%s*(.-)%s*$"):lower()
		if raw == "" then apply_shortcut(nil, nil); return end
		local parts = {}
		for part in raw:gmatch("[^+]+") do table.insert(parts, part) end
		if #parts < 1 then return end
		local key  = parts[#parts]
		local mods = {}
		for i = 1, #parts - 1 do
			local m = parts[i]
			if m == "option" then m = "alt" end
			table.insert(mods, m)
		end
		if #mods == 0 then mods = {"ctrl"} end
		apply_shortcut(mods, key)
	end

	-- Build the default-section sub-menu: "Aucune" first, then one item per personal section
	local function default_section_label()
		if not state.custom_default_section then return i18n.get("menu.hotstrings.no_default_section") end
		if type(personal_secs) == "table" then
			for _, sec in ipairs(personal_secs) do
				if type(sec) == "table" and sec.name == state.custom_default_section then
					local lbl = resolve_desc(sec.description) ~= "" and resolve_desc(sec.description)
						or tostring(sec.name):gsub("_", " ")
					return ctx.applyTriggerChar(lbl)
				end
			end
		end
		return state.custom_default_section
	end

	local cat_menu = { {
		title   = i18n.get("menu.hotstrings.no_default_section"),
		checked = (not state.custom_default_section) or nil,
		fn      = function()
			state.custom_default_section = nil
			if ctx.hotstring_editor and type(ctx.hotstring_editor.set_default_section) == "function" then
				pcall(ctx.hotstring_editor.set_default_section, nil)
			end
			ctx.save_prefs(); ctx.updateMenu()
		end,
	} }
	if type(personal_secs) == "table" then
		local has_real = false
		for _, sec in ipairs(personal_secs) do
			if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then
				has_real = true; break
			end
		end
		if has_real then
			table.insert(cat_menu, { title = "-" })
			for _, sec in ipairs(personal_secs) do
				if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then
					local lbl   = (type(sec.description) == "string" and sec.description ~= "")
						and sec.description or tostring(sec.name):gsub("_", " ")
					lbl = ctx.applyTriggerChar(lbl)
					local sname = sec.name
					table.insert(cat_menu, {
						title   = lbl,
						checked = (state.custom_default_section == sname) or nil,
						fn      = function()
							state.custom_default_section = sname
							if ctx.hotstring_editor and type(ctx.hotstring_editor.set_default_section) == "function" then
								pcall(ctx.hotstring_editor.set_default_section, sname)
							end
							ctx.save_prefs(); ctx.updateMenu()
						end,
					})
				end
			end
		end
	end


	-- =====================
	-- Build section rows
	-- =====================

	--- Appends section toggle rows for one group into a target list.
	--- @param target table Destination list.
	--- @param group_name string "personal" or "custom".
	--- @param secs table Section list from keymap.get_sections().
	--- @param group_enabled boolean Whether the group itself is on.
	local function append_section_rows(target, group_name, secs, group_enabled)
		if type(secs) ~= "table" then return end
		local has_real = false
		for _, sec in ipairs(secs) do
			if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then
				has_real = true; break
			end
		end
		if not has_real then return end

		for _, sec in ipairs(secs) do
			if type(sec) ~= "table" then goto continue_sec end
			if sec.name == "-" then
				target[#target + 1] = { title = "-" }
			elseif not sec.is_module_placeholder then
				local sec_on = ctx.keymap and type(ctx.keymap.is_section_enabled) == "function"
					and ctx.keymap.is_section_enabled(group_name, sec.name) or false
				local lbl = (type(sec.description) == "string" and sec.description ~= "")
					and sec.description or tostring(sec.name):gsub("_", " ")
				lbl = ctx.applyTriggerChar(lbl)
				target[#target + 1] = {
					title    = sec.count ~= nil and (lbl .. " (" .. fmt_count(sec.count) .. ")") or lbl,
					checked  = (sec_on and not paused) or nil,
					fn       = (group_enabled and not paused)
							   and toggleSectionFn(ctx, group_name, sec.name, lbl) or nil,
					disabled = not group_enabled or paused or nil,
				}
			end
			::continue_sec::
		end
	end


	-- =====================
	-- Assemble menu items
	local menu_items = {
		{
			title    = i18n.get("menu.hotstrings.open_editor"),
			disabled = paused or nil,
			fn       = not paused and function()
				hs.timer.doAfter(0, function() pcall(ctx.hotstring_editor.open) end)
			end or nil,
		},
		{
			title    = i18n.get("menu.hotstrings.open_file"),
			disabled = paused or nil,
			fn       = not paused and function() open_toml_path(toml_path_for_group(ctx, "personal")) end or nil,
		},
		{ title = "-" },
		{
			-- Clicking this item directly opens the shortcut customisation dialog
			title    = i18n.get("menu.hotstrings.shortcut_prefix") .. sc_label(),
			disabled = paused or nil,
			fn       = not paused and sc_fn or nil,
		},
		{
			title = i18n.get("menu.hotstrings.default_category_prefix") .. default_section_label(),
			menu  = cat_menu,
		},
		{
			title    = i18n.get("menu.hotstrings.close_on_add"),
			checked  = state.custom_close_on_add or nil,
			fn       = not paused and function()
				state.custom_close_on_add = not state.custom_close_on_add
				if ctx.hotstring_editor and type(ctx.hotstring_editor.set_close_on_add) == "function" then
					pcall(ctx.hotstring_editor.set_close_on_add, state.custom_close_on_add)
				end
				ctx.save_prefs(); ctx.updateMenu()
			end or nil,
			disabled = paused or nil,
		},
	}

	local ext_tree = { folders = {}, files = {} }
	local function file_rows_for_group(gname, rows)
		local result = {}
		local path = toml_path_for_group(ctx, gname)
		if path then
			result[#result + 1] = {
				title = i18n.get("menu.hotstrings.open_file"),
				fn    = function() open_toml_path(path) end,
			}
			result[#result + 1] = { title = "-" }
		end
		for _, row in ipairs(rows) do result[#result + 1] = row end
		return result
	end
	local function sorted_keys(tbl)
		local keys = {}
		for key in pairs(type(tbl) == "table" and tbl or {}) do keys[#keys + 1] = key end
		table.sort(keys)
		return keys
	end
	local function render_ext_tree(node, target, separate_files)
		if separate_files == nil then separate_files = true end
		local folder_names = sorted_keys(node.folders)
		for _, folder_name in ipairs(folder_names) do
			local folder_menu = {}
			render_ext_tree(node.folders[folder_name], folder_menu, true)
			target[#target + 1] = { title = folder_name, menu = folder_menu }
		end
		if separate_files and #folder_names > 0 and #node.files > 0 then
			target[#target + 1] = { title = "-" }
		end
		table.sort(node.files, function(a, b) return a.title < b.title end)
		for _, file in ipairs(node.files) do
			target[#target + 1] = { title = file.title, menu = file.menu }
		end
	end

	-- All personal groups in order: personal first, then extensions alphabetically
	for _, gname in ipairs(personal_group_names) do
		local g_enabled = groupEnabled(ctx, gname)
		local g_secs    = all_personal_secs_by_group[gname]
		local g_rows    = {}
		append_section_rows(g_rows, gname, g_secs, g_enabled)

		if #g_rows > 0 then
			if gname == "personal" then
				table.insert(menu_items, { title = "-" })
				for _, row in ipairs(g_rows) do table.insert(menu_items, row) end
			else
				local stem = gname:sub(14)
				local parts = split_personal_ext_stem(stem)
				if #parts > 0 then
					local node = ext_tree
					for i = 1, #parts - 1 do
						local folder = parts[i]
						node.folders[folder] = node.folders[folder] or { folders = {}, files = {} }
						node = node.folders[folder]
					end
					node.files[#node.files + 1] = {
						title = parts[#parts],
						menu  = file_rows_for_group(gname, g_rows),
					}
				end
			end
		end
	end

	if #ext_tree.files > 0 or next(ext_tree.folders) ~= nil then
		table.insert(menu_items, { title = "-" })
		render_ext_tree(ext_tree, menu_items, false)
	end

	-- Custom/dynamic hotstrings sections (group "custom")
	local custom_rows = {}
	append_section_rows(custom_rows, "custom", custom_secs, custom_enabled)
	if #custom_rows > 0 then
		table.insert(menu_items, { title = "-" })
		for _, row in ipairs(custom_rows) do table.insert(menu_items, row) end
	end

	-- All groups toggle together when the user clicks the top-level item
	local all_personal_enabled = true
	for _, gname in ipairs(personal_group_names) do
		if not groupEnabled(ctx, gname) then all_personal_enabled = false; break end
	end
	local both_enabled = all_personal_enabled and custom_enabled
	return {
		title   = title_str,
		checked = (both_enabled and not paused) or nil,
		fn      = function()
			local will_enable = not both_enabled
			-- Toggle all personal groups
			for _, gname in ipairs(personal_group_names) do
				state.hotstrings[gname] = will_enable
				if will_enable then
					if ctx.keymap and type(ctx.keymap.enable_group) == "function" then pcall(ctx.keymap.enable_group, gname) end
				else
					if ctx.keymap and type(ctx.keymap.disable_group) == "function" then pcall(ctx.keymap.disable_group, gname) end
				end
			end
			-- Toggle custom group
			state.hotstrings["custom"] = will_enable
			if will_enable then
				if ctx.keymap and type(ctx.keymap.enable_group) == "function" then pcall(ctx.keymap.enable_group, "custom") end
				if not state.keymap then
					state.keymap = true
					if ctx.keymap and type(ctx.keymap.start) == "function" then pcall(ctx.keymap.start) end
				end
			else
				if ctx.keymap and type(ctx.keymap.disable_group) == "function" then pcall(ctx.keymap.disable_group, "custom") end
			end
			ctx.save_prefs()
			ctx.notify_feature(base_title, will_enable)
			ctx.updateMenu()
		end,
		menu = menu_items,
	}
end

return M
