--- ui/menu/menu_hotstrings.lua

--- ==============================================================================
--- MODULE: Menu Hotstrings
--- DESCRIPTION:
--- Builds the hotstrings and personal info sub-menus for the tray menu.
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("lib.logger")
local LOG    = "menu_hotstrings"

local dh_mod = require("modules.dynamic_hotstrings")





-- ===================================
-- ===================================
-- ======= 1/ Default State ==========
-- ===================================
-- ===================================

M.DEFAULT_STATE = {
	preview_star_enabled          = true,
	preview_autocorrect_enabled   = true,
	preview_ai_enabled            = true,
	custom_close_on_add           = false,
	custom_default_section        = nil,
	custom_editor_shortcut        = nil,
	sections_order_overrides      = {},
	terminator_states             = {},
	custom_terminators            = {},
	hotstrings                    = {},
	delays                        = {},
	personal_info                 = dh_mod.DEFAULT_STATE.personal_info,
	dynamichotstrings_enabled     = dh_mod.DEFAULT_STATE.dynamichotstrings_enabled,
}





-- ===================================
-- ===================================
-- ======= 2/ Menu Construction ======
-- ===================================
-- ===================================

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
				ctx.notify_feature(description or "Informations personnelles", ctx.state.personal_info)
				ctx.updateMenu()
			end,
		},
		{
			title = "   ↳ Modifier les informations…",
			fn    = function() hs.timer.doAfter(0.1, function() pcall(ctx.personal_info.open_editor) end) end,
		},
	}
end

