--- modules/dynamic_hotstrings/personal_info.lua

--- ==============================================================================
--- MODULE: Personal Info Tracker
--- DESCRIPTION:
--- Monitors typed characters and expands  @<letters><trigger>  into
--- tab-separated personal-information values.
---
--- FEATURES & RATIONALE:
--- 1. Single Tap Integration: Registers an interceptor directly inside keymap's keyDown tap.
--- 2. Conflict Avoidance: Runs BEFORE backspace, escape, and hotstring matching.
--- ==============================================================================

local M = {}

local hs       = hs
local Logger   = require("infra.logger")
local SyntheticInput = require("adapters.synthetic_input")
local Terminators = require("keymap.terminators")
local LOG      = "personal_info"

-- Safely require the UI editor module to prevent crashes
local ok_editor, ui_editor = pcall(require, "ui.personal_info_editor")
if not ok_editor then ui_editor = nil end

local ok_kl, keylogger = pcall(require, "modules.keylogger")
if not ok_kl then keylogger = nil end

-- The shared personal-info field classification, used ONLY by the preview
-- provider below. Optional-require rather than a hard dependency so a driver
-- shipped without the shared tree still expands correctly — the provider then
-- withholds instead, which is the safe direction.
local ok_fields, personal_info_fields = pcall(require, "infra.personal_info_fields")
if not ok_fields then personal_info_fields = nil end





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local STATE_IDLE       = "idle"
local STATE_COLLECTING = "collecting"

local _enabled   = false
local _replacing = false
local _state     = STATE_IDLE
local _combo     = ""

local _trigger         = "★"
local _info            = {}
local _letters         = {}
local _base_dir        = ""
local _info_toml_path  = ""

local _keymap    = nil
local _active_start_token = nil
local _starting_token = nil
local ManifestReader = require("infra.manifest_reader")

-- The magic key as declared in the shared feature manifest. Named once here so
-- the three sites below cannot drift apart from each other or from the manifest.
local DEFAULT_TRIGGER = ManifestReader.default_for("hotstrings.trigger_char")

-- Same-directory staging keeps the final rename atomic on macOS
local SAVE_TEMP_SUFFIX = ".ergopti-save.tmp"

-- Width of the placeholder a preview part falls back to when the shared field
-- classification cannot be reached. Fixed rather than the value's own length:
-- how long a secret is, is itself a hint about which one it is.
local UNCLASSIFIED_PREVIEW_BULLETS = 8

--- Registers one append-only keymap callback as part of a prospective start.
--- @param label string Stable diagnostic label.
--- @param registrar function Keymap registration function.
--- @param callback function Token-gated callback to publish.
--- @return boolean committed
local function register_start_callback(label, registrar, callback)
	if type(registrar) ~= "function" then
		Logger.error(LOG, "Personal-info start requires keymap.%s.", label)
		return false
	end
	local ok, result = xpcall(function() return registrar(callback) end, debug.traceback)
	if ok and result ~= false then return true end
	Logger.error(LOG, "Personal-info %s failed (callback content withheld; terminal type: %s).",
		label, type(result))
	return false
end

--- Invalidates every callback published by an uncommitted start generation.
--- @param token table Prospective generation token.
--- @param reason string Failure context.
--- @return boolean false
local function rollback_start(token, reason)
	if _starting_token == token or _active_start_token == token then
		_starting_token = nil
		_active_start_token = nil
		_enabled = false
		_replacing = false
		_state = STATE_IDLE
		_combo = ""
		_keymap = nil
	end
	Logger.error(LOG, "Personal info tracker start rolled back after %s.", tostring(reason))
	return false
end

local DEFAULT_CONFIG = {
	-- Read from the shared manifest rather than restated: a second copy of the
	-- magic key is a second thing to change when the user picks another one.
	trigger_char = ManifestReader.default_for("hotstrings.trigger_char"),
	info = {
		first_name            = "Prénom",
		last_name             = "Nom",
		date_of_birth         = "01/01/1990",
		email_address         = "prenom.nom@exemple.fr",
		work_email_address    = "prenom.nom@entreprise.fr",
		phone_number          = "0600000000",
		phone_number_clean    = "06 00 00 00 00",
		street_address        = "1 Rue de la Paix",
		city                  = "Paris",
		country               = "France",
		postal_code           = "75001",
		iban                  = "FR00 0000 0000 0000 0000 0000 000",
		bic                   = "ABCDFRPP",
		credit_card           = "0000 0000 0000 0000",
		social_security_number = "0 00 00 00 000 000 00",
	},
	letters = {
		a = "street_address",
		b = "bic",
		c = "credit_card",
		d = "date_of_birth",
		e = "email_address",
		f = "phone_number_clean",
		i = "iban",
		m = "email_address",
		n = "last_name",
		p = "first_name",
		s = "social_security_number",
		t = "phone_number",
		w = "work_email_address",
	},
}





