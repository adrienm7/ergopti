--- tests/unit/ui/menu/menu_llm/download/test_repository_identifier_validation.lua

--- ==============================================================================
--- MODULE: MLX Download Repository Validation
--- DESCRIPTION:
--- Exercises one download ownership boundary without weakening receipt assertions.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture_support = require("tests.support.mlx_download_fixture")
local with_fixture = fixture_support.with_fixture

helpers.describe("HS-037 detached session repository identifiers are untrusted", function()
	local hostile_repositories = {
		"org/model'$(touch_HS037_PWN)'",
		"org/model`touch_HS037_PWN`",
		"org/model\"$(touch_HS037_PWN)\"",
		"org/mo del",
		"org/model\npayload",
		"org/model/extra",
	}

	for _, hostile_repo in ipairs(hostile_repositories) do
		helpers.it("refuses a hostile pull_model repository before acquisition", function()
			with_fixture({}, function(fixture)
				local cancellation_reason
				local accepted = fixture.obj.pull_model("B", hostile_repo, nil,
					function(reason)
						cancellation_reason = reason
						return true
					end, {is_current = function() return true end})

				helpers.assert_eq(accepted, false)
				helpers.assert_eq(cancellation_reason, "invalid_repo")
				helpers.assert_eq(#fixture.controls.tasks.launcher, 0)
				helpers.assert_eq(#fixture.controls.tasks.tail, 0)
				helpers.assert_eq(#fixture.records.timers, 0)
				helpers.assert_eq(#fixture.records.os_commands, 0)
				helpers.assert_nil(fixture.controls.window)
			end)
		end)
	end

	helpers.it("refuses a planted reattach repository at the retry handoff", function()
		local hostile_repo = "org/model'$(touch_HS037_PWN)'"
		with_fixture({
			pid_alive = true,
			pid_identity = false,
			tail = {running_after_start = false},
		}, function(fixture)
			helpers.assert_true(fixture.controls.reattach(hostile_repo))
			helpers.assert_true(fixture.controls.window.on_retry())
			helpers.assert_eq(#fixture.controls.tasks.launcher, 0,
				"retry must not construct a launcher from the planted repository")
			for path in pairs(fixture.controls.files) do
				helpers.assert_true(not path:match("%.py$") and not path:match("%.sh$"),
					"retry must not stage executable files from the planted repository")
			end
		end)
	end)
end)
