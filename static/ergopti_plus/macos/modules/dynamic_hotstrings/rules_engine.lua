--- modules/dynamic_hotstrings/rules_engine.lua

--- ==============================================================================
--- MODULE: Rules Engine (Hammerspoon shim)
--- DESCRIPTION:
--- Hammerspoon-specific shim that wires the shared pure-Lua dynamic hotstrings
--- rules engine into the HS keymap module. Handles hs.eventtap injection and
--- hs.timer scheduling — the matching logic itself lives in the shared module at
--- _shared/lua/dynamic_hotstrings/init.lua.
---
--- FEATURES & RATIONALE:
--- 1. Thin shim: all suffix-matching and rule-registration logic is delegated to
---    the shared engine; this file only adds HS-specific injection mechanics.
--- 2. Instant Resolution: uses the keymap interceptor for low-latency replacements.
--- ==============================================================================

local M = {}

local hs = hs
local ok_utils, km_utils = pcall(require, "modules.keymap.utils")
if not ok_utils then km_utils = nil end

local ok_kl, keylogger = pcall(require, "modules.keylogger")
if not ok_kl then keylogger = nil end

local SharedEngine = require("dynamic_hotstrings")

local Logger = require("infra.logger")
local text_utils = require("infra.text_utils")
local LOG    = "dynamic_hotstrings.rules"

local ok_locale, locale = pcall(require, "infra.locale")
if not ok_locale then locale = nil end





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local GROUP_NAME = "dynamichotstrings"

local _km             = nil
local _trigger        = "\u{2605}"
local _is_injecting   = false
local _personal_data  = nil
-- Mutable section list kept as an upvalue so register_prefix_entries can
-- update the real counts after personal data is injected.
local _sections       = nil





-- =========================================
-- =========================================
-- ======= 2/ Key Interceptor Engine =======
-- =========================================
-- =========================================

--- Intercepts keystrokes to detect suffix + trigger combinations for dynamic resolution.
--- @param event userdata The Hammerspoon hs.eventtap.event object.
--- @param km_buffer string The current typing buffer maintained by the keymap module.
--- @return string|nil Returns "consume" to swallow the event, or nil to pass it through.
--- @param event userdata The keyDown event.
--- @param km_buffer string The keymap buffer.
--- @param ctx table|nil Fields the keymap tap already read from the event
---        (keyCode, flags, chars). Re-fetching them is an ObjC accessor call
---        per interceptor per keystroke; the fallback keeps this working if the
---        contract is ever invoked without a context.
local function interceptor(event, km_buffer, ctx)
	if _is_injecting or not _km then return nil end

	local flags = (ctx and ctx.flags) or event:getFlags()
	if flags.cmd or flags.ctrl then return nil end

	local char = (ctx and ctx.chars) or event:getCharacters(false) or ""
	if char ~= _trigger then return nil end

	-- Gate on the group master toggle so that disabling the dynamichotstrings group
	-- (or "Disable all hotstrings") stops date expansion even though date rules are
	-- matched through the interceptor rather than registry mappings (M-9).
	if type(_km.is_group_enabled) == "function" and not _km.is_group_enabled(GROUP_NAME) then
		return nil
	end

	local is_sec_enabled = _km.is_section_enabled
	local guard = is_sec_enabled
		and function(grp, sec) return is_sec_enabled(grp, sec) end
		or nil

	local match = SharedEngine.match_buffer(km_buffer or "", GROUP_NAME, guard)
	if not match then return nil end

	local rule   = match.rule
	local result = match.result
	local n_back = #rule.suffix

	Logger.debug(LOG, "Injecting dynamic rule for suffix '%s'…", rule.suffix)

	-- Arm the keymap synthetic counters BEFORE deferring injection so that the
	-- We do NOT call keylogger.log_hotstring here: the result may contain private
	-- data (phone number, SSN, IBAN) whose plaintext must never reach the log.
	_is_injecting = true

	local ok, err = pcall(function()
		if _km and type(_km.inject_dynamic) == "function" then
			_km.inject_dynamic(n_back, result, function()
				if km_utils and type(km_utils.emit_text) == "function" then
					return km_utils.emit_text(result)
				else
					hs.eventtap.keyStrokes(result)
					return #result, result
				end
			-- is_private = true for the same reason the comment above declines
			-- log_hotstring: the result may be a phone number, an SSN or an IBAN.
			-- Declining ONE sink while the other recorded the plaintext is what
			-- made that comment describe an invariant the code did not hold.
			-- Retained by default rather than per-rule, because a rule carries no
			-- confidentiality metadata and default-retain is the only shape in
			-- which a future rule cannot leak by omission.
			end, "dynamic", true)
		else
			-- Fallback if inject_dynamic is not available
			if _km then
				if type(_km.suppress_rescan) == "function" then _km.suppress_rescan() end
				if type(_km.arm_synthetic) == "function" then _km.arm_synthetic(n_back, result) end
			end
			if keylogger and type(keylogger.notify_synthetic) == "function" then
				-- Same privacy contract as the primary path above — this branch
				-- reaches the identical sink, so it needs the identical flag.
				pcall(keylogger.notify_synthetic, result, "hotstring", n_back, "dynamic", nil, true)
			end
			for _ = 1, n_back do
				hs.eventtap.keyStroke({}, "delete", 0)
			end
			if km_utils and type(km_utils.emit_text) == "function" then
				km_utils.emit_text(result)
			else
				hs.eventtap.keyStrokes(result)
			end
		end
	end)

	if not ok then
		Logger.error(LOG, "Dynamic rule injection failed: %s.", tostring(err))
	end

	-- Release the injecting flag immediately — no timer needed now that emission
	-- is synchronous; keeping it true beyond this point would block re-entrancy.
	_is_injecting = false
	if ok then
		Logger.info(LOG, "Dynamic rule injection completed.")
	end

	return "consume"
