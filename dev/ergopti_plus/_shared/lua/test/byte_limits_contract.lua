--- _shared/lua/test/byte_limits_contract.lua

--- ==============================================================================
--- MODULE: Shared Byte Limits Contract
--- DESCRIPTION:
--- Pins the [limits] byte caps of the timing registry
--- (_shared/modules/timings/constants.toml) that shared Lua modules publish as
--- public fields, and proves each field is the registry value. The macOS and
--- Linux suites both register it, so neither driver can keep a typed copy.
---
--- FEATURES & RATIONALE:
--- 1. The pinned numbers are the values the caps had as literals; a registry
---    edit that changes one fails here and must be deliberate.
--- 2. Each module is reloaded, so the field is read from the registry by this
---    load and not inherited from an earlier test.
--- ==============================================================================

local M = {}

--- The pinned registry values: { [limits] key, bytes }.
M.PINNED = {
	{ "layer_file_bytes", 65536 },
	{ "number_row_level_text_bytes", 1024 },
	{ "release_list_body_bytes", 2097152 },
	{ "program_catalogue_bytes", 65536 },
	{ "http_diagnostic_bytes", 65536 },
	{ "proxy_packet_bytes", 65536 },
	{ "shortcuts_reply_bytes", 65536 },
}

--- The shared modules and the field that publishes each key.
M.FIELDS = {
	{ module = "keymap.layer_editor", field = "MAX_TEXT_BYTES", key = "layer_file_bytes" },
	{ module = "layout.number_row_native", field = "MAX_TEXT_BYTES", key = "number_row_level_text_bytes" },
	{ module = "updater.list_cache", field = "MAX_BODY_BYTES", key = "release_list_body_bytes" },
	{ module = "program_providers", field = "MAX_CATALOGUE_BYTES", key = "program_catalogue_bytes" },
}

--- Registers the contract on one driver's suite.
--- @param helpers table The driver's test helpers.
--- @param options table { driver = string, timings = the driver's infra.timings }
function M.register(helpers, options)
	assert(type(options) == "table" and type(options.driver) == "string" and type(options.timings) == "table",
		"the byte limits contract needs a driver name and its timings reader")
	helpers.describe("shared [limits] byte caps: " .. options.driver, function()
		helpers.it("keeps the registry values unchanged", function()
			for _, pin in ipairs(M.PINNED) do
				helpers.assert_eq(options.timings.count("limits", pin[1]), pin[2], "[limits]." .. pin[1])
			end
		end)

		helpers.it("publishes each cap from the registry", function()
			for _, entry in ipairs(M.FIELDS) do
				package.loaded[entry.module] = nil
				local module = require(entry.module)
				helpers.assert_eq(module[entry.field], options.timings.count("limits", entry.key),
					entry.module .. "." .. entry.field)
			end
		end)
	end)
end

return M
