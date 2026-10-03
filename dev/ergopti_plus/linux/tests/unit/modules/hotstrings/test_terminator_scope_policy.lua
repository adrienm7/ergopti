--- tests/unit/modules/hotstrings/test_terminator_scope_policy.lua

require("test.terminator_scope_contract")(require("tests.helpers"),
	require("modules.hotstrings.terminator_settings").builtin_state_leaves)
