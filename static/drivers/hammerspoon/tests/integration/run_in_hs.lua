--- tests/integration/run_in_hs.lua

--- ==============================================================================
--- MODULE: In-Hammerspoon Integration Smoke Test
--- DESCRIPTION:
--- Loads each top-level driver module and asserts it returns a table without
--- throwing. Run from the Hammerspoon console after a reload to validate the
--- live build end-to-end against the real hs.* API.
--- ==============================================================================

local TARGETS = {
	"lib.color_utils", "lib.text_utils", "lib.toml_reader", "lib.logger",
	"lib.keycodes", "lib.layout", "lib.perf",
	"modules.keymap.terminators", "modules.keymap.utils",
	"modules.karabiner.defaults", "modules.karabiner.config",
	"modules.llm.backend_detector", "modules.llm.parser",
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
