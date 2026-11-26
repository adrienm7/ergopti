--- tests/unit/settings/scope/test_script_log_level_snapshot.lua

--- ==============================================================================
--- MODULE: Script Log-Level Snapshot (macOS)
--- DESCRIPTION:
--- Replays the shared numeric-owned alias snapshot contract against
--- infra.logger.
--- ==============================================================================

require("tests.lua.settings.scope_script_level_contract")(require("tests.helpers"), "macos")
