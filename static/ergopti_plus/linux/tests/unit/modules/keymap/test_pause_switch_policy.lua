--- tests/unit/modules/keymap/test_pause_switch_policy.lua
--- Shared pause/resume/quit layout policy, through the actual Linux assertion owner.
local helpers = require("tests.helpers")
require("test.pause_switch_policy_contract").run(helpers,
	helpers.driver_root() .. "/../_shared/tests/corpus/layouts/pause_switch_vectors.json")
return true
