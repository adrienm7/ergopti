--- infra/personal_info_fields.lua

--- ==============================================================================
--- MODULE: Personal-Info Field Classification (macOS binding)
--- DESCRIPTION:
--- Reads _shared/modules/personal_info/fields.toml — which personal_info fields
--- are secrets, and how much of one may appear on screen — and hands it to the
--- shared masking function.
---
--- FEATURES & RATIONALE:
--- 1. No local copy, by design. This driver keeps no fallback table: a fallback
---    is the second source the shared file exists to remove, and the failure it
---    produces is the worst kind — a value shown because one driver's private
---    list disagreed with the declaration. Linux carries the same module for the
---    same reason; the two must not diverge, and the corpus at
---    _shared/modules/personal_info/preview_vectors.toml is what measures that.
--- 2. Fail-CLOSED, unlike its timings sibling. infra/timings.lua raises when the
---    registry is unreadable, which is right for a boot-time constant table.
---    Here a raise would take down the preview bubble on the keystroke path, and
---    worse, a driver that cannot read the classification must not conclude that
---    nothing is secret. A missing or malformed declaration therefore yields a
---    policy under which everything is masked.
--- 3. Read once. The declaration is shipped with the driver, not user-editable,
---    so re-reading it per keystroke would be a file open on the preview path
---    for a value that cannot change.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local Codec  = require("infra.toml.codec")
local Mask   = require("personal_info.mask")
local Paths  = require("infra.paths")

local LOG = "infra.personal_info_fields"

-- Where the declaration lives inside the shared tree.
local DECLARATION_REL = "modules/personal_info/fields.toml"

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





-- ==========================
-- ==========================
-- ======= 1/ Loading =======
-- ==========================
-- ==========================

--- Loads the declaration, once.
---
--- Read then decode, through infra.toml.codec. NOT infra.toml.reader: that is
--- the hotstrings-format parser, and on this file it returns a well-formed EMPTY
--- result instead of erroring — so the binding would fail closed for a reason
--- nothing reports, every value would be bulleted, and it would look deliberate.
--- @return table { policy = table, fields = table }
local function declaration()
	if _declaration then return _declaration end

	-- Guard the PATH first: Paths.shared() returns nil when the _shared/ tree is
	-- unreachable, and the message below has to be able to name the real cause.
	local path = Paths.shared(DECLARATION_REL)
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "Cannot resolve the shared field declaration — masking everything.")
		_declaration = FAIL_CLOSED
		return _declaration
	end

	local handle = io.open(path, "r")
	if not handle then
		Logger.error(LOG, "Cannot open '%s' — masking everything.", path)
		_declaration = FAIL_CLOSED
		return _declaration
	end
	local body = handle:read("*a")
	handle:close()

	local ok, parsed = pcall(Codec.decode, body)
	if not ok or type(parsed) ~= "table" or type(parsed.policy) ~= "table" then
		Logger.error(LOG, "Could not parse '%s' — masking everything. (%s)", path,
			ok and "malformed" or tostring(parsed))
		_declaration = FAIL_CLOSED
		return _declaration
	end

	local valid, invalid = Mask.validate_policy(parsed.policy)
	if not valid then
		Logger.error(LOG, "The shared policy is invalid at '%s' — masking everything.", tostring(invalid))
		_declaration = FAIL_CLOSED
		return _declaration
	end

	_declaration = { policy = parsed.policy, fields = parsed.fields or {} }
	local declared = 0
	for _ in pairs(_declaration.fields) do declared = declared + 1 end
	Logger.debug(LOG, "Field classification loaded (%d field(s) declared).", declared)
	return _declaration
end





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- What the preview bubble may show for a value.
---
--- The ONLY entry point a display path should call. It takes the field name so
--- the decision and the masking cannot drift apart — a caller that remembers to
--- ask "is this masked" and forgets to actually mask is the shape this avoids.
---
--- DISPLAY ONLY. Nothing that reaches an injection seam may pass through here:
--- the expansion is always the complete value, and typing a row of bullets into
--- a bank form is silent, destructive, and indistinguishable from the feature
--- working.
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
