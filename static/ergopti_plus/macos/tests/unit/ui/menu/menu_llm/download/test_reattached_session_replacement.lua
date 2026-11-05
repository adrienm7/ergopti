--- tests/unit/ui/menu/menu_llm/download/test_reattached_session_replacement.lua

--- A retired reattachment cannot unlink a different download's session.
local helpers = require("tests.helpers")
local fixture_support = require("tests.support.mlx_download_fixture")

helpers.describe("MLX reattached session ownership", function()
	helpers.it("keeps a replacement session when the old download completes", function()
		fixture_support.with_fixture({ pid_alive = true }, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			local path = "/tmp/hs_mlx_active_download.json"
			local successor = '{"model":"C","log_path":"/tmp/hs_mlx_dl_successor.log","pid":5252}'
			fixture.controls.files[path] = successor
			fixture.controls.exit_code = 0
			fixture.controls.fire(3)
			fixture.controls.latest("tail"):complete(0)
			helpers.assert_eq(fixture.controls.files[path], successor,
				"a replacement session belongs to its new owner")
		end)
	end)
	helpers.it("keeps the file and owner when capture is unavailable", function()
		fixture_support.with_fixture({ pid_alive = true, session_classify_failure = true }, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			local path = "/tmp/hs_mlx_active_download.json"
			local original = fixture.controls.files[path]
			fixture.controls.exit_code = 0
			fixture.controls.fire(3)
			fixture.controls.latest("tail"):complete(0)
			helpers.assert_eq(fixture.controls.files[path], original)
			helpers.assert_true(fixture.obj.has_reattached_download())
		end)
	end)

	helpers.it("retains a refused removal for retry", function()
		local plan = { pid_alive = true, session_remove_failure = true }
		fixture_support.with_fixture(plan, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			local path = "/tmp/hs_mlx_active_download.json"
			fixture.controls.exit_code = 0
			fixture.controls.fire(3)
			fixture.controls.latest("tail"):complete(0)
			helpers.assert_type(fixture.controls.files[path], "string")
			helpers.assert_true(fixture.obj.has_reattached_download())
			plan.session_remove_failure = false
			helpers.assert_true(fixture.obj.pull_model("C", "org/other", nil, nil,
				{ is_current = function() return true end }))
		end)
	end)

	helpers.it("releases a refused unlink before retiring a replaced session", function()
		local plan = { pid_alive = true, session_remove_failure = true, session_release_failure = true }
		fixture_support.with_fixture(plan, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			local path = "/tmp/hs_mlx_active_download.json"
			fixture.controls.exit_code = 0
			fixture.controls.fire(3)
			fixture.controls.latest("tail"):complete(0)
			helpers.assert_true(fixture.obj.has_reattached_download())
			local successor = '{"model":"C","log_path":"/tmp/successor.log"}'
			fixture.controls.files[path] = successor
			helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, nil,
				{ is_current = function() return true end }), false)
			helpers.assert_eq(fixture.controls.files[path], successor)
			helpers.assert_eq(fixture.records.session_at_release_retry, successor)
			plan.session_release_failure = false
			helpers.assert_true(fixture.obj.pull_model("C", "org/other", nil, nil,
				{ is_current = function() return true end }))
			helpers.assert_eq(fixture.records.session_at_release_retry, successor)
		end)
	end)

	helpers.it("continues removal after releasing a refused unlink", function()
		local plan = { pid_alive = true, session_remove_failure = true, session_release_failure = true }
		fixture_support.with_fixture(plan, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			local path = "/tmp/hs_mlx_active_download.json"
			fixture.controls.exit_code = 0
			fixture.controls.fire(3)
			fixture.controls.latest("tail"):complete(0)
			helpers.assert_type(fixture.controls.files[path], "string")
			plan.session_remove_failure, plan.session_release_failure = false, false
			helpers.assert_true(fixture.obj.pull_model("C", "org/other", nil, nil,
				{ is_current = function() return true end }))
			helpers.assert_type(fixture.records.session_at_release_retry, "string")
			helpers.assert_eq(fixture.records.session_removed_content, fixture.records.session_at_release_retry)
			local current = fixture.controls.files[path]
			helpers.assert_true(current:find('"model":"C"', 1, true) ~= nil)
		end)
	end)

	helpers.it("retries only release after the old file was removed", function()
		local plan = { pid_alive = true, session_release_failure = true }
		fixture_support.with_fixture(plan, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			local path = "/tmp/hs_mlx_active_download.json"
			fixture.controls.exit_code = 0
			fixture.controls.fire(3)
			fixture.controls.latest("tail"):complete(0)
			helpers.assert_nil(fixture.controls.files[path])
			helpers.assert_true(fixture.obj.has_reattached_download())
			local successor = '{"model":"C","log_path":"/tmp/successor.log"}'
			fixture.controls.files[path] = successor
			plan.session_release_failure = false
			helpers.assert_true(fixture.obj.pull_model("C", "org/other", nil, nil,
				{ is_current = function() return true end }))
			helpers.assert_eq(fixture.records.session_at_release_retry, successor)
		end)
	end)
end)
