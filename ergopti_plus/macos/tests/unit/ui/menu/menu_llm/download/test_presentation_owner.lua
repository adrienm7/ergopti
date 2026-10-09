--- tests/unit/ui/menu/menu_llm/download/test_presentation_owner.lua

--- ==============================================================================
--- MODULE: MLX Download Presentation
--- DESCRIPTION:
--- Exercises one download ownership boundary without weakening receipt assertions.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture_support = require("tests.support.mlx_download_fixture")
local with_fixture = fixture_support.with_fixture
local launch_detached_download = fixture_support.launch_detached_download

local function find_function_upvalue(fn, target, seen)
	if type(fn) ~= "function" then return nil end
	seen = seen or {}
	if seen[fn] then return nil end
	seen[fn] = true
	for index = 1, 100 do
		local name, value = debug.getupvalue(fn, index)
		if name == nil then break end
		if name == target and type(value) == "function" then return value end
		if type(value) == "function" then
			local nested = find_function_upvalue(value, target, seen)
			if nested ~= nil then return nested end
		end
	end
	return nil
end

helpers.describe("MLX download presentation ownership", function()
	for _, reattached in ipairs({ false, true }) do
		helpers.it("honors the real native close after presentation retirement, reattached="
			.. tostring(reattached), function()
			with_fixture({ real_window = true, pid_alive = true }, function(fixture)
				if reattached then helpers.assert_true(fixture.controls.reattach())
				else helpers.assert_true(fixture.controls.pull()) end
				helpers.assert_type(fixture.controls.native_window, "table")
				helpers.assert_true(fixture.controls.real_window.is_active())
				fixture.controls.native_window.options.on_close()
				helpers.assert_eq(fixture.controls.real_window.is_active(), false)
				helpers.assert_eq(fixture.records.download_aborts, 1,
					"native close must still notify the real producer after retiring its view")
				if not reattached then helpers.assert_eq(#fixture.records.cancels, 1) end
			end)
		end)
		helpers.it("finishes native close cleanup when abort opens a successor, reattached="
			.. tostring(reattached), function()
			with_fixture({ real_window = true, pid_alive = true }, function(fixture)
				local abort = fixture.deps.mark_download_aborted
				fixture.deps.mark_download_aborted = function()
					abort()
					helpers.assert_true(fixture.controls.real_window.show({ kind = "mlx_model", model = "successor" }))
				end
				if reattached then helpers.assert_true(fixture.controls.reattach())
				else helpers.assert_true(fixture.controls.pull()) end
				local predecessor = fixture.controls.native_window
				predecessor.options.on_close()
				helpers.assert_true(fixture.controls.real_window.is_active())
				helpers.assert_eq(fixture.records.download_aborts, 1)
				if not reattached then helpers.assert_eq(#fixture.records.cancels, 1) end
				predecessor.options.on_close()
				helpers.assert_eq(fixture.records.download_aborts, 1,
					"the real native owner must reject duplicate predecessor close")
			end)
		end)
		for _, replaced in ipairs({ false, true }) do
			helpers.it("isolates progress and completion, reattached=" .. tostring(reattached)
				.. ", replaced=" .. tostring(replaced), function()
				with_fixture({ pid_alive = true }, function(fixture)
					if reattached then helpers.assert_true(fixture.controls.reattach())
					else
						helpers.assert_true(fixture.controls.pull())
						launch_detached_download(fixture)
					end
					if replaced then
						package.loaded["ui.download_window"].show({ model = "other operation" })
					end
					local updates = #fixture.records.updates
					fixture.controls.latest("tail"):emit("Downloading weights 50%\n")
					fixture.controls.finish_download(0)
					if not reattached then
						helpers.assert_type(fixture.controls.server_success, "function")
						fixture.controls.server_success()
						helpers.assert_eq(fixture.records.successes, 1,
							"presentation replacement must not suppress the business terminal")
					end
					if replaced then
						helpers.assert_eq(#fixture.records.updates, updates,
							"old native output must not paint the successor presentation")
						helpers.assert_eq(#fixture.records.completions, 0)
					else
						helpers.assert_true(#fixture.records.updates > updates)
						helpers.assert_eq(#fixture.records.completions, 1)
						helpers.assert_true(fixture.records.completions[1][1])
					end
					helpers.assert_nil(fixture.controls.files["/tmp/hs_mlx_active_download.json"],
						"presentation replacement must not suppress session cleanup")
				end)
			end)
		end
		helpers.it("rejects retained UI retry after presentation replacement, reattached="
			.. tostring(reattached), function()
			with_fixture({ pid_alive = true }, function(fixture)
				if reattached then helpers.assert_true(fixture.controls.reattach())
				else helpers.assert_true(fixture.controls.pull()) end
				local retry = fixture.controls.window.on_retry
				package.loaded["ui.download_window"].show({ model = "other operation" })
				helpers.assert_eq(retry(), false)
				helpers.assert_eq(fixture.records.download_aborts, 0)
				helpers.assert_eq(#fixture.records.cancels, 0)
				helpers.assert_eq(fixture.controls.window.model, "other operation")
			end)
		end)
	end
end)

helpers.describe("HS-012 MLX timer replacement ownership", function()
	helpers.it("preserves a same-slot successor installed during native settlement", function()
		local poll_behavior = {}
		with_fixture({
			requirement_lifecycle = true,
			timer_by_delay = { [3] = poll_behavior },
		}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			launch_detached_download(fixture)
			local owner = fixture.controls.requirement_child
			helpers.assert_type(owner, "table")
			local schedule_owner_timer = find_function_upvalue(
				fixture.obj.pull_model, "schedule_owner_timer")
			helpers.assert_type(schedule_owner_timer, "function")
			local predecessor = owner.timers.poll
			helpers.assert_type(predecessor, "table")
			local before = #fixture.records.timers

			poll_behavior.reenter_on_running = function()
				return schedule_owner_timer(owner, "poll", 3, function() return true end)
			end
			helpers.assert_eq(
				schedule_owner_timer(owner, "poll", 3, function() return true end), false,
				"the stale outer replacement must refuse its nested successor")
			helpers.assert_true(fixture.records.timer_running_reentry_result)
			helpers.assert_eq(#fixture.records.timers, before + 1,
				"the outer replacement must not publish a second successor")
			helpers.assert_true(owner.timers.poll ~= predecessor)
			helpers.assert_eq(fixture.records.timers[before + 1].live, true)
		end)
	end)
end)