end





-- ============================================
-- ============================================
-- ======= 3/ Data-Dependent Expansions =======
-- ============================================
-- ============================================

--- Generates and registers all prefix-based hotstrings based on the user's personal data.
local function register_prefix_entries()
	if type(_personal_data) ~= "table" then return end
	if not _km then
		-- Personal data is present but the keymap is not wired yet. This happens
		-- when inject_data() runs BEFORE start() (the production order), so the
		-- Registration is deferred to M.start(), which calls us again once _km is
		-- set. This is the normal production order; M.start() verifies the keymap
		-- was actually wired before registering any prefix expansion.
		Logger.debug(LOG, "Personal data received before keymap wiring; prefix registration deferred to M.start().")
		return
	end
	Logger.debug(LOG, "Registering prefix-based dynamic hotstrings…")

	-- is_private marks every mapping built from personal_info.toml as PII. The
	-- interceptor path above already refuses to log its result; these prefix
	-- mappings take the EXPANDER path instead, which logs trigger AND replacement
	-- to the 14-day log and the metrics store by default. Both sides must stay
	-- out: the trigger prefix is itself a fragment of the secret (the first 5
	-- digits of the SSN, the first 6 chars of the IBAN), so redacting only the
	-- replacement would still leak
	local base_opts = { is_word = false, auto_expand = true, is_case_sensitive = true, is_private = true }

	--- Copies the shared flags and names the personal_info.toml field the value
	--- came from.
	---
	--- Per call, never once into a shared table: this function registers FOUR
	--- different fields, and the phone number and its spaced variant are both
	--- registered from the same block — so a single `base_opts.field = …` would
	--- tag every mapping as whichever name was written last. Both phone fields are
	--- declared public today, which is exactly what would make that mistake
	--- invisible until one of them was reclassified and the bubble started
	--- revealing it.
	--- @param field string The personal_info.toml field name.
	--- @param overrides table|nil Flags that differ from the shared base.
	--- @return table
	local function opts_for(field, overrides)
		local out = {}
		for key, value in pairs(base_opts) do out[key] = value end
		for key, value in pairs(overrides or {}) do out[key] = value end
		out.field = field
		return out
	end

	local phone  = type(_personal_data.phone_number) == "string" and _personal_data.phone_number or tostring(_personal_data.phone_number or "")
	local fphone = type(_personal_data.phone_number_clean) == "string" and _personal_data.phone_number_clean or tostring(_personal_data.phone_number_clean or "")
	local ssn    = type(_personal_data.social_security_number) == "string" and _personal_data.social_security_number or tostring(_personal_data.social_security_number or "")
	local iban   = type(_personal_data.iban) == "string" and _personal_data.iban or tostring(_personal_data.iban or "")

	-- Strip decorative spaces for prefix matching (SSN and IBAN contain spaces)
	local ssn_raw  = ssn:gsub("%s+", "")
	local iban_raw = iban:gsub("%s+", "")

	-- Update section counts in the registry so build_groups shows accurate totals.
	local counts = SharedEngine.compute_prefix_counts(phone, fphone, ssn_raw, iban_raw)
	if type(_sections) == "table" then
		for _, sec in ipairs(_sections) do
			if type(sec) == "table" and counts[sec.name] ~= nil then
				sec.count = counts[sec.name]
			end
		end
	end

	if _km.set_group_context then _km.set_group_context(GROUP_NAME) end

	-- Register phone prefixes
	if _km.is_section_enabled and _km.is_section_enabled(GROUP_NAME, "phoneprefixes") then
		-- Two DIFFERENT fields in one block: every entry below expands to the raw
		-- number except the last, which expands to the spaced variant.
		local phone_opts  = opts_for("phone_number")
		local fphone_opts = opts_for("phone_number_clean")
		if #phone >= 2 then
			_km.add(phone:sub(1, 2) .. _trigger, phone, phone_opts)
			_km.add("+33" .. phone:sub(1, 2), "+33" .. phone, phone_opts)
		end
		if #phone >= 4 then
			_km.add(phone:sub(1, 4), phone, phone_opts)
			_km.add("+33" .. phone:sub(2, 4), "+33" .. phone, phone_opts)
		end
		if #phone >= 6 then
			_km.add(phone:sub(2, 5), phone, phone_opts)
		end
		if #fphone >= 5 then
			_km.add(fphone:sub(1, 5), fphone, fphone_opts)
		end
	end

	-- Register SSN prefixes: no-space trigger → SSN without spaces; spaced → SSN with spaces
	if _km.is_section_enabled and _km.is_section_enabled(GROUP_NAME, "ssnprefixes") then
		if #ssn_raw >= 5 then
			local ssn_raw_pfx    = ssn_raw:sub(1, 5)
			local ssn_spaced_pfx = SharedEngine.spaced_prefix(ssn, 5)
			local ssn_opts       = opts_for("social_security_number")
			_km.add(ssn_raw_pfx, ssn_raw, ssn_opts)
			if ssn_spaced_pfx ~= ssn_raw_pfx then
				_km.add(ssn_spaced_pfx, ssn, ssn_opts)
			end
		end
	end

	-- Register IBAN prefixes: 6 raw chars (case-insensitive) → IBAN without spaces;
	-- 7-char spaced trigger (e.g. "FR76 XX") → IBAN with spaces.
	if _km.is_section_enabled and _km.is_section_enabled(GROUP_NAME, "ibanprefixes") then
		if #iban_raw >= 6 then
			local iban_raw_pfx    = iban_raw:sub(1, 6)
			local iban_spaced_pfx = SharedEngine.spaced_prefix(iban, 6)
			-- is_private for the same reason as `base_opts` above: the IBAN and its
			-- 6-char prefix trigger are both secret
			local opts_ci = opts_for("iban", { is_case_sensitive = false })
			_km.add(iban_raw_pfx,    iban:gsub("%s+", ""), opts_ci)
			if iban_spaced_pfx ~= iban_raw_pfx then
				_km.add(iban_spaced_pfx, iban, opts_ci)
			end
		end
	end

	if _km.set_group_context then _km.set_group_context(nil) end
	if _km.sort_mappings then _km.sort_mappings() end
	Logger.info(LOG, "Prefix-based dynamic hotstrings registered.")
