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
local Terminators = require("keymap.terminators")
local SyntheticInput = require("adapters.synthetic_input")
local HidDiagnosticMailbox = require("modules.diagnostics.hid_diagnostic_mailbox")

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
-- A mutable resolver must run once for a visibly committed action. This
-- snapshot binds its exact result to the bridge's opaque tooltip lease.
local _preview_snapshot = nil
-- Mutable section list kept as an upvalue so register_prefix_entries can
-- update the real counts after personal data is injected.
local _sections       = nil
-- Callback registries do not expose an inverse operation. Every published
-- closure therefore carries one start token and remains inert until that exact
-- generation commits; a failed generation can never revive on a later retry.
local _active_start_token = nil
local _starting_token     = nil

--- Calls a historically void keymap API while honoring an explicit refusal.
--- Nil remains success because the production registration APIs return no value.
--- @param label string Diagnostic step name.
--- @param fn function Keymap operation.
--- @param ... any Operation arguments.
--- @return any result Raw successful result.
local function require_void_commit(label, fn, ...)
	if type(fn) ~= "function" then
		error(label .. " capability is unavailable", 0)
	end
	local result = fn(...)
	if result == false then
		error(label .. " explicitly refused commitment", 0)
	end
	return result
end

--- Captures the shared rules owned before a prospective start.
--- @return table[] snapshot
local function snapshot_shared_rules()
	local snapshot = {}
	for index, rule in ipairs(SharedEngine.get_rules()) do
		snapshot[index] = {
			suffix = rule.suffix,
			section = rule.section,
			resolver = rule.resolver,
		}
	end
	return snapshot
end

--- Restores the shared rule set after a failed prospective start.
--- @param snapshot table[] Previously owned rules.
local function restore_shared_rules(snapshot)
	SharedEngine.reset_rules()
	for _, rule in ipairs(snapshot) do
		SharedEngine.add_rule(rule.suffix, rule.section, rule.resolver)
	end
end

--- Reports one failed start step without letting its exception escape.
--- @param label string Diagnostic step name.
--- @param operation function Protected operation.
--- @return boolean committed
--- @return any result
local function run_start_step(label, operation)
	local ok, result = xpcall(operation, debug.traceback)
	if ok and result ~= false then return true, result end
	Logger.error(LOG, "Rules-engine start step '%s' failed "
		.. "(callback content withheld; terminal type: %s).", label, type(result))
	return false, result
end

--- Tests whether a callback belongs to the sole committed start generation.
--- @param token table Prospective generation token.
--- @param keymap table Keymap captured when the callback was registered.
--- @return boolean active
local function owns_active_start(token, keymap)
	return _active_start_token == token and _km == keymap
end

--- Restores every RulesEngine-owned state field after start failure.
--- @param token table Failed generation token.
--- @param rules_snapshot table[] Pre-start shared rules.
--- @param sections_snapshot table|nil Pre-start menu sections.
--- @param reason string Failure context.
--- @return boolean false
local function rollback_start(token, rules_snapshot, sections_snapshot, reason)
	if (_starting_token ~= nil and _starting_token ~= token)
		or (_active_start_token ~= nil and _active_start_token ~= token)
	then
		Logger.error(LOG, "Stale rules-engine start failed after ownership moved: %s.", tostring(reason))
		return false
	end
	_starting_token = nil
	_active_start_token = nil
	_preview_snapshot = nil
	_sections = sections_snapshot
	_km = nil
	restore_shared_rules(rules_snapshot)
	if type(SharedEngine.set_resolver_error_reporter) == "function" then
		local reporter_ok, reporter_cleared = pcall(SharedEngine.set_resolver_error_reporter, nil)
		if not reporter_ok or reporter_cleared ~= true then
			Logger.error(LOG, "Dynamic rules engine rollback could not clear its resolver reporter.")
		end
	end
	Logger.error(LOG, "Dynamic rules engine start rolled back after %s.", tostring(reason))
	return false
end

--- Defers shared-resolver diagnostics beyond the key event callback.
--- @param rule table Shared rule record.
--- @return boolean owned True after privacy-safe metadata entered the mailbox.
local function report_resolver_failure(rule)
	return HidDiagnosticMailbox.report_resolver_failure(rule)
end

