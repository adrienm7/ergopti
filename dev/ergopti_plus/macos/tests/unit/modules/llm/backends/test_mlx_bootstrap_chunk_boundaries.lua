--- tests/unit/modules/llm/backends/test_mlx_bootstrap_chunk_boundaries.lua

--- ==============================================================================
--- MODULE: MLX Bootstrap Chunk Boundaries
--- DESCRIPTION:
--- Exercise the real MLX checker with fragmented native task output. A PTY
--- flush does not imply that a task callback receives a complete marker.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.modules.llm.backends.ai_runtime_selection_install_fixture")

helpers.describe("MLX bootstrap framing (mlx-bootstrap-chunks)", function()
	helpers.it("opens progress for a fragmented sync marker", Fixture.scoped(function()
		local state = Fixture.new_state()
		local active, shows = false, 0
		state.window = {}
		for key, value in pairs(Fixture.WINDOW_STUB) do state.window[key] = value end
		state.window.is_active = function() return active end
		state.window.show = function() active = true; shows = shows + 1 end
		local checker = Fixture.load_mlx_checker(state)
		helpers.assert_true(checker.install_for_selection())
		local task = state.tasks[1]
		local marker = "VENV_SYNC_RAN\r\n"
		for index = 1, #marker do
			helpers.assert_true(task.stream(task, marker:sub(index, index), ""))
		end
		helpers.assert_eq(shows, 1, "a split sync marker must claim the progress window once")
		task.done(0, "", "")
	end))
end)
