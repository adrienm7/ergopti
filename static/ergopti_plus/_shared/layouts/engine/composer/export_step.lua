--- _shared/layouts/engine/composer/export_step.lua

--- ==============================================================================
--- MODULE: Layout Editor Export Step (Shared)
--- DESCRIPTION:
--- Runs one step of the shared export adapter (source_export.lua) for the
--- layout editor of the macOS and Linux app windows, with the driver's own Lua.
--- Those windows keep their strict content policy (no 'unsafe-eval'), so the
--- page cannot run the fengari VM the site uses (maintainer, 2026-11-15); the
--- page sends the step's input and builds the XKB and KLC files from the result.
---
--- FEATURES & RATIONALE:
--- 1. Same data path as the page's fengari runner (layout_editor/lua_runner.js)
---    and the repository tool: JSON text in, the shared json module's
---    encoding out, so the files the page builds are the same bytes.
--- 2. Allowlisted: only the adapter's `read` and `xkb` steps run.
--- 3. Bounded and fail fast: an input or result over max_export_step_bytes, an
---    input that is not a JSON object, or a Lua error is refused with the
---    source failures' export code; an adapter refusal is the result's
---    `ok = false`, passed on as it is.
--- 4. PURE Lua: no file, process or host access.
--- ==============================================================================

local M = {}

local Json = require("core.text.engine.json")

-- The adapter steps the page may run.
M.STEPS = { read = true, xkb = true }

-- A failure code the page receives.
local CODE = "^[a-z_]+$"





-- ===========================
-- ===========================
-- ======= 1/ Settings =======
-- ===========================
-- ===========================

--- Validates the source table of the shared layout defaults for the export step.
--- @param layout_defaults table Decoded _shared/layouts/data/defaults.json.
--- @return table|nil settings { max_bytes, failure }
--- @return string|nil error
function M.settings(layout_defaults)
	local source = type(layout_defaults) == "table" and layout_defaults.source or nil
	if type(source) ~= "table" then return nil, "the layout defaults have no source table" end
	local bound = source.max_export_step_bytes
	if type(bound) ~= "number" or bound <= 0 or bound % 1 ~= 0 then
		return nil, "the source max_export_step_bytes is not a positive integer"
	end
	local failures = source.failures
	if type(failures) ~= "table" or type(failures.export) ~= "string" or not failures.export:match(CODE) then
		return nil, "the source failures name no export code"
	end
	return { max_bytes = bound, failure = failures.export }, nil
end





-- ========================
-- ========================
-- ======= 2/ Run =========
-- ========================
-- ========================

--- Runs one adapter step on its JSON input.
--- @param settings table From M.settings.
--- @param step string read or xkb.
--- @param input_text string The step's input as JSON text.
--- @return boolean ok
--- @return string output_or_code The result's JSON text, or the failure code.
--- @return string|nil detail Why it was refused.
function M.run(settings, step, input_text)
	if type(step) ~= "string" or not M.STEPS[step] then
		return false, settings.failure, "the export step is not read or xkb"
	end
	if type(input_text) ~= "string" or input_text == "" then
		return false, settings.failure, "the export step has no input"
	end
	if #input_text > settings.max_bytes then
		return false, settings.failure, "the export step's input is larger than its bound"
	end
	local decoded, input = pcall(Json.decode, input_text)
	if not decoded or type(input) ~= "table" or not input_text:match("^%s*{") then
		return false, settings.failure, "the export step's input is not a JSON object"
	end
	local ran, result = pcall(function()
		return require("layouts.engine.composer.source_export")[step](input)
	end)
	if not ran then return false, settings.failure, tostring(result) end
	local output = Json.encode(result)
	if #output > settings.max_bytes then
		return false, settings.failure, "the export step's result is larger than its bound"
	end
	return true, output, nil
end





-- ========================================
-- ========================================
-- ======= 3/ Layout registry entry =======
-- ========================================
-- ========================================

--- Builds a driver layout registry's source_export_step, the same on macOS and
--- Linux: it reads the layout defaults through the registry, runs one step and
--- answers on_done(ok, output_or_code, detail).
--- @param registry table The driver's layout registry module.
--- @param read_defaults function Returns the decoded layout defaults, or nil and an error.
--- @param logger table The driver's logger.
--- @param log_tag string The registry's log tag.
--- @param failure_code string The code an unusable defaults file answers.
function M.registry_entry(registry, read_defaults, logger, log_tag, failure_code)
	--- Runs one step of the shared export adapter for the layout editor's XKB
	--- and KLC downloads, with this driver's Lua.
	--- @param payload table { step = "read"|"xkb", input = JSON text }
	--- @param on_done function on_done(ok, output_or_code, detail)
	--- @return boolean dispatched
	registry.source_export_step = function(payload, on_done)
		local layout_defaults, defaults_err = read_defaults()
		local settings, settings_err
		if layout_defaults then settings, settings_err = M.settings(layout_defaults) end
		if not settings then
			local detail = tostring(defaults_err or settings_err)
			logger.error(log_tag, "The layout editor's export step is unusable: %s.", detail)
			on_done(false, failure_code, detail)
			return false
		end
		local ok, output_or_code, detail = M.run(settings, type(payload) == "table" and payload.step or nil,
			type(payload) == "table" and payload.input or nil)
		if not ok then logger.warn(log_tag, "The layout editor's export step was refused: %s.", tostring(detail)) end
		on_done(ok, output_or_code, detail)
		return true
	end
end

return M
