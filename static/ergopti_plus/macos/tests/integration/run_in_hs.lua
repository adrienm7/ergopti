--- tests/integration/run_in_hs.lua

--- ==============================================================================
--- MODULE: In-Hammerspoon Integration Smoke Test
--- DESCRIPTION:
--- Loads each top-level driver module and asserts it returns a table without
--- throwing. Run from the Hammerspoon console after a reload to validate the
--- live build end-to-end against the real hs.* API.
--- ==============================================================================

local TARGETS = {
	"core.text.engine.utils", "core.text.engine.toml.reader", "core.logger.engine.logger",
	"platform.input.keycodes", "modules.keymap.layout", "core.logger.engine.perf",
	"hotstrings.engine.expander.terminators", "hotstrings.engine.expander.utils",
	"platform.remap.defaults", "platform.remap.config",
	"ai.engine.api.backend_detector", "ai.engine.api.parser",
}

local pass, fail = 0, 0
for _, name in ipairs(TARGETS) do
	local ok, mod = pcall(require, name)
	if ok and type(mod) == "table" then
		pass = pass + 1
		print(string.format("  PASS %s", name))
	else
		fail = fail + 1
		print(string.format("  FAIL %s : %s", name, tostring(mod)))
	end
end

print(string.format("\nIntegration smoke: %d passed, %d failed", pass, fail))
return { passed = pass, failed = fail }
