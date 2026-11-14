--- tests/support/tooltip_renderer_fixture.lua

--- ==============================================================================
--- MODULE: Tooltip Renderer Fixture
--- DESCRIPTION:
--- Owns renderer construction, diagnostics and native state across each scenario.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}
local OWNERS = {
	"core.lifecycle.engine.compat.utf8",
	"core.fs.adapters.json_codec",
	"core.logger.engine.logger", "core.i18n.engine.i18n", "core.fs.engine.paths", "infra.text_utils", "core.text.engine.utils_core",
	"infra.toml.reader", "core.text.engine.toml_codec.reader", "core.text.engine.toml_codec.basic_string", "core.text.engine.toml_codec.bom",
	"core.text.engine.toml_codec.key_path", "core.text.engine.toml_codec.record_scanner",
	-- The real TOML reader opens its source through this shared owner.
	"core.text.engine.toml_codec.source_open",
	-- The record scanner memoizes one text's scans through this owner.
	"core.text.engine.toml_codec.source_memo",
	-- The real logger records its phase counters into this owner.
	"infra.phase_stats",
	-- The phase counters' bookkeeping, shared with the Linux driver.
	"metrics.engine.perf.phase_stats_core",
	-- The renderer configuration and the paths walk split paths through this pure owner.
	"core.fs.engine.native_path",
	-- The renderer asks it which applications answer Accessibility; it
	-- captures hs at require time, so each scenario loads it afresh.
	"adapters.accessibility_permission",
	"infra.vscode_bridge", "core.ui.engine.tooltip.layout", "core.ui.engine.tooltip.llm_line", "core.ui.engine.tooltip.tint", "ui.tooltip.config", "ui.tooltip.renderer",
	-- The configuration names the shortcut column's modifiers through the key
	-- name table, which it loads with its data and sorting helper.
	"platform.input.keycodes.key_names", "platform.input.keycodes.key_names_data", "core.text.engine.table_util",
	-- The configuration resolves tint colors through the shared CSS hex parser.
	"core.ui.engine.color_hex",
	-- text_utils builds its case tables from this generated data at require time.
	"core.text.engine.unicode_case.data",
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
	package.loaded["core.logger.engine.logger"] = logger
	package.loaded["ui.tooltip.config"] = nil
	package.loaded["core.text.engine.toml_codec.reader"] = nil
	package.loaded["infra.toml.reader"] = nil
	package.loaded["adapters.accessibility_permission"] = nil
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