--- Builds the main hotstring groups menu.
--- @param ctx table Context.
--- @return table
function M.build_groups(ctx)
	local top_names = {}
	for _, f in ipairs(type(ctx.hotfiles) == "table" and ctx.hotfiles or {}) do
		top_names[#top_names + 1] = ctx.get_group_name(f)
	end
	if #top_names == 0 then return {} end

	local items = {}
	for _, name in ipairs(top_names) do
		if name == "custom" or name == "personal" then goto continue_group end

		local enabled  = groupEnabled(ctx, name)
		local sections = ctx.keymap and type(ctx.keymap.get_sections) == "function" and ctx.keymap.get_sections(name) or nil
		local has_secs = type(sections) == "table" and #sections > 0

		local total, has_count = 0, false
		if enabled and has_secs then
			for _, sec in ipairs(sections) do
				if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder
					and (ctx.keymap and type(ctx.keymap.is_section_enabled) == "function" and ctx.keymap.is_section_enabled(name, sec.name)) then
					if sec.count ~= nil then has_count = true; total = total + tonumber(sec.count) end
				end
			end
		end

		local base_label = groupLabel(ctx, name)
		local item = {
			title   = has_count and (base_label .. " (" .. fmt_count(total) .. ")") or base_label,
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
			for _, sec in ipairs(ordered_secs) do
				if type(sec) == "table" then
					if sec.name == "-" then
						sec_menu[#sec_menu + 1] = { title = "-" }
					elseif sec.is_module_placeholder then
						local ms       = type(ctx.module_sections) == "table" and ctx.module_sections[name]
						local ms_entry = type(ms) == "table" and ms[sec.name]
						local mod_id   = type(ms_entry) == "table" and ms_entry.mod_id or ms_entry
						if mod_id == "personal_info" then
							local ms_desc  = type(ms_entry) == "table" and ms_entry.description or nil
							local pi_items = buildPersonalInfoItems(ctx, ms_desc)
							if type(pi_items) == "table" then
								for _, pi in ipairs(pi_items) do
									if type(pi) == "table" then
										if pi.checked ~= nil and ctx.paused then pi.checked = nil end
										if not enabled or ctx.paused then pi.fn = nil; pi.disabled = true end
										sec_menu[#sec_menu + 1] = pi
									end
								end
							end
						end
					else
						local sec_on = ctx.keymap and type(ctx.keymap.is_section_enabled) == "function" and ctx.keymap.is_section_enabled(name, sec.name) or false
						local lbl    = (type(sec.description) == "string" and sec.description ~= "")
									   and sec.description or tostring(sec.name):gsub("_", " ")
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

	-- Valeurs par défaut des couleurs (cohérentes avec llm_bridge et DEFAULT_STATE)
	local c_star        = M.DEFAULT_STATE.preview_star_color
	local c_autocorrect = M.DEFAULT_STATE.preview_autocorrect_color
	local c_ai          = M.DEFAULT_STATE.preview_ai_color

	local bubble_sub = {}

	table.insert(bubble_sub, buildBubbleItem(ctx,
		"Bulle ★ (touche magique)",
		"preview_star_enabled",
		"set_preview_star_enabled",
		"Bulle ★"))

	table.insert(bubble_sub, { title = "-" })

	table.insert(bubble_sub, buildBubbleItem(ctx,
		"Bulle Autocorrection (espace)",
		"preview_autocorrect_enabled",
		"set_preview_autocorrect_enabled",
		"Bulle Autocorrection"))

	table.insert(bubble_sub, { title = "-" })

	table.insert(bubble_sub, buildBubbleItem(ctx,
		"Bulle Intelligence artificielle",
		"preview_ai_enabled",
		"set_preview_ai_enabled",
		"Bulle IA"))

	table.insert(menu, { title = "Bulles de prévisualisation", disabled = paused or nil, menu = bubble_sub })
	table.insert(menu, { title = "-" })

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
				if def.consume then lbl = lbl .. " (consommé)" end

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
						ctx.notify_feature("Expanseur de mots : " .. ctx.applyTriggerChar(l), nv)
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
		local consume_sfx = ct.consume and " (consommé)" or ""
		local ct_lbl = ct.char .. " : Personnalisé" .. consume_sfx

		local ct_sub = {
			{
				title    = "Supprimer cet expanseur…",
				disabled = paused or nil,
				fn       = not paused and (function(k) return function()
					local res = hs.dialog.blockAlert(
						"Supprimer l'expanseur",
						"Êtes-vous sûr de vouloir supprimer cet expanseur personnalisé ?",
						"Supprimer", "Annuler"
					)
					if res ~= "Supprimer" then return end
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
		title    = "+ Ajouter un expanseur personnalisé…",
		disabled = paused or nil,
		fn       = not paused and function()
			-- 1. Ask for the trigger character (loop until exactly one character is entered)
			local char
			while true do
				local ok_p, btn, char_raw = pcall(hs.dialog.textPrompt,
					"Nouvel expanseur de mots",
					"Saisissez le caractère déclencheur (un seul caractère) :",
					"", "OK", "Annuler"
				)
				if not ok_p or btn ~= "OK" or type(char_raw) ~= "string" then return end
				-- Extract first UTF-8 character and check nothing follows
				local first = char_raw:match("^[%z\1-\127\194-\244][\128-\191]*")
				if first and first ~= "" and first == char_raw then
					char = first
					break
				end
				hs.dialog.blockAlert("Saisie invalide", "Veuillez saisir exactement un seul caractère.", "Réessayer")
			end

			-- 2. Ask consume behaviour (default: non consommé)
			local consume_res = hs.dialog.blockAlert(
				"Comportement du déclencheur",
				"Voulez-vous que le caractère soit consommé (non tapé) lors de l'expansion ?",
				"Non — taper le caractère", "Oui — consommer", "Annuler"
			)
			if consume_res == "Annuler" then return end
			local consume = (consume_res == "Oui — consommer")

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

			local label = char .. " : Personnalisé" .. (consume and " (consommé)" or "")

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

	table.insert(menu, { title = "Expanseurs de mots", disabled = paused or nil, menu = exp_sub })

	local delay_menu = {}
	local function make_delay_item(title, key, default_val, is_base)
		local cur_val = is_base and state.expansion_delay or (state.delays[key] or default_val)
		local cur_ms = math.floor(cur_val * 1000 + 0.5)
		local def_ms = math.floor(default_val * 1000 + 0.5)
		
		return {
			title    = title .. " : " .. cur_ms .. " ms" .. (cur_ms == def_ms and " (défaut)" or ""),
			disabled = paused or nil,
			fn       = not paused and function()
				local ok_p, btn, raw = pcall(hs.dialog.textPrompt,
					title,
					"Entrez le délai en millisecondes (entier ≥ 0) :",
					tostring(cur_ms), "OK", "Annuler"
				)
				if not ok_p or btn ~= "OK" then return end
				
				local val = tonumber(raw)
				if not val or val < 0 or val ~= math.floor(val) then
					pcall(function() hs.notify.new({ title = "Délai invalide", informativeText = "Veuillez saisir un entier ≥ 0." }):send() end)
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

	local def_base = ctx.keymap and ctx.keymap.BASE_DELAY_SEC_DEFAULT
	if not def_base then
		Logger.warn(LOG, "keymap.BASE_DELAY_SEC_DEFAULT manquant — délai de base indéfini")
	end
	local def_delays = ctx.keymap and type(ctx.keymap.DELAYS_DEFAULT) == "table" and ctx.keymap.DELAYS_DEFAULT
	if not def_delays then
		Logger.warn(LOG, "keymap.DELAYS_DEFAULT manquant — délais individuels indéfinis")
	end

	table.insert(delay_menu, make_delay_item("Touche ★", "STAR_TRIGGER", def_delays.STAR_TRIGGER, false))
	table.insert(delay_menu, make_delay_item("Auto-complétions (ex: numéros)", "dynamichotstrings", def_delays.dynamichotstrings, false))
	table.insert(delay_menu, make_delay_item("Autocorrections", "autocorrection", def_delays.autocorrection, false))
	table.insert(delay_menu, make_delay_item("Roulements", "rolls", def_delays.rolls, false))
	table.insert(delay_menu, make_delay_item("Réductions de SFBs", "sfbsreduction", def_delays.sfbsreduction, false))
	table.insert(delay_menu, make_delay_item("Réductions de distances", "distancesreduction", def_delays.distancesreduction, false))
	
	table.insert(delay_menu, { title = "-" })
	table.insert(delay_menu, make_delay_item("Défaut (autres catégories)", nil, def_base, true))

	table.insert(menu, { title = "Délais d’expansion", disabled = paused or nil, menu = delay_menu })
	table.insert(menu, { title = "-" })

	table.insert(menu, {
		title    = "Touche magique : " .. state.trigger_char,
		disabled = paused or nil,
		fn       = not paused and function()
			local ok_p, btn, raw = pcall(hs.dialog.textPrompt,
				"Touche magique",
				"Entrez le caractère à utiliser pour remplacer le ★ :",
				state.trigger_char, "OK", "Annuler"
			)
			if ok_p and btn == "OK" and type(raw) == "string" and raw ~= "" then
				local new_char = raw:match("^([%z\1-\127\194-\244][\128-\191]*)") or raw:sub(1,1)
				if new_char and new_char ~= state.trigger_char then
					state.trigger_char = new_char
					if ctx.keymap and type(ctx.keymap.set_trigger_char) == "function" then
						pcall(ctx.keymap.set_trigger_char, new_char)
					end
					if ctx.hotstring_editor and type(ctx.hotstring_editor.set_trigger_char) == "function" then
						pcall(ctx.hotstring_editor.set_trigger_char, new_char)
					end
					ctx.save_prefs()
					ctx.do_reload("menu")
				end
			end
		end or nil,
	})
	
	if state.trigger_char ~= "★" then
		table.insert(menu, {
			title    = "   ↳ Réinitialiser (défaut : ★)",
			disabled = paused or nil,
			fn       = not paused and function()
				state.trigger_char = "★"
				if ctx.keymap and type(ctx.keymap.set_trigger_char) == "function" then pcall(ctx.keymap.set_trigger_char, "★") end
				ctx.save_prefs(); ctx.do_reload("menu")
			end or nil,
		})
	end

	return { title = "Paramètres Hotstrings", menu = menu }
end

--- Builds the personal hotstrings section.
--- @param ctx table Context.
--- @return table|nil
function M.build_personal(ctx)
	local state  = ctx.state
	local paused = ctx.paused
	local name   = "personal"
	
	local found = false
	for _, f in ipairs(type(ctx.hotfiles) == "table" and ctx.hotfiles or {}) do
		if ctx.get_group_name(f) == name then found = true; break end
	end
	if not found then return nil end

	local enabled  = groupEnabled(ctx, name)
	local sections = ctx.keymap and type(ctx.keymap.get_sections) == "function" and ctx.keymap.get_sections(name) or nil
	local has_secs = type(sections) == "table" and #sections > 0

	local total, has_count = 0, false
	if enabled and has_secs then
		for _, sec in ipairs(sections) do
			if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder
				and (ctx.keymap and type(ctx.keymap.is_section_enabled) == "function" and ctx.keymap.is_section_enabled(name, sec.name)) then
				if sec.count ~= nil then has_count = true; total = total + tonumber(sec.count) end
			end
		end
	end

	local base_label = "Hotstrings AHK" -- Libellé ajusté comme demandé
	local item = {
		title   = has_count and (base_label .. " (" .. fmt_count(total) .. ")") or base_label,
		checked = (enabled and not paused) or nil,
		fn      = toggleGroupFn(ctx, name),
	}

	if has_secs then
		local override    = (type(state.sections_order_overrides) == "table" and state.sections_order_overrides)[name]
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
		for _, sec in ipairs(ordered_secs) do
			if type(sec) == "table" then
				if sec.name == "-" then
					sec_menu[#sec_menu + 1] = { title = "-" }
				elseif sec.is_module_placeholder then
					local ms       = type(ctx.module_sections) == "table" and ctx.module_sections[name]
					local ms_entry = type(ms) == "table" and ms[sec.name]
					local mod_id   = type(ms_entry) == "table" and ms_entry.mod_id or ms_entry
					if mod_id == "personal_info" then
						local ms_desc  = type(ms_entry) == "table" and ms_entry.description or nil
						local pi_items = buildPersonalInfoItems(ctx, ms_desc)
						if type(pi_items) == "table" then
							for _, pi in ipairs(pi_items) do
								if type(pi) == "table" then
									if pi.checked ~= nil and paused then pi.checked = nil end
									if not enabled or paused then pi.fn = nil; pi.disabled = true end
									sec_menu[#sec_menu + 1] = pi
								end
							end
						end
					end
				else
					local sec_on = ctx.keymap and type(ctx.keymap.is_section_enabled) == "function" and ctx.keymap.is_section_enabled(name, sec.name) or false
					local lbl    = (type(sec.description) == "string" and sec.description ~= "")
								   and sec.description or tostring(sec.name):gsub("_", " ")
					lbl = ctx.applyTriggerChar(lbl)
					sec_menu[#sec_menu + 1] = {
						title    = sec.count ~= nil and (lbl .. " (" .. fmt_count(sec.count) .. ")") or lbl,
						checked  = (sec_on and not paused) or nil,
						fn       = (enabled and not paused)
								   and toggleSectionFn(ctx, name, sec.name, lbl) or nil,
						disabled = not enabled or paused or nil,
					}
				end
			end
		end
		item.menu = sec_menu
	end
	return item
end

--- Builds the custom user hotstrings menu.
--- @param ctx table Context.
--- @return table
function M.build_custom(ctx)
	local state  = ctx.state
	local paused = ctx.paused
	local custom_sections = ctx.keymap and type(ctx.keymap.get_sections) == "function" and ctx.keymap.get_sections("custom") or nil
	local custom_enabled  = groupEnabled(ctx, "custom")

	local total_count, has_count = 0, false
	if custom_enabled and type(custom_sections) == "table" then
		for _, sec in ipairs(custom_sections) do
			if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder
				and (ctx.keymap and type(ctx.keymap.is_section_enabled) == "function" and ctx.keymap.is_section_enabled("custom", sec.name)) then
				if sec.count ~= nil then has_count = true; total_count = total_count + tonumber(sec.count) end
			end
		end
	end

	local base_title = "Hotstrings personnels"
	local title_str  = has_count
		and (base_title .. " (" .. fmt_count(total_count) .. ")")
		or  base_title

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
		if not sc or sc == false then return "Aucun" end
		if sc_is_default(sc) then
			return "Ctrl + " .. state.trigger_char .. " (défaut)"
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

	local function default_section_label()
		if not state.custom_default_section then return "Aucune" end
		if type(custom_sections) == "table" then
			for _, sec in ipairs(custom_sections) do
				if type(sec) == "table" and sec.name == state.custom_default_section then
					local lbl = (type(sec.description) == "string" and sec.description ~= "")
						and sec.description or tostring(sec.name):gsub("_", " ")
					return ctx.applyTriggerChar(lbl)
				end
			end
		end
		return state.custom_default_section
	end

	local cat_menu = {}
	table.insert(cat_menu, {
		title   = "Aucune",
		checked = (not state.custom_default_section) or nil,
		fn      = function()
			state.custom_default_section = nil
			if ctx.hotstring_editor and type(ctx.hotstring_editor.set_default_section) == "function" then
				pcall(ctx.hotstring_editor.set_default_section, nil)
			end
			ctx.save_prefs(); ctx.updateMenu()
		end,
	})
	
	if type(custom_sections) == "table" then
		local has_real = false
		for _, sec in ipairs(custom_sections) do
			if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then has_real = true; break end
		end
		if has_real then
			table.insert(cat_menu, { title = "-" })
			for _, sec in ipairs(custom_sections) do
				if type(sec) == "table" then
					if sec.name == "-" then
						table.insert(cat_menu, { title = "-" })
					elseif not sec.is_module_placeholder then
						local lbl  = (type(sec.description) == "string" and sec.description ~= "")
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
	end

	local def_sc      = default_sc()
	local already_def = sc_is_default(state.custom_editor_shortcut)
	
	local sc_menu = {
		{
			title = "Personnaliser…",
			fn    = function()
				local current_str = ""
				if type(state.custom_editor_shortcut) == "table" then
					current_str = table.concat(state.custom_editor_shortcut.mods or {}, "+")
						.. "+" .. (state.custom_editor_shortcut.key or "")
				end
				local ok_p, btn, raw = pcall(hs.dialog.textPrompt,
					"Raccourci personnalisé",
					"Format : mods+touche  (ex : cmd+alt+p  ou  ctrl+shift+e)\n"
						.. "Mods disponibles : cmd, alt, ctrl, shift\nLaisser vide pour désactiver",
					current_str, "OK", "Annuler"
				)
				if not ok_p or btn ~= "OK" or type(raw) ~= "string" then return end
				raw = raw:match("^%s*(.-)%s*$"):lower()
				if raw == "" then
					apply_shortcut(nil, nil)
					return
				end
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
			end,
		}
	}

	if not already_def then
		table.insert(sc_menu, {
			title    = (function()
				local def = def_sc
				local mods = def.mods or {}
				local mods_cap = {}
				for i, m in ipairs(mods) do
					mods_cap[i] = m:sub(1,1):upper() .. m:sub(2)
				end
				local mods_str = table.concat(mods_cap, "+")
				local key_str = def.key or "?"
				return "   ↳ Réinitialiser (défaut : " .. (mods_str ~= "" and (mods_str .. " + ") or "") .. key_str:upper() .. ")"
			end)(),
			fn       = function() apply_shortcut(def_sc.mods, def_sc.key) end,
		})
	end

	table.insert(sc_menu, {
		title = "Catégorie par défaut : " .. default_section_label(),
		menu  = cat_menu,
	})

	table.insert(sc_menu, {
		title   = "Fermer l’UI après ajout d’un hotstring par le raccourci",
		checked = state.custom_close_on_add or nil,
		fn      = function()
			state.custom_close_on_add = not state.custom_close_on_add
			if ctx.hotstring_editor and type(ctx.hotstring_editor.set_close_on_add) == "function" then
				pcall(ctx.hotstring_editor.set_close_on_add, state.custom_close_on_add)
			end
			ctx.save_prefs(); ctx.updateMenu()
		end,
	})

	local menu_items = {
		{
			title    = "Ouvrir l’éditeur de hotstrings",
			disabled = paused or nil,
			fn       = not paused and function()
				hs.timer.doAfter(0, function() pcall(ctx.hotstring_editor.open) end)
			end or nil,
		},
		{
			title = "Raccourci : " .. sc_label(),
			menu  = sc_menu,
		},
	}

	if type(custom_sections) == "table" and #custom_sections > 0 then
		local has_real = false
		for _, sec in ipairs(custom_sections) do
			if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then has_real = true; break end
		end
		if has_real then
			table.insert(menu_items, { title = "-" })
			for _, sec in ipairs(custom_sections) do
				if type(sec) == "table" then
					if sec.name == "-" then
						table.insert(menu_items, { title = "-" })
					elseif not sec.is_module_placeholder then
						local sec_on = ctx.keymap and type(ctx.keymap.is_section_enabled) == "function" and ctx.keymap.is_section_enabled("custom", sec.name) or false
						local lbl    = (type(sec.description) == "string" and sec.description ~= "")
									   and sec.description or tostring(sec.name):gsub("_", " ")
						lbl = ctx.applyTriggerChar(lbl)
						table.insert(menu_items, {
							title    = sec.count ~= nil
								and (lbl .. " (" .. fmt_count(sec.count) .. ")") or lbl,
							checked  = (sec_on and not paused) or nil,
							fn       = (custom_enabled and not paused)
									   and toggleSectionFn(ctx, "custom", sec.name, lbl) or nil,
							disabled = not custom_enabled or paused or nil,
						})
					end
				end
			end
		end
	end

	return {
		title   = title_str,
		checked = (custom_enabled and not paused) or nil,
		fn      = function()
			local will_enable = not custom_enabled
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
