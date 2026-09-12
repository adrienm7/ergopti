--- tests/support/tooltip_renderer_fixture.lua

--- ==============================================================================
--- MODULE: Tooltip Renderer Fixture
--- DESCRIPTION:
--- Owns renderer construction, diagnostics and native state across each scenario.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}
local OWNERS = {
	"infra.logger", "infra.i18n", "infra.paths", "infra.text_utils", "text_utils",
	"infra.toml.reader", "toml_codec.reader", "toml_codec.basic_string", "toml_codec.bom",
	"infra.vscode_bridge", "tooltip.layout", "tooltip.tint", "ui.tooltip.config", "ui.tooltip.renderer",
}

--- Loads a fresh production renderer with an observable file-logger surface.
--- @return table renderer Fresh renderer module.
--- @return table errors Captured ERROR messages.
function M.load()
	local errors = {}
	local logger = helpers.make_logger_stub()
	logger.error = function(_log, fmt, ...)
		local ok, message = pcall(string.format, tostring(fmt), ...)
		errors[#errors + 1] = ok and message or tostring(fmt)
	end
	package.loaded["infra.logger"] = logger
	package.loaded["ui.tooltip.config"] = nil
	package.loaded["toml_codec.reader"] = nil
	package.loaded["infra.toml.reader"] = nil
	return helpers.load_with_stubs("ui.tooltip.renderer"), errors
end

--- Registers a complete renderer scenario with exact predecessor restoration.
--- @param name string Scenario label.
--- @param callback function Scenario construction and assertions.
function M.it(name, callback)
	helpers.it(name, function()
		return helpers.with_stub_scope(OWNERS, callback)
	end)
end

return M