-- ===========================================
-- ===========================================
-- ======= 2/ Configuration Management =======
-- ===========================================
-- ===========================================

--- Parses a simple key = "value" TOML section block into a table.
--- @param content string Full file content.
--- @param section string Section name (without brackets).
--- @return table
local function parse_toml_section(content, section)
	local result = {}
	-- Find the section header, then collect lines until the next header
	local in_section = false
	for raw_line in (content .. "\n"):gmatch("([^\n]*)\n") do
		local line = raw_line:match("^%s*(.-)%s*$")
		if line:match("^%[") then
			in_section = (line == "[" .. section .. "]")
		elseif in_section then
			-- %w alone excludes '_', which silently dropped every underscore-named
			-- key (date_of_birth, phone_number, social_security_number, …) back to
			-- DEFAULT_CONFIG on every restart; match the sibling parser's class.
			local key, val = line:match('^([%w_%-]+)%s*=%s*"(.*)"$')
			if key then
				-- Single-pass unescape: process \\(.) left-to-right so \\n is correctly
			-- decoded as backslash+n, not as newline (the chained-gsub bug corrupted
			-- \\n because \n was replaced before \\  was resolved)
			val = val:gsub('\\(.)', function(c)
					return ({n="\n", t="\t", ['"']='"', ['\\']='\\'})[c] or ('\\'..c)
				end)
				result[key] = val
			end
		end
	end
	return result
end

--- Escapes a string for a TOML double-quoted value.
--- @param s string
--- @return string
local function escape_toml(s)
	s = s:gsub("\\", "\\\\")
	s = s:gsub('"',  '\\"')
	s = s:gsub("\n", "\\n")
	s = s:gsub("\t", "\\t")
	return s
end

--- Builds an isolated candidate without publishing partial edits to live consumers.
--- @param new_info table Updated personal-information fields.
--- @return table candidate Complete candidate table.
local function build_info_candidate(new_info)
	local candidate = {}
	for key, value in pairs(_info) do candidate[key] = value end
	for key, value in pairs(new_info) do candidate[key] = value end
	return candidate
end

