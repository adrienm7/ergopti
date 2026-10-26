--- tests/unit/infra/shared_modules/test_shared_module_contracts.lua

--- ==============================================================================
--- MODULE: Test Shared Module Contracts
--- DESCRIPTION:
--- Registers the direct contracts of the shared Lua modules that no other test
--- required by name (audit R36): the AI menu config guard, the personal editor
--- model, the programmable hotstring configuration inverse, the typed-text
--- migration runner, the physical position observation, and the small process,
--- sqlite, walker and composer helpers. The same cases run on macOS and Linux.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.config_guard_contract").register(helpers)
require("test.personal_model_contract").register(helpers)
require("test.dynamic_hotstrings_user_scope_contract").register(helpers)
require("test.text_migration_runner_contract").register(helpers)
require("test.text_migration_driver_contract").register(helpers)
require("test.user_code_driver_contract").register(helpers)
require("test.physical_position_observation_contract").register(helpers)
require("test.shared_helpers_contract").register(helpers)
