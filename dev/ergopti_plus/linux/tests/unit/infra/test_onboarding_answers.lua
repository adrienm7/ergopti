--- tests/unit/infra/test_onboarding_answers.lua

--- ==============================================================================
--- MODULE: Onboarding Answers (Linux)
--- DESCRIPTION:
--- Runs the shared onboarding answers contract against the Linux manifest under
--- the Linux runner (LuaJIT in CI): the wizard catalogue names only paths this
--- driver declares, the finish payload becomes sparse manifest rows or is
--- refused whole, and the commit publishes one versioned batch.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.onboarding_answers_contract").register(helpers, { driver = "linux" })
