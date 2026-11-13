--- tests/unit/infra/shared_modules/test_shared_module_contracts.lua

--- ==============================================================================
--- MODULE: Test Shared Module Contracts
--- DESCRIPTION:
--- Registers the direct contracts of the shared Lua modules that no other test
--- required by name (audit R36): the AI menu config guard, the personal editor
--- model, the programmable hotstring configuration inverse, the typed-text
--- migration runner, the raw-ingress rule of the typed-text cipher, the
--- physical position observation, and the small process, sqlite, walker and
--- composer helpers. The same cases run on macOS and Linux.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.settings.guard_contract").register(helpers)
require("tests.lua.hotstrings.personal_model_contract").register(helpers)
require("tests.lua.hotstrings.dynamic_hotstrings_user_scope_contract").register(helpers)
require("tests.lua.core.text_migration_runner_contract").register(helpers)
require("tests.lua.physical_conflicts_vectors_contract").register(helpers, helpers.shared("tests/corpus/shortcuts/physical_conflict_vectors.json"))
require("tests.lua.core.text_migration_driver_contract").register(helpers)
require("tests.lua.core.text_cipher_raw_ingress_contract").register(helpers)
require("tests.lua.hotstrings.user_code_driver_contract").register(helpers)
require("tests.lua.layouts.physical_position_observation_contract").register(helpers)
require("tests.lua.shared_helpers_contract").register(helpers)