end





-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================

--- Adds a custom interceptor rule — delegated to the shared engine.
--- @param suffix string The string sequence that must immediately precede the trigger character.
--- @param section string The UI section name linking this rule to a toggleable menu item.
--- @param resolver function A callback function that returns the string to insert.
function M.add_rule(suffix, section, resolver)
	SharedEngine.add_rule(suffix, section, resolver)
end

--- Internal method used by init.lua to inject personal data into the engine.
--- @param personal_data table Dictionary containing personal information.
--- @param trigger_char string The global trigger character to apply.
function M.inject_data(personal_data, trigger_char)
	_personal_data = type(personal_data) == "table" and personal_data or {}
	if type(trigger_char) == "string" and trigger_char ~= "" then _trigger = trigger_char end
	register_prefix_entries()
end

--- Live-updates the trigger character the interceptor listens for.
--- Called from menu_state.lua's sync_state_to_modules alongside the existing
--- keymap/hotstring_editor trigger-char calls, so a magic-key change made via
--- the menu reaches this engine without requiring a full reload (F-HIGH-8 fix:
--- previously this engine only ever saw the value captured once at boot from
--- personal_info.toml's own independent default, orphaning every date/prefix
--- rule the moment a user customized the magic key).
--- @param char string The new trigger character (must be a non-empty string).
function M.set_trigger_char(char)
	if type(char) ~= "string" or char == "" then
		Logger.warn(LOG, "set_trigger_char: received an invalid value ('%s') — ignored.", tostring(char))
		return
	end
	_trigger = char
	Logger.debug(LOG, "Trigger char: '%s'.", char)
end