--- Revokes the prospective value and any committed row before semantics change.
--- @param reason string Stable diagnostic context.
--- @return boolean committed True only when mutation may proceed.
local function invalidate_preview_snapshot(reason)
	if not _km then
		_preview_snapshot = nil
		return true
	end
	if type(_km.invalidate_hotstring_preview) ~= "function" then
		Logger.error(LOG, "%s could not revoke the dynamic preview: keymap fence is unavailable.", reason)
		return false
	end
	local ok, committed = xpcall(_km.invalidate_hotstring_preview, debug.traceback)
	if not ok or committed ~= true then
		Logger.error(LOG, "%s could not revoke the dynamic preview (details withheld).", reason)
		return false
	end
	_preview_snapshot = nil
	return true
end





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
	if flags.cmd or flags.ctrl then
		_preview_snapshot = nil
		return nil
	end

	local char = (ctx and ctx.chars) or event:getCharacters(false) or ""
	if not Terminators.matches_magic_event(char, _trigger) then
		_preview_snapshot = nil
		return nil
	end

	-- Gate on the group master toggle so that disabling the dynamichotstrings group
	-- (or "Disable all hotstrings") stops date expansion even though date rules are
	-- matched through the interceptor rather than registry mappings (M-9).
	if type(_km.is_group_enabled) == "function" and not _km.is_group_enabled(GROUP_NAME) then
		_preview_snapshot = nil
		return nil
	end

	local is_sec_enabled = _km.is_section_enabled
	local guard = is_sec_enabled
		and function(grp, sec) return is_sec_enabled(grp, sec) end
		or nil

	local buffer = km_buffer or ""
	local snapshot = _preview_snapshot
	_preview_snapshot = nil -- every action identity is single-use
	local match = nil
	if snapshot and snapshot.buffer == buffer and snapshot.trigger == _trigger then
		local section_live = not guard or guard(GROUP_NAME, snapshot.match.rule.section)
		local lease_ok = false
		if section_live and type(_km.owns_visible_magic_action) == "function" then
			local ok_lease, owns = pcall(_km.owns_visible_magic_action, snapshot.token, buffer)
			if not ok_lease then
				Logger.error(LOG, "Dynamic preview lease check failed: %s.", tostring(owns))
			else
				lease_ok = owns == true
			end
		end
		if lease_ok then match = snapshot.match end
	end
	if not match then match = SharedEngine.match_buffer(buffer, GROUP_NAME, guard) end
	if not match then return nil end

	local rule   = match.rule
	local result = match.result
	local n_back = #rule.suffix

	Logger.debug(LOG, "Injecting dynamic rule for suffix '%s'…", rule.suffix)

	-- inject_dynamic routes the whole replacement through one immutable-tagged
	-- keymap transaction; the fallback below must preserve that same ownership.
	-- We do NOT call keylogger.log_hotstring here: the result may contain private
	-- data (phone number, SSN, IBAN) whose plaintext must never reach the log.
	_is_injecting = true

	local ok, err = pcall(function()
		if _km and type(_km.inject_dynamic) == "function" then
			local injected = _km.inject_dynamic(n_back, result, function()
				if km_utils and type(km_utils.emit_text) == "function" then
					return km_utils.emit_text(result)
				else
					assert(SyntheticInput.emit_key_strokes(result),
						"dynamic fallback text could not be dispatched")
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
			assert(injected == true,
				"keymap rejected the dynamic replacement transaction")
		else
			-- The fallback still needs the keymap-owned replacement transaction;
			-- independent action tags would return to keymap as user input.
			if not _km or type(_km.arm_synthetic) ~= "function"
					or type(_km.with_synthetic_transaction) ~= "function"
					or type(_km.finish_synthetic) ~= "function"
					or type(_km.cancel_synthetic) ~= "function" then
				error("dynamic fallback requires the keymap synthetic-transaction API", 0)
			end
			if type(_km.suppress_rescan) == "function" then _km.suppress_rescan() end
			local transaction = _km.arm_synthetic(n_back, result)
			if keylogger and type(keylogger.notify_synthetic) == "function" then
				-- Same privacy contract as the primary path above — this branch
				-- reaches the identical sink, so it needs the identical flag.
				pcall(keylogger.notify_synthetic, result, "hotstring", n_back, "dynamic", nil, true)
			end
			local ok_emit, emit_err = pcall(_km.with_synthetic_transaction, transaction, function()
				for _ = 1, n_back do
					assert(SyntheticInput.emit_key_stroke({}, "delete", 0),
						"dynamic fallback Backspace could not be dispatched")
				end
				if km_utils and type(km_utils.emit_text) == "function" then
					km_utils.emit_text(result)
				else
					assert(SyntheticInput.emit_key_strokes(result),
						"dynamic fallback text could not be dispatched")
				end
			end)
			-- A throwing emitter may already have built a Backspace prefix in the
			-- ambient callback collector. Seal only a complete producer; cancellation
			-- removes that prefix so passing the physical trigger through cannot also
			-- erase user text.
			local close = ok_emit and _km.finish_synthetic or _km.cancel_synthetic
			local ok_close, close_err = pcall(close, transaction)
			if not ok_close then
				error(string.format("dynamic fallback transaction close failed: %s (emission: %s)",
					tostring(close_err), ok_emit and "ok" or tostring(emit_err)), 0)
			end
			if not ok_emit then error(emit_err, 0) end
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

	return ok and "consume" or nil
end

--- Resolves the exact dynamic action advertised by the keymap tooltip.
--- @param buf string Current keymap buffer.
--- @return string|nil result
--- @return table|nil token
local function preview_provider(buf)
	_preview_snapshot = nil
	if type(_km.is_group_enabled) == "function" and not _km.is_group_enabled(GROUP_NAME) then
		return nil
	end
	local is_sec_enabled = _km.is_section_enabled
	local guard = is_sec_enabled
		and function(grp, sec) return is_sec_enabled(grp, sec) end
		or nil
	local match = SharedEngine.match_buffer(buf, GROUP_NAME, guard)
	if not match then return nil end
	local token = {}
	_preview_snapshot = {
		buffer = buf,
		trigger = _trigger,
		match = match,
		token = token,
	}
	return match.result, token
end





-- ============================================
-- ============================================
-- ======= 3/ Data-Dependent Expansions =======
-- ============================================
-- ============================================

--- Generates and registers all prefix-based hotstrings based on the user's personal data.
local function register_prefix_entries()
	if type(_personal_data) ~= "table" then return true end
	if not _km then
		-- Personal data is present but the keymap is not wired yet. This happens
		-- when inject_data() runs BEFORE start() (the production order), so the
		-- Registration is deferred to M.start(), which calls us again once _km is
		-- set. This is the normal production order; M.start() verifies the keymap
		-- was actually wired before registering any prefix expansion.
		Logger.debug(LOG, "Personal data received before keymap wiring; prefix registration deferred to M.start().")
		return true
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

	require_void_commit("group-context registration", _km.set_group_context, GROUP_NAME)
	local function add_mapping(trigger, replacement, options)
		require_void_commit("prefix mapping registration", _km.add,
			trigger, replacement, options)
	end

	local registered, registration_error = xpcall(function()
		-- Register phone prefixes
		if _km.is_section_enabled and _km.is_section_enabled(GROUP_NAME, "phoneprefixes") then
			-- Two DIFFERENT fields in one block: every entry below expands to the raw
			-- number except the last, which expands to the spaced variant.
			local phone_opts  = opts_for("phone_number")
			local phone_magic_opts = opts_for("phone_number", { is_magic_trigger = true })
			local fphone_opts = opts_for("phone_number_clean")
			if #phone >= 2 then
				add_mapping(phone:sub(1, 2) .. _trigger, phone, phone_magic_opts)
				add_mapping("+33" .. phone:sub(1, 2), "+33" .. phone, phone_opts)
			end
			if #phone >= 4 then
				add_mapping(phone:sub(1, 4), phone, phone_opts)
				add_mapping("+33" .. phone:sub(2, 4), "+33" .. phone, phone_opts)
			end
			if #phone >= 6 then
				add_mapping(phone:sub(2, 5), phone, phone_opts)
			end
			if #fphone >= 5 then
				add_mapping(fphone:sub(1, 5), fphone, fphone_opts)
			end
		end

		-- Register SSN prefixes: no-space trigger → SSN without spaces; spaced → SSN with spaces
		if _km.is_section_enabled and _km.is_section_enabled(GROUP_NAME, "ssnprefixes") then
			if #ssn_raw >= 5 then
				local ssn_raw_pfx    = ssn_raw:sub(1, 5)
				local ssn_spaced_pfx = SharedEngine.spaced_prefix(ssn, 5)
				local ssn_opts       = opts_for("social_security_number")
				add_mapping(ssn_raw_pfx, ssn_raw, ssn_opts)
				if ssn_spaced_pfx ~= ssn_raw_pfx then
					add_mapping(ssn_spaced_pfx, ssn, ssn_opts)
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
				add_mapping(iban_raw_pfx, iban:gsub("%s+", ""), opts_ci)
				if iban_spaced_pfx ~= iban_raw_pfx then
					add_mapping(iban_spaced_pfx, iban, opts_ci)
				end
			end
		end

		require_void_commit("prefix mapping sort", _km.sort_mappings)
		return true
	end, debug.traceback)
	local context_reset, context_error = xpcall(function()
		require_void_commit("group-context reset", _km.set_group_context, nil)
	end, debug.traceback)
	if not registered then error(registration_error, 0) end
	if not context_reset then error(context_error, 0) end
	Logger.info(LOG, "Prefix-based dynamic hotstrings registered.")
	return true
end

--- Builds the menu metadata without publishing it into the keymap registry.
--- @return table[] sections
local function build_sections()
	local dates = SharedEngine.today_date_strings()
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

	return {
		{ name = "datelongfr", description = desc_datelongfr, count = 1 },
		{ name = "datefr", description = desc_datefr, count = 1 },
		{ name = "date", description = desc_date, count = 1 },
		{ name = "phoneprefixes", description = loc("dynamichotstrings.phoneprefixes"), count = 0 },
		{ name = "ssnprefixes", description = loc("dynamichotstrings.ssnprefixes"), count = 0 },
		{ name = "ibanprefixes", description = loc("dynamichotstrings.ibanprefixes"), count = 0 },
		{ name = "-" },
		{ name = "textexpansionpersonalinformation", count = 0, is_module_placeholder = true },
	}
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
	if not invalidate_preview_snapshot("Rule registration") then return false end
	SharedEngine.add_rule(suffix, section, resolver)
	return true
end

--- Internal method used by init.lua to inject personal data into the engine.
--- @param personal_data table Dictionary containing personal information.
--- @param trigger_char string The global trigger character to apply.
function M.inject_data(personal_data, trigger_char)
	if not invalidate_preview_snapshot("Personal-data update") then return false end
	_personal_data = type(personal_data) == "table" and personal_data or {}
	if type(trigger_char) == "string" and trigger_char ~= "" then _trigger = trigger_char end
	local ok, committed = xpcall(register_prefix_entries, debug.traceback)
	if not ok or committed ~= true then
		Logger.error(LOG, "Personal-data prefix registration failed (details withheld; terminal type: %s).",
			type(committed))
		return false
	end
	return true
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
		return false
	end
	if not invalidate_preview_snapshot("Trigger-key update") then return false end
	_trigger = char
	Logger.debug(LOG, "Trigger char: '%s'.", char)
	return true
end

--- Initializes the engine, wiring it into the keymap engine.
--- @param keymap_module table The active keymap module reference.
function M.start(keymap_module)
	Logger.debug(LOG, "Starting dynamic rules engine…")
	if type(keymap_module) ~= "table" then
		Logger.error(LOG, "Keymap module missing, rules engine aborted.")
		return false
	end
	if type(keymap_module.registry_transaction) ~= "function" then
		Logger.error(LOG, "Keymap registry transaction missing, rules engine aborted.")
		return false
	end
	if _active_start_token then
		if _km == keymap_module then
			Logger.debug(LOG, "Dynamic rules engine already started with this keymap.")
			return true
		end
		Logger.error(LOG, "Dynamic rules engine already owns a different keymap — "
			.. "stop it before replacement (callback content withheld).")
		return false
	end
	if _starting_token then
		Logger.error(LOG, "Dynamic rules engine start refused because another start is in progress.")
		return false
	end
	if not invalidate_preview_snapshot("Rules-engine start") then return false end

	local token = {}
	local rules_snapshot = snapshot_shared_rules()
	local sections_snapshot = _sections
	_starting_token = token
	_km = keymap_module
	_preview_snapshot = nil

	-- The keymap exposes no unregister operation for these callback arrays. Stage
	-- token-gated closures before any registry write; even a registrar that
	-- appends and then reports failure can leave behind only a permanently inert
	-- closure.
	local interceptor_ok = run_start_step("interceptor registration", function()
		return require_void_commit("interceptor registration", _km.register_interceptor,
			function(...)
				if not owns_active_start(token, keymap_module) then return nil end
				return interceptor(...)
			end)
	end)
	if not interceptor_ok then
		return rollback_start(token, rules_snapshot, sections_snapshot, "interceptor registration")
	end

	local provider_ok = run_start_step("preview-provider registration", function()
		return require_void_commit("preview-provider registration", _km.register_preview_provider,
			function(buf)
				if not owns_active_start(token, keymap_module) then return nil end
				return preview_provider(buf)
			end)
	end)
	if not provider_ok then
		return rollback_start(token, rules_snapshot, sections_snapshot, "preview-provider registration")
	end

	local rules_ok = run_start_step("shared date-rule registration", function()
		require_void_commit("shared date-rule registration", SharedEngine.register_date_rules, _trigger)
		return true
	end)
	if not rules_ok then
		return rollback_start(token, rules_snapshot, sections_snapshot, "shared date-rule registration")
	end

	local sections_ok, prospective_sections = run_start_step("section metadata preparation", build_sections)
	if not sections_ok or type(prospective_sections) ~= "table" then
		return rollback_start(token, rules_snapshot, sections_snapshot, "section metadata preparation")
	end
	_sections = prospective_sections

	-- Sections are ordered identically to the AHK DynamicHotstrings feature map.
	-- Prefix registration runs directly at start because the default enabled-group
	-- path deliberately does not invoke the post-load hook.
	local function publish_registry_state()
		local group_label = locale and locale.get("dynamichotstrings.group_label") or ""
		require_void_commit("dynamic group registration", _km.register_lua_group,
			GROUP_NAME, group_label, _sections)
		register_prefix_entries()
		require_void_commit("dynamic post-load hook registration", _km.set_post_load_hook,
			GROUP_NAME, function()
				if not owns_active_start(token, keymap_module) then return true end
				return register_prefix_entries()
			end)
		if type(SharedEngine.set_resolver_error_reporter) ~= "function"
			or SharedEngine.set_resolver_error_reporter(report_resolver_failure) ~= true
		then
			error("shared resolver error reporter did not commit", 0)
		end
		if _starting_token ~= token or _km ~= keymap_module then
			error("prospective rules-engine ownership became stale", 0)
		end
		_active_start_token = token
		_starting_token = nil
		return true
	end

	local registry_ok = run_start_step("keymap registry transaction", function()
		local committed = _km.registry_transaction("dynamic_rules_start", publish_registry_state)
		if committed ~= true then error("keymap registry transaction did not commit", 0) end
		return true
	end)
	if not registry_ok then
		return rollback_start(token, rules_snapshot, sections_snapshot, "keymap registry transaction")
	end

	if _active_start_token ~= token or _starting_token ~= nil or _km ~= keymap_module then
		return rollback_start(token, rules_snapshot, sections_snapshot, "final ownership verification")
	end

	Logger.info(LOG, "Dynamic rules engine started successfully.")
	return true
end

--- Stops the engine and cleans up shared state.
function M.stop()
	-- Clear the date rules registered at start time; without this, a subsequent
	-- start() call would call register_date_rules() again and duplicate all three
	-- rules in the shared engine (dynhotstrings-5).
	-- Teardown must fail closed even if native pixels cannot be revoked: leaving
	-- an interceptor live after pause/quit is worse than a stale surface that the
	-- outer tooltip teardown can retry. Return the revocation result to the owner.
	_active_start_token = nil
	_starting_token = nil
	local revoked = invalidate_preview_snapshot("Rules-engine stop")
	_preview_snapshot = nil
	SharedEngine.reset_rules()
	local reporter_cleared = SharedEngine.set_resolver_error_reporter(nil) == true
	_sections = nil
	_km = nil
	return revoked and reporter_cleared
end

return M