--- Serializes one complete personal-information candidate.
--- @param candidate table Complete personal-information table.
--- @return string content TOML payload.
local function serialize_config(candidate)
	local lines = {
		"# personal_info.toml — Personal information",
		"# Auto-managed by the personal information editor.",
		"# Do not edit manually unless you know what you are doing.",
		"",
		"[info]",
	}
	for key, value in pairs(candidate) do
		lines[#lines + 1] = key .. " = \"" .. escape_toml(tostring(value)) .. "\""
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "[letters]"
	for key, value in pairs(_letters) do
		lines[#lines + 1] = key .. " = \"" .. escape_toml(tostring(value)) .. "\""
	end
	lines[#lines + 1] = ""
	return table.concat(lines, "\n")
end

--- Revokes any visible or prospective preview before its source data changes.
--- @return boolean committed True only when mutation may proceed safely.
local function invalidate_preview_before_save()
	-- The nil case is bootstrap-only: start() materialises a missing file before
	-- registering this module's preview provider, so no visible promise exists.
	if not _keymap then return true end
	if type(_keymap.invalidate_hotstring_preview) ~= "function" then
		Logger.error(LOG, "Personal-info save refused because the keymap preview fence is unavailable.")
		return false
	end
	local ok, committed = xpcall(_keymap.invalidate_hotstring_preview, debug.traceback)
	if not ok or committed ~= true then
		Logger.error(LOG, "Personal-info save refused because preview revocation did not commit "
			.. "(failure content withheld).")
		return false
	end
	return true
end

--- Removes an unpublished staging file and reports cleanup failure.
--- @param staged_path string Staging file path.
local function remove_staged_file(staged_path)
	local ok, removed, remove_err = pcall(os.remove, staged_path)
	if not ok or removed ~= true then
		Logger.warn(LOG, "Could not remove the unpublished personal-info staging file "
			.. "(failure content withheld).")
	end
end

--- Writes and flushes a complete payload to its staging file.
--- @param staged_path string Same-directory staging file path.
--- @param content string Complete TOML payload.
--- @return boolean committed True after write, flush, and close succeed.
local function write_staged_config(staged_path, content)
	local open_ok, file_or_err, open_err = pcall(io.open, staged_path, "wb")
	if not open_ok or not file_or_err then
		Logger.error(LOG, "Cannot open the personal-info staging file (failure content withheld).")
		return false
	end
	local file = file_or_err
	local write_ok, write_committed, write_err = xpcall(function()
		local written, err = file:write(content)
		if not written then return false, err end
		local flushed, flush_err = file:flush()
		if flushed ~= true then return false, flush_err end
		return true
	end, debug.traceback)
	local close_ok, close_committed, close_err = pcall(file.close, file)
	if not write_ok or write_committed ~= true or not close_ok or close_committed ~= true then
		Logger.error(LOG, "Personal-info staging write did not commit (failure content withheld).")
		remove_staged_file(staged_path)
		return false
	end
	return true
end

--- Reads personal_info.toml and returns a config table compatible with DEFAULT_CONFIG.
--- @param toml_path string Absolute path to personal_info.toml.
--- @return table config The loaded or default configuration.
--- @return boolean was_missing True if the file did not exist on disk and defaults were used.
local function load_config(toml_path)
	Logger.debug(LOG, "Loading personal info from '%s'…", toml_path)
	local fh = io.open(toml_path, "r")
	if not fh then
		Logger.info(LOG, "personal_info.toml not found — using default values.")
		return DEFAULT_CONFIG, true
	end
	local content = fh:read("*a")
	fh:close()

	local info    = parse_toml_section(content, "info")
	local letters = parse_toml_section(content, "letters")

	-- Fall back to defaults for any missing field
	local merged_info    = {}
	local merged_letters = {}
	for k, v in pairs(DEFAULT_CONFIG.info) do
		merged_info[k] = info[k] or v
		-- A non-empty parsed section that is still missing a known key almost
		-- always means the parser regex silently rejected that key's line —
		-- warn loudly instead of letting it look like a legitimately-absent key.
		if info[k] == nil and next(info) ~= nil then
			Logger.warn(LOG, "Key '%s' absent from a non-empty [info] section — falling back to default (check for a parser/regex mismatch).", k)
		end
	end
	for k, v in pairs(DEFAULT_CONFIG.letters) do merged_letters[k] = letters[k] or v end

	Logger.info(LOG, "Personal info configuration loaded successfully.")
	return {
		trigger_char = DEFAULT_CONFIG.trigger_char,
		info         = merged_info,
		letters      = merged_letters,
	}, false
end

--- Persists updated info fields through a preview-fenced atomic transaction.
--- @param new_info table The updated fields to save.
--- @return boolean committed True only after disk and live memory commit.
function M.save_info(new_info)
	if type(new_info) ~= "table" then
		Logger.error(LOG, "save_info(): expected a table, got %s — save refused.", type(new_info))
		return false
	end
	if type(_info_toml_path) ~= "string" or _info_toml_path == "" then
		Logger.error(LOG, "save_info() called before the personal-info path was initialized.")
		return false
	end
	Logger.debug(LOG, "Saving personal info to '%s'…", _info_toml_path)

	local candidate = build_info_candidate(new_info)
	local content = serialize_config(candidate)
	if not invalidate_preview_before_save() then return false end

	local staged_path = _info_toml_path .. SAVE_TEMP_SUFFIX
	if not write_staged_config(staged_path, content) then return false end
	local rename_ok, renamed, rename_err = pcall(os.rename, staged_path, _info_toml_path)
	if not rename_ok or renamed ~= true then
		Logger.error(LOG, "Personal-info staged-file publication did not commit "
			.. "(failure content withheld).")
		remove_staged_file(staged_path)
		return false
	end

	-- Preserve the shared table identity held by dependent engines
	for key in pairs(_info) do _info[key] = nil end
	for key, value in pairs(candidate) do _info[key] = value end

	Logger.info(LOG, "Personal info configuration saved successfully.")
	return true
end





-- ====================================
-- ====================================
-- ======= 3/ Engine Operations =======
-- ====================================
-- ====================================

--- Resolves accumulated letters into actual mapped strings.
---
--- Returns the field NAMES alongside the values, in the same order. The values
--- alone are what gets typed, but the preview has to ask the shared declaration
--- how much of each one may appear on screen — and only the letter that produced
--- a part knows which personal_info.toml field it is. Losing that here is what
--- would put an IBAN on screen in full.
--- ALL OR NOTHING. A letter that aliases nothing, or that aliases a field the
--- user left blank, declines the WHOLE combo rather than being skipped.
---
--- This used to skip. The failure it caused is silent and personal: typing "@npz"
--- with a stray "z" expanded as "@np", so the values landed one form field short
--- of where the user was aiming and every later box held the wrong thing — a
--- surname in the address line, and no error anywhere. Nothing happening is
--- merely visibly wrong, which the user corrects in a second.
---
--- Aligned deliberately with Linux (`manager.resolve_combo`) and Windows
--- (`HSE_TryPersonalInfoCombo`), which both refuse. Three drivers answering the
--- same question differently is the divergence the shared corpus exists to end,
--- and this one changes what gets TYPED, not only what is shown.
--- @param combo string Sequence of typed letters.
--- @return table values List of strings resolved from the letters; empty when
---   any letter of the combo cannot be resolved.
--- @return table fields Matching personal_info.toml field names, same indices.
local function resolve_combo(combo)
	local parts  = {}
	local fields = {}
	if type(combo) ~= "string" then return parts, fields end

	for i = 1, #combo do
		local letter = combo:sub(i, i)
		local key    = _letters[letter]
		local value  = key and _info[key] or nil
		if type(value) ~= "string" or value == "" then return {}, {} end
		table.insert(parts, value)
		table.insert(fields, key)
	end
	return parts, fields
end

--- What the preview bubble may show for one resolved part.
---
--- DISPLAY ONLY: do_expand() calls resolve_combo() and injects the values it
--- returns, never this. A mask that reached the injector would type bullets into
--- whatever form the user was filling in.
--- @param value string The resolved value.
--- @param field string|nil The personal_info.toml field it came from.
--- @return string
local function masked_for_preview(value, field)
	if type(value) ~= "string" then return value end
	if not personal_info_fields or type(personal_info_fields.for_preview) ~= "function" then
		-- Fail closed. Every value this provider resolves comes straight out of
		-- personal_info.toml, so an unreachable classifier is precisely the case
		-- where showing the value is the wrong guess.
		Logger.error(LOG, "Field classification unavailable — withholding a personal-info preview.")
		return ("•"):rep(UNCLASSIFIED_PREVIEW_BULLETS)
	end
	return personal_info_fields.for_preview(value, field)
end

--- Performs the actual injection of the requested data.
--- @param combo string Sequence of typed letters corresponding to the data.
--- @return boolean injected True only when the keymap accepted the transaction.
local function do_expand(combo)
	Logger.debug(LOG, "Injecting personal data…")
	local n_back = 1 + #combo
	local parts  = resolve_combo(combo)
	_replacing = true
	-- Two strings serve the historical emitter return contract; neither identifies
	-- an OS event. Immutable transaction tags now provide that provenance.
	-- `emitted` describes the character-producing key sequence: field values plus
	-- each inter-field Tab. It remains compatibility metadata for callers that
	-- inspect physical_echo.
	-- `echoed` is the LOGICAL text: values only, no tab. A Tab moves focus to the
	-- next field, it inserts nothing on screen, so this is what CoreState.buffer
	-- and the keylogger's logical record must hold.
	local emitted = table.concat(parts, "\t")
	local echoed  = table.concat(parts, "")

	local ok, err = pcall(function()
		if _keymap and type(_keymap.inject_dynamic) == "function" then
			local injected = _keymap.inject_dynamic(n_back, echoed, function()
				local c = 0
				local ok_tu, text_utils = pcall(require, "infra.text_utils")
				for i, value in ipairs(parts) do
					assert(SyntheticInput.emit_key_strokes(value),
						"personal-info field could not be dispatched")
					if ok_tu and type(text_utils.utf8_len) == "function" then
						c = c + text_utils.utf8_len(value)
					else
						c = c + #value
					end
					if i < #parts then
						assert(SyntheticInput.emit_key_stroke({}, "tab", 0),
							"personal-info Tab could not be dispatched")
						c = c + 1
					end
				end
				-- Historical (count, physical_echo, logical_text) contract.
				-- physical_echo describes field keydowns and inter-field Tabs for
				-- compatibility only; immutable tags on the emitted events provide
				-- exact ownership and prevent them from being classified as human.
				-- logical_text stays tab-free so the buffer and logical telemetry hold
				-- only text inserted into fields, not focus-navigation keys.
				return c, emitted, echoed
			-- is_private = true: every value this module emits comes from
			-- personal_info.toml, which rules_engine already treats as PII in its
			-- entirety when it registers the same data as mappings. The two paths
			-- must agree — an @-tag expansion of the SSN is exactly as secret as
			-- the prefix-triggered one, and only this argument tells the keylogger
			-- to redact what it persists.
			end, "personal", true)
			assert(injected == true,
				"keymap rejected the personal-info replacement transaction")
		else
			-- The fallback still needs one keymap-owned replacement transaction.
			-- Independent implicit actions would expose its tabs/deletes as user input.
			if not _keymap or type(_keymap.arm_synthetic) ~= "function"
					or type(_keymap.with_synthetic_transaction) ~= "function"
					or type(_keymap.finish_synthetic) ~= "function"
					or type(_keymap.cancel_synthetic) ~= "function" then
				error("personal-info fallback requires the keymap synthetic-transaction API", 0)
			end
			local transaction = _keymap.arm_synthetic(n_back, "")
			if type(_keymap.suppress_rescan) == "function" then _keymap.suppress_rescan() end
			if keylogger and type(keylogger.notify_synthetic) == "function" then
				-- Same privacy contract as the primary path: this branch reaches
				-- the identical sink and must carry the identical flag.
				pcall(keylogger.notify_synthetic, emitted, "hotstring", n_back, "personal", nil, true)
			end
			local ok_emit, emit_err = pcall(_keymap.with_synthetic_transaction, transaction, function()
				for _ = 1, n_back do
					assert(SyntheticInput.emit_key_stroke({}, "delete", 0),
						"personal-info fallback Backspace could not be dispatched")
				end
				for i, value in ipairs(parts) do
					assert(SyntheticInput.emit_key_strokes(value),
						"personal-info fallback field could not be dispatched")
					if i < #parts then
						assert(SyntheticInput.emit_key_stroke({}, "tab", 0),
							"personal-info fallback Tab could not be dispatched")
					end
				end
			end)
			-- Failed multi-field construction may already own deletes, field text and
			-- Tabs. Cancel that whole prefix; sealing it while passing the physical
			-- trigger through would produce a private, partial replacement.
			local close = ok_emit and _keymap.finish_synthetic or _keymap.cancel_synthetic
			local ok_close, close_err = pcall(close, transaction)
			if not ok_close then
				error(string.format("personal-info fallback transaction close failed: %s (emission: %s)",
					tostring(close_err), ok_emit and "ok" or tostring(emit_err)), 0)
			end
			if not ok_emit then error(emit_err, 0) end
		end
	end)

	if not ok then
		Logger.error(LOG, "Personal data injection failed: %s.", tostring(err))
	end

	-- Tagged synthetic events are filtered before interceptors, so ownership can
	-- end with the transaction. A delay here would only hide real physical input.
	_replacing = false
	if ok then Logger.info(LOG, "Personal data injection completed.") end
	return ok
end

--- Returns whether the static registry owns a complete personal-info trigger.
--- Both the interceptor and preview provider use this exact gate so a static
--- `@x<magic>` collision cannot be declined by one and advertised by the other.
--- @param full_trigger string Complete `@` combo including the magic key.
--- @return boolean
local function static_claims_full_trigger(full_trigger)
	if not _keymap or type(_keymap.classify_trigger) ~= "function" then return false end
	return (_keymap.classify_trigger(full_trigger)) == true
end





-- =========================================
-- =========================================
-- ======= 4/ Key Interceptor Engine =======
-- =========================================
-- =========================================

--- Intercepts keystrokes to detect prefix + trigger combinations for dynamic resolution.
--- @param event userdata The Hammerspoon hs.eventtap.event object.
--- @param _km_buffer string The current typing buffer maintained by the keymap module.
--- @return string|nil Returns "consume" to swallow the event, or "suppress" to block hotstrings.
--- @param event userdata The keyDown event.
--- @param _km_buffer string The keymap buffer (unused here).
--- @param ctx table|nil Fields the keymap tap already read from the event
---        (keyCode, flags, chars). Re-fetching them is an ObjC accessor call
---        per interceptor per keystroke; the fallback keeps this working if the
---        contract is ever invoked without a context.
local function interceptor(event, _km_buffer, ctx)
	if not _enabled then return nil end
	if _replacing then return nil end

	local flags = (ctx and ctx.flags) or event:getFlags()
	
	-- Reset state on command or control modifiers
	if flags.cmd or flags.ctrl then
		_state = STATE_IDLE
		_combo = ""
		return nil
	end

	local kc = event:getKeyCode()

	-- Reset state on escape, return, or navigation keys
	if kc == 53 or kc == 36 or kc == 76 or (kc >= 123 and kc <= 126) then
		_state = STATE_IDLE
		_combo = ""
		return nil
	end

	-- Handle backspace during collection
	if kc == 51 then
		if _state == STATE_COLLECTING then
			-- Alt+Backspace deletes an entire word on macOS, so trimming one char
			-- from _combo would leave it out of sync with the actual screen content.
			-- Reset to IDLE so the next @-trigger starts a clean collection.
			if flags.alt then
				_state = STATE_IDLE
				_combo = ""
			elseif #_combo > 0 then
				_combo = _combo:sub(1, -2)
			else
				_state = STATE_IDLE
			end
		end
		return nil
	end

	local char = (ctx and ctx.chars) or event:getCharacters(false) or ""
	if char == "" then return nil end

	if _state == STATE_IDLE then
		if char == "@" then
			local full_trigger = (_km_buffer or "") .. "@"
			if _keymap then
				-- Single-pass and memoised: classify_trigger returns all three flags
				-- from one walk of the corpus, and its answer is cached until the
				-- corpus changes.
				--
				-- There is no fallback. The else branch here used to run
				-- has_exact_trigger, has_trigger_prefix and has_trigger_suffix as three
				-- separate, uncached full scans — and it was unreachable in production,
				-- because keymap always exports classify_trigger. Its only real effect
				-- would have been to hide a partial keymap injection behind a slower
				-- path with different caching, which is the hardcoded behavioural
				-- fallback convention 5.4 forbids.
				local exact, pref, suff = false, false, false
				if type(_keymap.classify_trigger) == "function" then
					exact, pref, suff = _keymap.classify_trigger(full_trigger)
				else
					-- Loud, not silent. Absent means the keymap module was injected
					-- partially, which is a wiring mistake and used to be absorbed by
					-- three slower scans that reported nothing. Collection still proceeds
					-- on the all-false answer, exactly as before, so the diagnostic is
					-- added without changing what the user sees.
					Logger.error(LOG, "keymap.classify_trigger is missing — cannot tell whether "
						.. "'%s' is already claimed by a static hotstring; proceeding as "
						.. "unclaimed.", full_trigger)
				end
				if exact or pref or suff then
					return nil
				end
			end

			_state = STATE_COLLECTING
			_combo = ""
			return nil
		end
		return nil
	end

	if _state == STATE_COLLECTING then
		if Terminators.matches_magic_event(char, _trigger) then
			-- The keymap buffer is the authority on what is actually on screen.
			--
			-- This state machine is fed exclusively from keyDown, so it resets on
			-- modifiers, navigation, backspace and any non-letter — but a MOUSE
			-- CLICK produces no keyDown at all, and neither does a focus change.
			-- The pending combo therefore survived a caret move, and do_expand
			-- sizes its backspaces from #_combo alone: it would erase that many
			-- characters wherever the caret now sits and inject the PII there.
			-- Cross-checking against the buffer makes every unobserved caret move
			-- invalidate the combo by construction, and makes this engine's answer
			-- identical to the preview's, which already derives it from the buffer.
			local buffer = _km_buffer or ""
			if buffer:sub(-(#_combo + 1)) ~= "@" .. _combo then
				Logger.debug(LOG, "Pending @-combo no longer matches the buffer — discarding.")
				_state = STATE_IDLE
				_combo = ""
				return nil
			end
			if #_combo > 0 and #resolve_combo(_combo) > 0 then
				local combo = _combo
				
				local full_trigger = "@" .. combo .. _trigger
				-- Through the memoised classifier, like the @-entry check above.
				-- has_exact_trigger walks the whole mapping corpus and caches nothing,
				-- and this runs on the keystroke that completes a combo - so the same
				-- question was answered by a full scan here and from cache there.
				-- classify_trigger returns all three flags; only `exact` matters at this
				-- point, because a prefix or suffix match does not claim the trigger.
				local claimed = static_claims_full_trigger(full_trigger)
				if claimed and full_trigger:sub(1, 1) == "@" then
					_state = STATE_IDLE
					_combo = ""
					return nil
				end
				
				_state = STATE_IDLE
				_combo = ""
				
				if do_expand(combo) then return "consume" end
				return nil
			end
			
			_state = STATE_IDLE
			_combo = ""
			return nil
		end

		-- Collect lowercase letters for the combo
		if char:match("^[a-z]$") then
			_combo = _combo .. char
			return nil
		end

		_state = STATE_IDLE
		_combo = ""
		return nil
	end

	return nil
end





-- =============================
-- =============================
-- ======= 5/ Public API =======
-- =============================
-- =============================

--- Retrieves the current personal info table.
--- @return table The info table.
function M.get_info()         return _info    end

--- Seeds the two lookup tables and resolves a combo. TESTS ONLY.
---
--- `resolve_combo` is a local, and the all-or-nothing rule it enforces decides
--- what gets TYPED into a user's form — so it needs a behavioural test rather
--- than a source-grep pinning its current spelling. Linux exposes `_reset` for
--- the same reason and the same audience.
--- @param info table The [info] table to resolve against.
--- @param letters table The [letters] alias map.
--- @param combo string The letters typed after "@".
--- @return table values, table fields
function M._resolve_combo_for_test(info, letters, combo)
	local prev_info, prev_letters = _info, _letters
	_info, _letters = info or {}, letters or {}
	local ok, values, fields = pcall(resolve_combo, combo)
	_info, _letters = prev_info, prev_letters
	if not ok then error(values, 0) end
	return values, fields
end

--- Retrieves the configured trigger character.
--- @return string The trigger character.
function M.get_trigger_char() return _trigger end

--- Updates the live trigger character used by the @-tag interceptor.
---
--- Without this the module had no way to learn about a magic key changed from
--- the menu: the sibling RulesEngine gained a setter, and dynamic_hotstrings
--- aliased its own proxy straight to that one engine, so the fix for the shared
--- defect reached exactly half of the pair. The @-tag engine went deaf while the
--- preview kept advertising the expansion.
--- @param char string The new trigger character.
function M.set_trigger_char(char)
	if type(char) ~= "string" or char == "" then
		Logger.error(LOG, "set_trigger_char(): expected a non-empty string, got %s — trigger unchanged.", type(char))
		return false
	end
	_trigger = char
	-- A pending combo was accumulated against the OLD trigger; keeping it would
	-- let the next keystroke fire a combo the user started under different rules.
	_state = STATE_IDLE
	_combo = ""
	Logger.debug(LOG, "Trigger char: %s.", char)
	return true
end

--- Opens the browser-based HTML form using the extracted UI module.
function M.open_editor()
	Logger.debug(LOG, "Opening personal info editor UI…")
	if ui_editor and type(ui_editor.open) == "function" then
		ui_editor.open(_info, M.save_info)
	else
		Logger.error(LOG, "The editor UI module is not available.")
	end
end

--- Initializes the module, wiring it into the keymap engine.
--- @param base_dir string Base configuration directory.
--- @param keymap_module table The active keymap module reference.
--- @param info_toml_path string|nil Absolute path to personal_info.toml (optional override).
function M.start(base_dir, keymap_module, info_toml_path)
	Logger.debug(LOG, "Starting personal info tracker…")
	if _active_start_token then
		if _keymap == keymap_module then return true end
		Logger.error(LOG, "Personal info tracker already owns a different keymap.")
		return false
	end
	if _starting_token then
		Logger.error(LOG, "Personal info tracker start refused because another start is in progress.")
		return false
	end

	local token = {}
	_starting_token = token
	if type(base_dir) == "string" then _base_dir = base_dir end

	-- Resolve the TOML path: explicit override > default relative to base_dir
	if type(info_toml_path) == "string" and info_toml_path ~= "" then
		_info_toml_path = info_toml_path
	else
		_info_toml_path = _base_dir .. "../hotstrings/personal_info.toml"
	end

	local config, was_missing = load_config(_info_toml_path)
	if type(config) ~= "table" then
		Logger.warn(LOG, "Module disabled because configuration is missing or invalid.")
		return rollback_start(token, "configuration load")
	end

	_info    = type(config.info) == "table" and config.info or {}
	_letters = type(config.letters) == "table" and config.letters or {}

	-- Source the trigger from the real, user-configurable magic key, exactly as
	-- the sibling RulesEngine already does. personal_info.toml's trigger_char is
	-- only this module's own default and never reflects a magic key changed from
	-- the menu, so booting from it left the @-tag engine listening for a key the
	-- user had stopped typing — while the preview, which has no trigger of its
	-- own, kept promising the expansion.
	if type(keymap_module) == "table" and type(keymap_module.get_trigger_char) == "function" then
		_trigger = tostring(keymap_module.get_trigger_char() or config.trigger_char or DEFAULT_TRIGGER)
	else
		_trigger = tostring(config.trigger_char or DEFAULT_TRIGGER)
	end

	-- Materialise defaults to disk if the file did not exist, so the user can
	-- edit it directly and so renaming or deleting it triggers a fresh
	-- re-creation on the next launch (mirrors the AHK side's behaviour).
	if was_missing then
		Logger.info(LOG, "Writing default personal_info.toml at '%s'…", _info_toml_path)
		M.save_info({})
	end

	_state     = STATE_IDLE
	_combo     = ""
	_replacing = false
	_enabled   = true
	
	_keymap = type(keymap_module) == "table" and keymap_module or nil
	local callback_keymap = _keymap

	-- Register the keystroke interceptor
	if _keymap and not register_start_callback("register_interceptor", _keymap.register_interceptor,
		function(...)
			if _active_start_token ~= token or _keymap ~= callback_keymap then return nil end
			return interceptor(...)
		end)
	then
		return rollback_start(token, "interceptor registration")
	end

	-- Register the preview provider for UI feedback
	if _keymap and not register_start_callback("register_preview_provider", _keymap.register_preview_provider,
		function(buf)
			if _active_start_token ~= token or _keymap ~= callback_keymap then return nil end
			if not _enabled or type(buf) ~= "string" then return nil end
			
			local match = buf:match("@([a-z]+)$")
			if match then
				-- The interceptor owns collection entry. It may deliberately remain
				-- IDLE because a static mapping already claims this `@` sequence.
				if _state ~= STATE_COLLECTING or _combo ~= match then return nil end
				if static_claims_full_trigger("@" .. match .. _trigger) then return nil end
				local parts, fields = resolve_combo(match)
				if #parts > 0 then
					-- Masked part by part, not row by row: one @-combo can resolve to
					-- several fields at once (`@ip★` is an IBAN AND a first name), and
					-- they are not classified alike. Masking the joined string would
					-- have no field to ask about and would have to hide all of it.
					local shown = {}
					for index, value in ipairs(parts) do
						shown[index] = masked_for_preview(value, fields[index])
					end
					return table.concat(shown, " ⇥ ")
				end
			end
			return nil
		end)
	then
		return rollback_start(token, "preview-provider registration")
	end
	_active_start_token = token
	_starting_token = nil
	Logger.info(LOG, "Personal info tracker started successfully.")
	return true
end

--- Enables the engine tracking.
function M.enable()
	Logger.debug(LOG, "Enabling personal info tracking…")
	_enabled = true; _state = STATE_IDLE; _combo = ""
	Logger.info(LOG, "Personal info tracking enabled.")
end

--- Disables the engine tracking.
function M.disable()
	Logger.debug(LOG, "Disabling personal info tracking…")
	_enabled = false; _state = STATE_IDLE; _combo = ""
	Logger.info(LOG, "Personal info tracking disabled.")
end

--- Stops the engine tracking.
function M.stop()
	_active_start_token = nil
	_starting_token = nil
	M.disable()
	_keymap = nil
end

return M
