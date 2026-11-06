--- tests/unit/modules/keystats/storage/test_ledger_replay_state_bounds.lua

--- Persisted JSON offsets must fit the host integer used by the replay owner.
local helpers = require("tests.helpers")
local Replay = require("modules.keystats.ledger_replay")

helpers.describe("ledger replay state bounds (keystats-replay-offset-range)", function()
	helpers.it("rejects an integral float outside the host integer range before replay", function()
		for _, offset in ipairs({ 2.0 ^ 63, math.huge, -1, 1.5 }) do
			local state = { version = Replay.STATE_VERSION, offset = offset }
			helpers.assert_eq(Replay.is_state(state), false)
			local status, reason = Replay.step({ state = state, size = 0 })
			helpers.assert_eq(status, "failed")
			helpers.assert_eq(reason, "invalid replay state")
		end
		helpers.assert_true(Replay.is_state({ version = Replay.STATE_VERSION, offset = 1.0 }))
	end)
end)
