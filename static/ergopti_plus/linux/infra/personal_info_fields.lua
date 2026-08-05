--- infra/personal_info_fields.lua

--- ==============================================================================
--- MODULE: Personal-Info Field Classification (Linux binding)
--- DESCRIPTION:
--- Reads _shared/modules/personal_info/fields.toml — which personal_info fields
--- are secrets, and how much of one may appear on screen — and hands it to the
--- shared masking function.
---
--- FEATURES & RATIONALE:
--- 1. No local copy, by design. This driver keeps no fallback table: a fallback
---    is the second source the shared file exists to remove, and the failure it
---    produces is the worst kind — a value shown because one driver's private
---    list disagreed with the declaration.
--- 2. Fail-CLOSED, unlike its timings sibling. A missing or malformed
---    declaration does not raise: it yields a policy under which everything is
---    masked. A driver that cannot read the classification must not conclude
---    that nothing is secret, and a raise on this path would take down the
---    preview bubble rather than degrade it.
--- 3. Read once. The declaration is shipped with the driver, not user-editable,
---    so re-reading it per keystroke would be a file open on the preview path
---    for a value that cannot change.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Reader = require("toml_codec")
local Mask   = require("personal_info.mask")

local LOG = "infra.personal_info_fields"

-- What the classification degrades to when it cannot be read. Everything is
-- masked and nothing is revealed, so a driver that lost its declaration hides
-- values rather than showing them.
local FAIL_CLOSED = {
	policy = {
		mask_char            = "•",
		reveal_head          = 0,
		reveal_tail          = 0,
		min_length_to_reveal = math.huge,
		preserve_separators  = true,
	},
	fields = {},
}

local _declaration = nil




-- =========================================
-- =========================================
-- ======= 1/ Loading ======================
-- =========================================
-- =========================================

--- Resolves the absolute path to the shared declaration.
---
--- Walks up from this file, exactly as infra/timings.lua does: this module is
--- read before the driver's package.path is necessarily complete, so it cannot
--- ask a path resolver that itself needs one.
--- @return string|nil
local function resolve_path()
	local src = debug and debug.getinfo and debug.getinfo(1, "S")
	if not (src and src.source) then return nil end
	local s = src.source
	if s:sub(1, 1) == "@" or s:sub(1, 1) == "=" then s = s:sub(2) end
	s = s:gsub("\\", "/")
	-- .../ergopti_plus/linux/infra/personal_info_fields.lua → .../ergopti_plus/
	local root = s:match("^(.*)/[^/]+/[^/]+/[^/]+$")
	if not root then return nil end
	return root .. "/_shared/modules/personal_info/fields.toml"
end

--- Loads the declaration, once.
--- @return table { policy = table, fields = table }
local function declaration()
	if _declaration then return _declaration end

	local path = resolve_path()
	if not path then
		Logger.error(LOG, "Cannot resolve the shared field declaration — masking everything.")
		_declaration = FAIL_CLOSED
		return _declaration
	end

	-- Read then decode: toml_codec exposes `decode(string)`, not `parse(path)` —
	-- the timings reader's `Reader.parse` is a different module, and calling the
	-- wrong one here fails closed, which is safe and completely silent about why.
	local fh = io.open(path, "r")
	if not fh then
		Logger.error(LOG, "Cannot open '%s' — masking everything.", path)
		_declaration = FAIL_CLOSED
		return _declaration
	end
	local content = fh:read("*a")
	fh:close()

	local ok, parsed = pcall(Reader.decode, content)
	if not ok or type(parsed) ~= "table" or type(parsed.policy) ~= "table" then
		Logger.error(LOG, "Could not parse '%s' — masking everything. (%s)", path,
			ok and "malformed" or tostring(parsed))
		_declaration = FAIL_CLOSED
		return _declaration
	end

	local valid, missing = Mask.validate_policy(parsed.policy)
	if not valid then
		Logger.error(LOG, "The shared policy is missing '%s' — masking everything.", tostring(missing))
		_declaration = FAIL_CLOSED
		return _declaration
	end

	_declaration = { policy = parsed.policy, fields = parsed.fields or {} }
	Logger.debug(LOG, "Field classification loaded (%d field(s) declared).", (function()
		local n = 0
		for _ in pairs(_declaration.fields) do n = n + 1 end
		return n
	end)())
	return _declaration
end




-- =========================================
-- =========================================
-- ======= 2/ Public API ===================
-- =========================================
-- =========================================

--- What the preview bubble may show for a value.
---
--- The ONLY entry point a display path should call. It takes the field name so
--- the decision and the masking cannot drift apart — a caller that remembers to
--- ask "is this masked" and forgets to actually mask is the shape this avoids.
--- @param value string The full value, as it would be typed.
--- @param field string|nil The personal_info.toml field it came from.
--- @return string
function M.for_preview(value, field)
	return Mask.mask_field(value, field, declaration())
end

--- Whether a field is declared a secret.
--- @param field string|nil
--- @return boolean
function M.is_masked(field)
	local decl = declaration()
	local entry = (type(field) == "string") and decl.fields[field] or nil
	-- Unknown is masked: a field nobody classified is a field nobody decided to
	-- reveal.
	if entry == nil then return true end
	return entry.masked ~= false
end

--- Drops the cached declaration. Tests only — the file cannot change at runtime.
function M._reset()
	_declaration = nil
end

return M
