--- tests/unit/infra/config/test_script_log_level_snapshot.lua

--- ==============================================================================
--- MODULE: Script Log-Level Snapshot (macOS)
--- DESCRIPTION:
--- Replays the shared numeric-owned alias snapshot contract against
--- infra.logger.
--- ==============================================================================

require("test.config_scope_script_level_contract")(require("tests.helpers"), "macos")
