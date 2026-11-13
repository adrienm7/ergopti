-- tests/fixtures/partial_hotstrings_failure.lua
-- Registers one mapping, then simulates a failing hotstring loader.
local Registry = require("settings.engine.registry")

Registry.add("partial", "PARTIAL", { is_case_sensitive = true })
error("injected Lua hotstring load failure")
