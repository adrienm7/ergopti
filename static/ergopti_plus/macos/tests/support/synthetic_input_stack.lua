--- tests/support/synthetic_input_stack.lua

--- ==============================================================================
--- MODULE: Synthetic Input Stack Test Support
--- DESCRIPTION:
--- Reloads the real modules that capture one Hammerspoon stub and one synthetic
--- ledger at require-time. Tests that exercise exact Quartz provenance use this
--- helper so every scenario has a coherent producer, timer, and event-tap stack.
--- ==============================================================================

local helpers = require("tests.helpers")

local M = {}

local CAPTURED_STACK = {
	"modules.keymap.utils",
	"modules.keymap.terminator_replay",
	"adapters.text_sender",
	"adapters.clipboard",
	"adapters.event_provenance",
	"adapters.synthetic_input",
	"adapters.event_tap_guard",
	"adapters.timer_scheduler",
}


--- Loads a subject and the real SyntheticInput adapter under the same fresh hs.
--- Deliberately does not clear optional collaborators such as modules.keylogger:
--- callers may have installed a dependency double before reaching this seam.
--- @param module_name string Subject module name.
--- @param hs_overrides table|nil Optional Hammerspoon stub overrides.
--- @return table subject
--- @return table synthetic_input
function M.load(module_name, hs_overrides)
	for _, name in ipairs(CAPTURED_STACK) do
		package.loaded[name] = nil
	end
	local subject = helpers.load_with_stubs(module_name, hs_overrides)
	return subject, require("adapters.synthetic_input")
end


return M
