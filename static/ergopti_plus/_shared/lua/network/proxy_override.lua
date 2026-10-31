--- _shared/lua/network/proxy_override.lua

--- network/proxy_override.lua

--- ==============================================================================
--- MODULE: Shared Proxy Override Setting
--- DESCRIPTION:
--- Interprets the user's proxy override (Issue #101 point 2): automatic (the
--- system settings, a company PAC included), direct, or one explicit relay
--- every download uses. Pure policy over the canonical declaration
--- (_shared/modules/network/proxy_override.json); each driver reads the stored
--- value through its own storage owner and hands it to proxy_policy.route.
---
--- FEATURES & RATIONALE:
--- 1. An escape hatch: a PAC Ergopti cannot fetch or evaluate, or one naming a
---    relay that refuses Ergopti's clients, left no way to download from a
---    network where a terminal works; the override bypasses the lookup.
--- 2. One relay grammar: a relay is accepted exactly when the route plan
---    accepts it (network/route_plan.lua), so every environment-driven client
---    can export it.
--- 3. Fail fast: a stored value that is neither empty, the direct token nor a
---    valid relay is refused with a closed reason, never read as automatic.
--- ==============================================================================

local M = {}

local RoutePlan = require("network.route_plan")

--- The closed refusal reasons.
M.INVALID = "proxy-override-invalid"
M.DECLARATION_INVALID = "proxy-override-declaration-invalid"

--- Builds the interpreter of one decoded declaration.
--- @param data table Decoded proxy_override.json.
--- @return table|nil override, string|nil reason
function M.new(data)
	if type(data) ~= "table" or data.schema_version ~= 1 or type(data.storage_key) ~= "string"
		or not data.storage_key:match("^%l[%l_]*%.%l[%l_]*$") or data.default ~= ""
		or type(data.direct) ~= "string" or not data.direct:match("^%l+$") then
		return nil, M.DECLARATION_INVALID
	end
	local direct = data.direct
	local override = { storage_key = data.storage_key, default = data.default, direct = direct }

	--- Classifies a stored or typed value.
	--- @param value any nil (never set) reads as the default.
	--- @return table|nil choice { mode = "automatic"|"direct"|"relay", relay = string|nil }, string|nil reason
	function override.parse(value)
		if value == nil then value = data.default end
		if type(value) ~= "string" then return nil, M.INVALID end
		value = value:match("^%s*(.-)%s*$")
		if value == "" then return { mode = "automatic" } end
		if value:lower() == direct then return { mode = "direct" } end
		if value == "direct" or not RoutePlan.valid_route(value) then return nil, M.INVALID end
		return { mode = "relay", relay = value }
	end

	--- The canonical form a valid value is stored under.
	--- @param value any
	--- @return string|nil stored, string|nil reason
	function override.normalize(value)
		local choice, reason = override.parse(value)
		if not choice then return nil, reason end
		if choice.mode == "automatic" then return data.default end
		if choice.mode == "direct" then return direct end
		return choice.relay
	end

	return override
end

--- The i18n keys of the edit dialog, one per message.
M.KEYS = {
	title = "proxy_override.title",
	prompt = "proxy_override.prompt",
	invalid = "proxy_override.invalid",
	not_saved = "proxy_override.not_saved",
	saved = {
		automatic = "proxy_override.saved_automatic",
		direct = "proxy_override.saved_direct",
		relay = "proxy_override.saved_relay",
	},
}

--- Runs the Debug menu row: shows the stored value, validates what the user
--- types, stores its canonical form and says what downloads now do. A value
--- the parser refuses is never stored. Logs name the mode only, never a relay.
--- @param setting table Interpreter from M.new.
--- @param ports table { get = fn(key) -> any, set = fn(key, value) -> boolean,
---   prompt = fn(title, text, initial) -> string|nil (nil on cancel),
---   error = fn(title, text), info = fn(title, text), t = fn(key) -> string,
---   log = fn(level, message, ...) }.
--- @return boolean saved
function M.edit(setting, ports)
	local stored = ports.get(setting.storage_key)
	local initial = type(stored) == "string" and stored or setting.default
	local typed = ports.prompt(ports.t(M.KEYS.title), ports.t(M.KEYS.prompt), initial)
	if typed == nil then return false end
	local value = setting.normalize(typed)
	if value == nil then
		ports.log("warn", "Proxy override refused: the typed value is not a relay URL, direct or empty.")
		ports.error(ports.t(M.KEYS.title), ports.t(M.KEYS.invalid))
		return false
	end
	if ports.set(setting.storage_key, value) ~= true then
		ports.log("error", "Proxy override not saved: the settings store refused the write.")
		ports.error(ports.t(M.KEYS.title), ports.t(M.KEYS.not_saved))
		return false
	end
	local mode = setting.parse(value).mode
	ports.log("info", "Proxy override saved: %s.", mode)
	ports.info(ports.t(M.KEYS.title), ports.t(M.KEYS.saved[mode]))
	return true
end

return M
