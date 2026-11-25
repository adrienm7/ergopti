--- tests/unit/modules/shortcuts/test_workflow_model.lua

--- ==============================================================================
--- MODULE: macOS User Workflow Model
--- DESCRIPTION:
--- Replays the shared workflow model contract
--- (_shared/tests/lua/workflows/workflow_model_contract.lua) and the
--- interpreter, runner, owner, editor host and screen step contracts on the
--- Hammerspoon runtime.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.workflows.workflow_model_contract").register(helpers, helpers.shared)
require("tests.lua.workflows.workflow_interpreter_contract").register(helpers, helpers.shared)
require("tests.lua.workflows.workflow_runner_contract").register(helpers, helpers.shared)
require("tests.lua.workflows.workflow_owner_contract").register(helpers, helpers.shared)
require("tests.lua.workflows.workflow_editor_host_contract").register(helpers, helpers.shared)
require("tests.lua.workflows.workflow_screen_contract").register(helpers, helpers.shared)
