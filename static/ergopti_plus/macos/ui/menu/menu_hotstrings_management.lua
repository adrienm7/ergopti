--- ui/menu/menu_hotstrings_management.lua

--- ==============================================================================
--- MODULE: Menu Hotstrings — Management sub-menu
--- DESCRIPTION:
--- Builds the Paramètres sub-menu for the hotstrings tray menu: preview bubbles
--- (magic key, autocorrection, AI, coloured tooltips), word expanders (built-in
--- and custom terminators with add/delete), per-category delay configuration,
--- magic key character editor, and the repeat key toggle.
--- Sub-module of ui.menu.menu_hotstrings — merged at load time via
--- `for k, v in pairs(sub) do M[k] = v end`.
--- ==============================================================================

local M = {}
local hs                = hs
local Logger            = require("infra.logger")
local dialog            = require("infra.dialog_util")
local notifications     = require("infra.notifications")
local i18n              = require("infra.i18n")
local hotstrings_config = require("modules.hotstrings.hotstrings_config")
local LOG               = "menu_hotstrings"





-- =============================
-- =============================
-- ======= 1/ Management =======
-- =============================
-- =============================

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
		checked  = state[enabled_key] or nil,
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

	-- Bulk actions — mirror the Windows word-expanders submenu so both drivers
	-- expose the same set: enable all / disable all / reset the built-in
	-- terminators to their catalogue defaults. Custom terminators are managed
	-- individually below and are left untouched here.
	local function bulk_set_terminators(enabled)
		for _, d in ipairs(defs) do
			if type(d) == "table" and not d.custom and d.key then
				if ctx.keymap and type(ctx.keymap.set_terminator_enabled) == "function" then
					pcall(ctx.keymap.set_terminator_enabled, d.key, enabled)
				end
				state.terminator_states[d.key] = enabled
			end
		end
		ctx.save_prefs()
		ctx.updateMenu()
	end
	local function reset_terminators()
		for _, d in ipairs(defs) do
			if type(d) == "table" and not d.custom and d.key then
				-- default_enabled is true unless the catalogue marks it false (slash/backslash)
				local def_on = (d.default_enabled ~= false)
				if ctx.keymap and type(ctx.keymap.set_terminator_enabled) == "function" then
					pcall(ctx.keymap.set_terminator_enabled, d.key, def_on)
				end
				state.terminator_states[d.key] = def_on
			end
		end
		ctx.save_prefs()
		ctx.updateMenu()
	end
	exp_sub[#exp_sub + 1] = { title = i18n.get("menu.hotstrings.check_all"),   disabled = paused or nil, fn = not paused and function() bulk_set_terminators(true)  end or nil }
	exp_sub[#exp_sub + 1] = { title = i18n.get("menu.hotstrings.uncheck_all"), disabled = paused or nil, fn = not paused and function() bulk_set_terminators(false) end or nil }
	exp_sub[#exp_sub + 1] = { title = i18n.get("menu.global.reset_defaults"),  disabled = paused or nil, fn = not paused and reset_terminators or nil }
	exp_sub[#exp_sub + 1] = { title = "-" }

	-- Built-in terminators (non-custom), with consume indicator. The shared
	-- catalogue order IS the menu order; { type = "separator" } entries become
	-- "-" dividers so the groups (whitespace, punctuation, apostrophes, closing
	-- delimiters, slashes, magic key) are separated — single source = the spec.
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
					checked  = enabled_t or nil,
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
			checked  = enabled_t or nil,
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
		-- Coerce + fail closed to default_val: state.expansion_delay (and per-key
		-- delays) come straight from config.toml and can be a string (hand edit /
		-- AHK migration). The engine apply is already type-guarded (menu_state.lua),
		-- but this arithmetic (cur_val * 1000) would crash the delay submenu build —
		-- swallowed by the builder pcall, dropping the whole Paramètres submenu (F-L13).
		local cur_val = tonumber(is_base and state.expansion_delay or (state.delays[key] or default_val)) or default_val
		local cur_ms = math.floor(cur_val * 1000 + 0.5)
		local def_ms = math.floor(default_val * 1000 + 0.5)
		local display_ms = (cur_ms == 0) and i18n.get("menu.hotstrings.infinite") or (cur_ms .. " ms")

		return {
			-- menu.settings.default_indicator (" (default)") is the surviving shared
			-- key — its value already carries the leading space, so we don't add one.
			title    = title .. " : " .. display_ms .. (cur_ms == def_ms and i18n.get("menu.settings.default_indicator") or ""),
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

	-- Builds a quick-access delay item for a TOML-backed category (magic key,
	-- autocorrection). Unlike make_delay_item — which owns its value in
	-- state.delays — this reads the EFFECTIVE delay via hotstrings_config.resolve
	-- (so the row shows the same number as the config window) and writes through
	-- set_override (the one persistent source both UIs share), then pushes the new
	-- value into the live CoreState.DELAYS via set_delay so it applies at once.
	local function make_category_delay_item(title, key, category)
		local resolved = hotstrings_config.resolve(category, nil)
		local cur_val  = (type(resolved) == "table" and type(resolved.delay) == "number") and resolved.delay or nil
		if type(cur_val) ~= "number" then
			Logger.error(LOG, "make_category_delay_item(): no resolvable delay for category '%s'.", category)
			return { title = title .. " : " .. i18n.get("menu.hotstrings.missing_value"), disabled = true }
		end
		local cur_ms     = math.floor(cur_val * 1000 + 0.5)
		local has_over   = (type(resolved) == "table" and resolved.has_override) or false
		local display_ms = (cur_ms == 0) and i18n.get("menu.hotstrings.infinite") or (cur_ms .. " ms")

		return {
			-- menu.settings.default_indicator (" (default)") carries its own leading
			-- space; show it while the user has set no override for this category.
			title    = title .. " : " .. display_ms .. ((not has_over) and i18n.get("menu.settings.default_indicator") or ""),
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

				-- Persist through hotstrings_config (same store + file the config
				-- window writes to, so the two UIs never desync) then apply to the
				-- running engine so the new delay takes effect without a restart.
				local new_sec = val / 1000
				pcall(hotstrings_config.set_override, category, nil, "delay", new_sec)
				if ctx.keymap and type(ctx.keymap.set_delay) == "function" then pcall(ctx.keymap.set_delay, key, new_sec) end
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
			if not ok or not win or type(win.open) ~= "function" then return end
			-- make_category_delay_item bakes the resolved delay and the
			-- "(default)" indicator into its title at BUILD time, so an override
			-- edited in the window leaves those rows showing pre-edit values and a
			-- false default tag until something else rebuilds the menu. Hand the
			-- window an explicit refresh channel so the two UIs cannot desync.
			win._on_config_changed = function()
				ctx.save_prefs()
				ctx.updateMenu()
			end
			pcall(win.open)
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

	-- The ★ magic-key and autocorrection delays are TOML-backed categories
	-- (also tunable in the config window). Surface them here too, mirroring the
	-- AHK tray, so the most-used per-category delays are one click away.
	if def_delays then
		table.insert(delay_menu, { title = "-" })
		table.insert(delay_menu, make_category_delay_item(i18n.get("menu.hotstrings.delay_magic_key"), "STAR_TRIGGER", "magickey"))
		table.insert(delay_menu, make_category_delay_item(i18n.get("menu.hotstrings.delay_autocorrection"), "autocorrection", "autocorrection"))
	end

	delays_item = { title = i18n.get("menu.hotstrings.delays_colors"), disabled = paused or nil, menu = delay_menu }

	if exp_item then table.insert(menu, exp_item) end
	if delays_item then table.insert(menu, delays_item) end
	table.insert(menu, { title = "-" })
	if bubble_item then table.insert(menu, bubble_item) end
	table.insert(menu, { title = "-" })
	local hs_state  = ctx and ctx.state
	local hs_paused = ctx and ctx.paused
	table.insert(menu, {
		title    = i18n.get("menu.hotstrings.magic_key_prefix") .. (hs_state and hs_state.trigger_char or "★"),
		disabled = hs_paused or nil,
		fn       = not hs_paused and function()
			if not hs_state then return end
			local ok_p, btn, raw = pcall(dialog.text_prompt,
				i18n.get("menu.hotstrings.magic_key_title"),
				i18n.get("menu.hotstrings.magic_key_prompt"),
				hs_state.trigger_char, "OK", i18n.get("common.cancel")
			)
			if ok_p and btn == "OK" and type(raw) == "string" and raw ~= "" then
				local new_char = raw:match("^([%z\1-\127\194-\244][\128-\191]*)") or raw:sub(1,1)
				if new_char and new_char ~= hs_state.trigger_char then
					hs_state.trigger_char = new_char
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
	local repeat_enabled = ctx and ctx.keymap
		and type(ctx.keymap.is_repeat_feature_enabled) == "function"
		and ctx.keymap.is_repeat_feature_enabled()
	table.insert(menu, {
		title    = i18n.get("menu.hotstrings.repeat_key_toggle"),
		checked  = repeat_enabled,
		disabled = hs_paused or nil,
		fn       = not hs_paused and function()
			if ctx and ctx.keymap and type(ctx.keymap.set_repeat_feature_enabled) == "function" then
				pcall(ctx.keymap.set_repeat_feature_enabled, not repeat_enabled)
			end
			ctx.do_reload("menu")
		end or nil,
	})

	return { title = i18n.get("menu.hotstrings.params"), menu = menu }
end

return M
