--- tests/unit/modules/shortcuts/caps_word/test_caps_word_auto_off_policy.lua
--- Shared CapsWord auto-off policy, through the actual Linux assertion owner.
local helpers = require("tests.helpers")
require("test.caps_word_auto_off_contract").run(helpers,
	helpers.driver_root() .. "/../_shared/tests/corpus/caps_word/auto_off_vectors.json")
return true
