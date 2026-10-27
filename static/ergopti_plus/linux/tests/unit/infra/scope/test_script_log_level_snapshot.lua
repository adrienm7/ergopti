--- tests/unit/infra/scope/test_script_log_level_snapshot.lua

--- ==============================================================================
--- MODULE: Script Log-Level Snapshot (Linux)
--- DESCRIPTION:
--- Replays the shared numeric-owned alias snapshot contract against
--- infra.script_settings.
--- ==============================================================================

require("test.config_scope_script_level_contract")(require("tests.helpers"), "linux")
