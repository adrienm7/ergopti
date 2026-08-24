--- tests/unit/ui/test_onboarding_bool_value_type.lua

--- ==============================================================================
--- MODULE: Onboarding Wizard — boolean value TYPE (regression)
--- DESCRIPTION:
--- Audit finding F-H8. to_bool() returned the Lua STRING "true"/"false", which
--- toml_writer serialised as a QUOTED `enabled = "false"`. The TOML decoder only
--- coerces a BARE true/false to a boolean, so a quoted "false" decoded back to the
--- Lua string "false" — and a non-empty string is truthy, so a feature the user
--- DECLINED in the wizard (every boot gate is `if state.flag then`) silently
--- re-activated on the post-wizard reload.
---
--- Root cause encoded end-to-end through the REAL writer + decoder: a declined
--- answer must serialise as a bare `enabled = false` and decode to a FALSY value.
--- ==============================================================================

local helpers = require("tests.helpers")

local Onboarding  = helpers.load_with_stubs("ui.onboarding")
local toml_writer = require("infra.toml.writer")
local toml_codec  = require("infra.toml.codec")

local function enabled_value(updates, section)
	for _, u in ipairs(updates) do
		if u.section == section and u.key == "enabled" then return u.value end
	end
	return nil
end

helpers.describe("onboarding: a declined feature round-trips to a falsy boolean", function()
	helpers.it("declined metrics/gestures serialise as bare `false` and decode FALSY", function()
		local updates = Onboarding._build_config_updates({
			use_ergopti = true, use_metrics = false, use_gestures = false, magic_key = "X",
		})

		-- 1) The value is a real boolean, not the string "false".
		helpers.assert_eq(type(enabled_value(updates, "metrics")), "boolean")
		helpers.assert_eq(enabled_value(updates, "metrics"), false)
		helpers.assert_eq(enabled_value(updates, "gestures"), false)

		-- 2) Round-trip through the REAL writer + decoder.
		local tmp = (os.getenv("TEMP") or os.getenv("TMP") or "."):gsub("\\", "/")
			.. "/ergopti_onboarding_bool_roundtrip.toml"
		os.remove(tmp)
		local ok = toml_writer.batch_write(tmp, updates)
		helpers.assert_true(ok ~= false, "batch_write must succeed")

		local fh = assert(io.open(tmp, "r"))
		local raw = fh:read("*a"); fh:close()
		-- Bare boolean on disk, NEVER the quoted string the bug produced.
		helpers.assert_true(raw:find("enabled = false", 1, true) ~= nil,
			"a declined feature must serialise as a bare `enabled = false`")
		helpers.assert_true(raw:find('enabled = "false"', 1, true) == nil,
			"must NOT serialise as the quoted string \"false\" (it decodes truthy)")

		-- 3) Decode back: the boot gate `if state.flag then` must see a FALSY value.
		local parsed = toml_codec.decode(raw)
		helpers.assert_true(type(parsed) == "table", "decode must return a table")
		helpers.assert_true(parsed.metrics ~= nil, "decoded [metrics] section must be present")
		helpers.assert_eq(parsed.metrics.enabled, false)
		helpers.assert_true(not parsed.metrics.enabled,
			"decoded enabled MUST be falsy so a declined feature stays off on reload")

		os.remove(tmp)
	end)
end)
