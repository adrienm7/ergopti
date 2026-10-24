--- _shared/lua/llm/app_profile_overrides.lua

--- ==============================================================================
--- MODULE: Per-Application Profile Overrides (Shared Lua)
--- DESCRIPTION:
--- The rule behind llm.app_profile_overrides: a user maps an application to a
--- prompt profile, and a prediction typed in that application uses the mapped
--- profile instead of the menu's. Windows ships it (llm_bridge, prediction_exec
--- _LLM_Engine_ResolveProfileIdForApp); macOS and Linux share this module so the
--- rule, the stored text and the vectors are written once
--- (_shared/tests/corpus/llm/app_profile_overrides_vectors.json).
---
--- FEATURES & RATIONALE:
--- 1. The application key is the lower-cased process or application identifier
---    without a trailing ".exe", so an entry typed as "Slack" matches the
---    "slack.exe" Windows reports. The same normalisation applies when an entry
---    is added and when a prediction looks one up.
--- 2. The stored text is Windows's versioned envelope: "v1:" followed by the
---    Base64 of a JSON array of { app, profile } rows, and an empty string for
---    no override. Rows are written sorted by application, so the same map is the
---    same text. A damaged or newer envelope is refused, never half-read.
--- 3. The functions return new tables: a menu candidate is changed and only then
---    stored, so a refused write leaves the map in force untouched.
--- ==============================================================================

local Json = require("json")
local Base64 = require("compat.base64")
local AppIdentity = require("llm.app_identity")
local TableUtil = require("table_util")

local M = {}

-- The envelope version written and read here
M.VERSION_PREFIX = "v1:"

-- Aggregate bounds, so a hand-edited value cannot hold the menu hostage
M.MAX_ENTRIES = 200
M.MAX_FIELD_CHARS = AppIdentity.MAX_CHARS





-- ==========================================
-- ==========================================
-- ======= 1/ Application Key ===============
-- ==========================================
-- ==========================================

--- The key an application is stored and looked up under (llm.app_identity).
--- @param app any The identifier a driver reports, or a user typed.
--- @return string|nil key Lower-cased, trimmed, without ".exe"; nil when unusable.
function M.normalize_app(app)
	return AppIdentity.normalize(app)
end





-- ==========================================
-- ==========================================
-- ======= 2/ Lookup And Edits ==============
-- ==========================================
-- ==========================================

--- The profile id mapped to an application.
--- @param overrides table|nil Map of application key to profile id.
--- @param app any The focused application's identifier.
--- @param default_id any The profile in force without an override.
--- @return any profile_id The mapped profile, else default_id.
function M.resolve(overrides, app, default_id)
	if type(overrides) ~= "table" then return default_id end
	local key = M.normalize_app(app)
	local mapped = key and overrides[key] or nil
	if type(mapped) == "string" and mapped ~= "" then return mapped end
	return default_id
end

--- A copy of the map with one application mapped to a profile.
--- @param overrides table|nil
--- @param app any
--- @param profile_id any
--- @return table|nil copy
--- @return string|nil reason
function M.with(overrides, app, profile_id)
	local key = M.normalize_app(app)
	if not key then return nil, "the application identifier is empty or unusable" end
	if type(profile_id) ~= "string" or profile_id == "" or #profile_id > M.MAX_FIELD_CHARS then
		return nil, "the profile id is empty or unusable"
	end
	local copy = {}
	for stored, mapped in pairs(overrides or {}) do copy[stored] = mapped end
	if copy[key] == nil and TableUtil.count(copy) >= M.MAX_ENTRIES then return nil, "too many application overrides" end
	copy[key] = profile_id
	return copy
end

--- A copy of the map without one application.
--- @param overrides table|nil
--- @param app any
--- @return table copy
function M.without(overrides, app)
	local key = M.normalize_app(app)
	local copy = {}
	for stored, mapped in pairs(overrides or {}) do
		if stored ~= key then copy[stored] = mapped end
	end
	return copy
end

--- The rows of a map in the order the menu and the stored text use.
--- @param overrides table|nil
--- @return table rows Array of { app, profile }, sorted by application.
function M.rows(overrides)
	local rows = {}
	for app, profile in pairs(overrides or {}) do rows[#rows + 1] = { app = app, profile = profile } end
	table.sort(rows, function(left, right) return left.app < right.app end)
	return rows
end





-- ==========================================
-- ==========================================
-- ======= 3/ Stored Text ===================
-- ==========================================
-- ==========================================

--- Reads the stored text.
--- @param payload any The llm.app_profile_overrides value.
--- @return table|nil overrides Map of application key to profile id.
--- @return string|nil reason Why the text is refused.
function M.decode(payload)
	if payload == nil or payload == "" or payload == "_" then return {} end
	if type(payload) ~= "string" then return nil, "the stored value is not text" end
	if payload:sub(1, #M.VERSION_PREFIX) ~= M.VERSION_PREFIX then
		return nil, "the stored value is not a v1 envelope"
	end
	local bytes = Base64.decode(payload:sub(#M.VERSION_PREFIX + 1))
	if type(bytes) ~= "string" then return nil, "the envelope is not valid Base64" end
	if not bytes:match("^%s*%[") then return nil, "the envelope does not hold a JSON array" end
	local ok, rows = pcall(Json.decode_lossless, bytes)
	if not ok or type(rows) ~= "table" then return nil, "the envelope does not hold valid JSON" end
	if #rows > M.MAX_ENTRIES then return nil, "too many application overrides" end
	local overrides = {}
	for index = 1, #rows do
		local row = rows[index]
		if type(row) ~= "table" or type(row.app) ~= "string" or type(row.profile) ~= "string" then
			return nil, "a row is not { app, profile }"
		end
		local key = M.normalize_app(row.app)
		if not key or key ~= row.app then return nil, "a row names an application that is not stored normalised" end
		if row.profile == "" or #row.profile > M.MAX_FIELD_CHARS then return nil, "a row names no usable profile" end
		if overrides[key] ~= nil then return nil, "an application appears twice" end
		overrides[key] = row.profile
	end
	return overrides
end

--- Writes the stored text.
--- @param overrides table|nil Map of application key to profile id.
--- @return string|nil payload "" for no override.
--- @return string|nil reason
function M.encode(overrides)
	local rows = M.rows(overrides)
	if #rows == 0 then return "" end
	local out = {}
	for index, row in ipairs(rows) do
		if M.normalize_app(row.app) ~= row.app or type(row.profile) ~= "string" or row.profile == "" then
			return nil, "an override is not storable"
		end
		out[index] = { app = row.app, profile = row.profile }
	end
	local ok, text = pcall(Json.encode, Json.array(out))
	if not ok or type(text) ~= "string" then return nil, "the overrides could not be encoded" end
	return M.VERSION_PREFIX .. Base64.encode(text)
end

return M
