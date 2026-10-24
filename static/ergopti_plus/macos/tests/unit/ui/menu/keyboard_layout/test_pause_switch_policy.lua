--- tests/unit/ui/menu/keyboard_layout/test_pause_switch_policy.lua

--- ==============================================================================
--- MODULE: Pause Switch Policy Tests
--- DESCRIPTION:
--- Replays the shared pause/resume/quit layout vectors through the macOS test
--- owner, against the macOS generated manifest.
--- ==============================================================================

local helpers = require("tests.helpers")
local Contract = require("test.pause_switch_policy_contract")
Contract.run(helpers, helpers.shared("tests/corpus/layouts/pause_switch_vectors.json"))
Contract.run_manifest(helpers, require("infra.manifest_reader"))

return true