--- Initializes the engine, wiring it into the keymap engine.
--- @param keymap_module table The active keymap module reference.
function M.start(keymap_module)
	Logger.debug(LOG, "Starting dynamic rules engine…")
	if type(keymap_module) ~= "table" then
		Logger.error(LOG, "Keymap module missing, rules engine aborted.")
		return
	end
	_km = keymap_module

	-- Register date rules via shared engine so both HS and Linux produce identical expansions
	SharedEngine.register_date_rules(_trigger)

	local dates = SharedEngine.today_date_strings()

	-- Descriptions show today's date so the user can immediately see the expected output.
	local function loc(key) return locale and locale.get(key) or "" end
	local desc_datefr = loc("dynamichotstrings.datefr")
	if desc_datefr == "" then desc_datefr = "dt" .. _trigger .. " inserts current date ({date})" end
	desc_datefr = desc_datefr:gsub("{date}", text_utils.escape_gsub_replacement(dates.fr))
	local desc_datelongfr = loc("dynamichotstrings.datelongfr")
	if desc_datelongfr == "" then desc_datelongfr = "date" .. _trigger .. " inserts long date ({date})" end
	desc_datelongfr = desc_datelongfr:gsub("{date}", text_utils.escape_gsub_replacement(dates.long_fr))
	local desc_date = loc("dynamichotstrings.date")
	if desc_date == "" then desc_date = "td" .. _trigger .. " inserts current date ({date})" end
	desc_date = desc_date:gsub("{date}", text_utils.escape_gsub_replacement(dates.iso))

	-- Sections ordered identically to the AHK DynamicHotstrings feature map.
	-- Prefix section counts start at 0; register_prefix_entries updates them with
	-- the real values once personal data is injected.
	-- textexpansionpersonalinformation is a module placeholder — resolved by the menu via _index.toml.
	-- textexpansionpersonalinformation is last, separated — mirrors AHK DynamicHotstrings layout.
	-- Descriptions come from lib.locale (static/locales/fr.json) so the JSON
	-- is the single source of truth shared with the AHK driver.
	_sections = {
		{ name = "datelongfr",    description = desc_datelongfr,                            count = 1 },
		{ name = "datefr",        description = desc_datefr,                                count = 1 },
		{ name = "date",          description = desc_date,                                  count = 1 },
		{ name = "phoneprefixes", description = loc("dynamichotstrings.phoneprefixes"),     count = 0 },
		{ name = "ssnprefixes",   description = loc("dynamichotstrings.ssnprefixes"),       count = 0 },
		{ name = "ibanprefixes",  description = loc("dynamichotstrings.ibanprefixes"),      count = 0 },
		{ name = "-" },
		{ name = "textexpansionpersonalinformation", count = 0, is_module_placeholder = true },
	}

	if _km.register_lua_group then
		_km.register_lua_group(GROUP_NAME, loc("dynamichotstrings.group_label"), _sections)
	end

	-- Register the phone/SSN/IBAN prefix hotstrings NOW that _km is wired. This
	-- must NOT rely on the post_load_hook below: register_lua_group already marks
	-- the group enabled, and on a default boot menu_state applies group state
	-- delta-only, so enable_group("dynamichotstrings") early-returns as a no-op
	-- and the hook never fires — leaving every prefix mapping unregistered. The
	-- direct call here is the single guaranteed registration; the hook still
	-- covers a later disable→re-enable cycle. inject_data() set _personal_data
	-- before start() ran, so the data is available here.
	register_prefix_entries()

	if _km.set_post_load_hook then
		_km.set_post_load_hook(GROUP_NAME, function()
			register_prefix_entries()
		end)
	end

	if _km.register_interceptor then
		_km.register_interceptor(interceptor)
	end

	-- Register preview provider — delegates matching to the shared engine.
	-- Also gate on the group master so preview is suppressed when the group is
	-- disabled (symmetric to the interceptor gate above, M-9).
	if type(_km.register_preview_provider) == "function" then
		local is_sec_enabled = _km.is_section_enabled
		local guard = is_sec_enabled
			and function(grp, sec) return is_sec_enabled(grp, sec) end
			or nil
		_km.register_preview_provider(function(buf)
			if type(_km.is_group_enabled) == "function" and not _km.is_group_enabled(GROUP_NAME) then
				return nil
			end
			return SharedEngine.preview(buf, GROUP_NAME, guard)
		end)
	end

	Logger.info(LOG, "Dynamic rules engine started successfully.")
end

--- Stops the engine and cleans up shared state.
function M.stop()
	-- Clear the date rules registered at start time; without this, a subsequent
	-- start() call would call register_date_rules() again and duplicate all three
	-- rules in the shared engine (dynhotstrings-5).
	SharedEngine.reset_rules()
	_km = nil
end

return M
