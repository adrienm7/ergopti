-- Personal information shortcuts for Hammerspoon.
--
-- Monitors typed characters and expands  @<letters><trigger>  into
-- tab-separated personal-information values.
--
-- Architecture: instead of a separate eventtap (which would compete with
-- keymap's tap for event ordering), this module registers an *interceptor*
-- directly inside keymap's single keyDown tap via keymap.register_interceptor().
-- The interceptor runs BEFORE backspace, escape, getCharacters(false) and all
-- hotstring matching — ensuring that Unicode trigger chars like ★ are caught
-- even when getCharacters(false) returns "".
--
-- Interceptor return values:
--   "consume"  → keymap returns true  (★ is consumed, suppresses apps + hotstrings)
--   "suppress" → keymap returns false (letter appears in field, hotstrings skipped)
--   nil        → normal keymap processing
--
-- Example (default config):
--   @np★  →  Nom [Tab] Prénom
--   @e★   →  prenom.nom@mail.fr
--   @npa★ →  Nom [Tab] Prénom [Tab] 1 Rue de la Paix

local M = {}

local eventtap = hs.eventtap
local timer    = hs.timer

-- ---------------------------------------------------------------------------
-- States
-- ---------------------------------------------------------------------------
local STATE_IDLE       = "idle"
local STATE_COLLECTING = "collecting"  -- after @ has been typed

-- ---------------------------------------------------------------------------
-- Module-level state
-- ---------------------------------------------------------------------------
local _enabled   = false
local _replacing = false
local _state     = STATE_IDLE
local _combo     = ""   -- letters accumulated after @

-- Config (populated by start()).
local _trigger   = "★"
local _info      = {}
local _letters   = {}
local _base_dir  = ""

-- ---------------------------------------------------------------------------
-- Built-in defaults — used when config.json has no "personal_info_config" key.
-- Users can override by adding a "personal_info_config" section to config.json.
-- ---------------------------------------------------------------------------
local DEFAULT_CONFIG = {
        trigger_char = "★",
        info = {
                FirstName            = "Prénom",
                LastName             = "Nom",
                DateOfBirth          = "01/01/1990",
                EmailAddress         = "prenom.nom@exemple.fr",
                WorkEmailAddress     = "prenom.nom@entreprise.fr",
                PhoneNumber          = "0600000000",
                PhoneNumberFormatted = "06 00 00 00 00",
                StreetAddress        = "1 Rue de la Paix",
                City                 = "Paris",
                Country              = "France",
                PostalCode           = "75001",
                IBAN                 = "FR00 0000 0000 0000 0000 0000 000",
                BIC                  = "ABCDFRPP",
                CreditCard           = "0000 0000 0000 0000",
                SocialSecurityNumber = "0 00 00 00 000 000 00",
        },
        letters = {
                a = "StreetAddress",
                b = "BIC",
                c = "CreditCard",
                d = "DateOfBirth",
                e = "EmailAddress",
                f = "PhoneNumberFormatted",
                i = "IBAN",
                m = "EmailAddress",
                n = "LastName",
                p = "FirstName",
                s = "SocialSecurityNumber",
                t = "PhoneNumber",
                w = "WorkEmailAddress",
        },
}

-- ---------------------------------------------------------------------------
-- Config loader
-- Reads the "personal_info_config" key from config.json (shared config file).
-- Falls back to DEFAULT_CONFIG so the module always starts with sensible values.
-- ---------------------------------------------------------------------------
local function load_config(base_dir)
        local path = base_dir .. "config.json"
        local raw  = hs.json.read(path)
        if type(raw) == "table" and type(raw["personal_info_config"]) == "table" then
                return raw["personal_info_config"]
        end
        -- config.json absent or has no personal_info_config key: use built-in defaults.
        print("[personal_info] No personal_info_config in config.json — using defaults.")
        return DEFAULT_CONFIG
end

-- ---------------------------------------------------------------------------
-- Combo resolver
-- ---------------------------------------------------------------------------
local function resolve_combo(combo)
	local parts = {}
	for i = 1, #combo do
		local letter = combo:sub(i, i)
		local key    = _letters[letter]
		if key and _info[key] then
			table.insert(parts, _info[key])
		end
	end
	return parts
end

-- ---------------------------------------------------------------------------
-- Expansion (runs asynchronously so keymap's tap can return first)
-- ---------------------------------------------------------------------------
local function do_expand(combo)
	-- At expansion time, the field contains: ...@<combo>
	-- The ★ was consumed by the interceptor so it is NOT in the field.
	-- We delete: @ (1) + #combo ASCII letters.
	local n_back = 1 + #combo
	local parts  = resolve_combo(combo)

	_replacing = true

	for _ = 1, n_back do
		eventtap.keyStroke({}, "delete", 0)
	end
	for i, value in ipairs(parts) do
		eventtap.keyStrokes(value)
		if i < #parts then
			eventtap.keyStroke({}, "tab", 0)
		end
	end

	timer.doAfter(0.15, function()
		_replacing = false
	end)
end

-- ---------------------------------------------------------------------------
-- Interceptor (registered into keymap via keymap.register_interceptor)
-- Called for every keyDown event that passes the cmd/ctrl guard.
-- ---------------------------------------------------------------------------
local function interceptor(event, _km_buffer)
	-- Module disabled (toggled off from menu): pass everything through.
	if not _enabled then return nil end
	-- While we are sending synthetic events, pass everything through.
	if _replacing then return nil end

	local flags = event:getFlags()
	if flags.cmd or flags.ctrl then
		_state = STATE_IDLE
		_combo = ""
		return nil
	end

	local kc = event:getKeyCode()

	-- Esc / Return / Enter / arrows → abort combo.
	if kc == 53 or kc == 36 or kc == 76
	or (kc >= 123 and kc <= 126) then
		_state = STATE_IDLE
		_combo = ""
		return nil
	end

	-- Backspace: pop last accumulated letter, or cancel @ if combo is empty.
	if kc == 51 then
		if _state == STATE_COLLECTING then
			if #_combo > 0 then
				_combo = _combo:sub(1, -2)
			else
				_state = STATE_IDLE
			end
		end
		return nil  -- keymap handles backspace normally
	end

	-- Use getCharacters(false) as primary source — this mirrors what keymap
	-- uses to build its buffer and correctly resolves Karabiner-remapped
	-- Unicode characters like ★ (where getCharacters(true) would return
	-- the underlying physical key name "j" instead of "★").
	local char = event:getCharacters(false) or ""
	if char == "" then return nil end

	-- ── IDLE: watch for @ ─────────────────────────────────────────────────
        -- Return "suppress" when @ is typed so no hotstring can ever fire on @.
        if _state == STATE_IDLE then
                if char == "@" then
                        _state = STATE_COLLECTING
                        _combo = ""
                        return "suppress"  -- @ appears in field, hotstrings blocked
                end
                return nil
        end

        -- ── COLLECTING ────────────────────────────────────────────────────────
        -- While collecting a combo, ALL characters suppress hotstring matching
        -- so the accumulated @<letters> never accidentally triggers an expansion.
        if _state == STATE_COLLECTING then
                -- Trigger character → attempt expansion.
                if char == _trigger then
                        if #_combo > 0 and #resolve_combo(_combo) > 0 then
                                local combo = _combo
                                _state = STATE_IDLE
                                _combo = ""
                                -- Defer so keymap's tap finishes returning "consume" first.
                                timer.doAfter(0, function() do_expand(combo) end)
                                return "consume"  -- swallow ★, prevent hotstring matching
                        end
                        -- Trigger with no matching combo → let it pass and reset.
                        _state = STATE_IDLE
                        _combo = ""
                        return nil
                end

                -- Lowercase ASCII letter → accumulate.
                if char:match("^[a-z]$") then
                        _combo = _combo .. char
                        return "suppress"  -- letter appears in field, hotstrings blocked
                end

                -- Anything else → abort combo; suppress to prevent the accumulated
                -- @<letters> from feeding a deferred hotstring expansion.
                _state = STATE_IDLE
                _combo = ""
                return "suppress"
        end

	return nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Return the loaded info table (used by init.lua to pass data to
-- dynamic_hotstrings without coupling the two modules directly).
function M.get_info()
	return _info
end

-- Return the trigger character loaded from config.
function M.get_trigger_char()
	return _trigger
end

-- Persist updated info fields into config.json under "personal_info_config.info".
-- Only the keys present in new_info are updated; other keys are preserved.
function M.save_info(new_info)
        local path = _base_dir .. "config.json"
        local raw  = hs.json.read(path)
        if type(raw) ~= "table" then raw = {} end
        if type(raw["personal_info_config"]) ~= "table" then
                raw["personal_info_config"] = {
                        trigger_char = _trigger,
                        letters      = _letters,
                        info         = {},
                }
        end
        for k, v in pairs(new_info) do
                raw["personal_info_config"]["info"][k] = v
        end
        local ok, encoded = pcall(function() return hs.json.encode(raw) end)
        if ok and encoded then
                local fh = io.open(path, "w")
                if fh then fh:write(encoded); fh:close() end
        end
        -- Update live state so expansions use the new values immediately.
        _info = raw["personal_info_config"]["info"]
        print("[personal_info] Config saved.")
end

-- Open a browser-based form to edit all personal info fields at once.
-- Uses hs.httpserver so the form opens in the system browser, completely
-- bypassing Hammerspoon's eventtap (which blocks keyboard input in webviews).
function M.open_editor()
        local fields = {
                { key = "FirstName",            label = "Prénom" },
                { key = "LastName",             label = "Nom" },
                { key = "DateOfBirth",          label = "Date de naissance" },
                { key = "EmailAddress",         label = "E-mail" },
                { key = "WorkEmailAddress",     label = "E-mail professionnel" },
                { key = "PhoneNumber",          label = "Téléphone (chiffres seuls)" },
                { key = "PhoneNumberFormatted", label = "Téléphone (formaté)" },
                { key = "StreetAddress",        label = "Adresse" },
                { key = "PostalCode",           label = "Code postal" },
                { key = "City",                 label = "Ville" },
                { key = "Country",              label = "Pays" },
                { key = "IBAN",                 label = "IBAN" },
                { key = "BIC",                  label = "BIC" },
                { key = "CreditCard",           label = "Carte de crédit" },
                { key = "SocialSecurityNumber", label = "Numéro de Sécurité Sociale" },
        }

        local srv
        local port = 18743

        -- URL-decode a percent-encoded string.
        local function urldecode(s)
                return (s:gsub("+", " "):gsub("%%(%x%x)", function(h)
                        return string.char(tonumber(h, 16))
                end))
        end

        -- Build the HTML form (values HTML-escaped).
        local rows = ""
        for _, f in ipairs(fields) do
                local val = (_info[f.key] or "")
                        :gsub("&", "&amp;"):gsub("<", "&lt;"):gsub('"', "&quot;")
                rows = rows .. string.format(
                        '<div class="row"><label>%s</label><input name="%s" value="%s"></div>\n',
                        f.label, f.key, val)
        end

        local html_form = string.format([[<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Infos personnelles</title>
<style>
*{box-sizing:border-box}
body{font-family:-apple-system,sans-serif;font-size:14px;padding:24px;
     background:#f5f5f7;margin:0;max-width:520px;margin:0 auto}
h2{margin:0 0 16px;font-size:17px}
.row{margin-bottom:11px}
label{display:block;color:#555;margin-bottom:4px;font-size:12px;font-weight:500}
input{width:100%%;padding:7px 10px;font-size:14px;border:1px solid #ccc;
      border-radius:6px;background:#fff}
input:focus{outline:none;border-color:#007AFF;box-shadow:0 0 0 3px rgba(0,122,255,.15)}
.btns{margin-top:20px;display:flex;justify-content:flex-end;gap:10px}
button{padding:8px 22px;font-size:14px;border-radius:7px;cursor:pointer;border:none;font-weight:500}
.cancel{background:#e0e0e0;color:#333}
.save{background:#007AFF;color:#fff}
</style></head>
<body>
<h2>Informations personnelles</h2>
<form method="POST" action="/save">
%s
<div class="btns">
  <button type="button" class="cancel"
    onclick="fetch('/cancel').then(()=>window.close())">Annuler</button>
  <button type="submit" class="save">Enregistrer</button>
</div>
</form></body></html>]], rows)

        local html_ok = [[<!DOCTYPE html><html><head><meta charset="utf-8">
<style>body{font-family:-apple-system,sans-serif;padding:40px;text-align:center}
h2{color:#007AFF}</style></head>
<body><h2>✓ Enregistré</h2><p>Vous pouvez fermer cet onglet.</p>
<script>window.close()</script></body></html>]]

        -- HTTP request handler.
        local function handler(method, path, headers, body)
                if path == "/" then
                        return html_form, 200, { ["Content-Type"] = "text/html; charset=utf-8" }
                elseif path == "/save" and method == "POST" then
                        -- Parse application/x-www-form-urlencoded body.
                        local new_info = {}
                        for k, v in (body or ""):gmatch("([^&=]+)=([^&]*)") do
                                new_info[urldecode(k)] = urldecode(v)
                        end
                        M.save_info(new_info)
                        -- Stop server after a short delay so browser gets the response.
                        timer.doAfter(0.5, function() if srv then srv:stop(); srv = nil end end)
                        return html_ok, 200, { ["Content-Type"] = "text/html; charset=utf-8" }
                elseif path == "/cancel" then
                        timer.doAfter(0.5, function() if srv then srv:stop(); srv = nil end end)
                        return "", 200, {}
                end
                return "Not found", 404, {}
        end

        srv = hs.httpserver.new(false, false)
        srv:setPort(port)
        srv:setCallback(handler)
        srv:start()

        -- Open the form in the default browser.
        hs.execute(string.format("open 'http://127.0.0.1:%d/'", port))
        print("[personal_info] Editor opened in browser on port " .. port)
end
function M.start(base_dir, keymap_module)
	if base_dir then _base_dir = base_dir end

	local config = load_config(_base_dir)
	if not config then
		print("[personal_info] Module disabled (config missing or invalid).")
		return
	end

	_trigger = config.trigger_char or "★"
	_info    = config.info    or {}
	_letters = config.letters or {}

	_state     = STATE_IDLE
	_combo     = ""
	_replacing = false
	_enabled   = true

	-- Register interceptor once; subsequent enable/disable only flip _enabled.
	if keymap_module and type(keymap_module.register_interceptor) == "function" then
		keymap_module.register_interceptor(interceptor)
		print("[personal_info] Interceptor registered in keymap.")
	else
		print("[personal_info] WARNING: keymap_module not provided or missing register_interceptor.")
	end

	local letter_count = 0
	for _ in pairs(_letters) do letter_count = letter_count + 1 end
	print(string.format("[personal_info] Started — trigger: %s, %d letter(s) mapped.",
		_trigger, letter_count))
end

-- Enable/disable without re-registering the interceptor.
-- Use these from the menu toggle instead of start/stop.
function M.enable()
	_state     = STATE_IDLE
	_combo     = ""
	_replacing = false
	_enabled   = true
	print("[personal_info] Enabled.")
end

function M.disable()
	_enabled   = false
	_state     = STATE_IDLE
	_combo     = ""
	_replacing = false
	print("[personal_info] Disabled.")
end

function M.stop()
	M.disable()
end

function M.is_enabled()
	return _enabled
end

return M
