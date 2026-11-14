--- tests/unit/infra/config/test_script_config_authority.lua

--- ==============================================================================
--- MODULE: Script Config Authority (macOS)
--- DESCRIPTION:
--- config.toml's [script] rows win over hs.settings at start; a change rewrites
--- the row the file holds. Replays the shared contract.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.settings.script_config_authority_contract").run(helpers, {
	platform = "hs", manifest = require("infra.manifest_reader"),
	aliases = require("infra.script_scope").alias_names(), file_adapter = require("core.fs.adapters.file_system"),
})
