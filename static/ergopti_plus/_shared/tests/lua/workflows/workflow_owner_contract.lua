--- _shared/tests/lua/workflows/workflow_owner_contract.lua

--- ==============================================================================
--- MODULE: User Workflow Owner Contract
--- DESCRIPTION:
--- Drives the shared owner over an in-memory config folder and recording OS
--- ports on the macOS and Linux runtimes: the run_workflow action runs the
--- stored workflow, each effect reaches its port, a missing workflow, an
--- invalid file and a failing step each end in a translated notice, Escape
--- stops a run, the variables reach a shell step as environment variables,
--- and an imported shell step waits for the editor's approval.
---
--- ROOT CAUSE ENCODED:
--- The run_workflow action had nothing to run: no store read the user's
--- workflows, no mapping turned the interpreter's effects into OS calls, and
--- a failure had no notice.
--- ==============================================================================

local Json = require("core.text.engine.json")
local Model = require("shortcuts.engine.workflows.model")
local Owner = require("shortcuts.engine.workflows.owner")
local Effects = require("shortcuts.engine.workflows.effects")

local M = {}

--- @param shared_path function
--- @param relative string
--- @return table
local function load_json(shared_path, relative)
	local file = assert(io.open(shared_path(relative), "rb"))
	local text = assert(file:read("*a")); assert(file:close())
	return assert(Json.decode(text), relative)
end

--- Builds an owner over recording ports.
--- @param catalogue table
--- @param vocabulary table
--- @param files table path -> text, the config folder.
--- @param overrides table|nil Effect port replacements.
--- @return table owner, table world
local function harness(catalogue, vocabulary, files, overrides)
	local world = { calls = {}, notices = {}, timers = {}, files = files, confirm = true }
	local function record(name)
		return function(...)
			local args = { ... }
			local done = args[#args]
			world.calls[#world.calls + 1] = { name = name, args = args }
			done(true)
		end
	end
	local effect_ports = {
		send_shortcut = record("send_shortcut"), type_text = record("type_text"), open = record("open"),
		focus_app = record("focus_app"), clipboard_set = record("clipboard_set"), mouse_move = record("mouse_move"),
		mouse_click = record("mouse_click"), run_action = record("run_action"), notify = record("notify"),
		clipboard_get = function(done) world.calls[#world.calls + 1] = { name = "clipboard_get" }; done("clip") end,
		after = function(ms, fn)
			local timer = { ms = ms, fn = fn, live = true }
			world.timers[#world.timers + 1] = timer
			return function() timer.live = false end
		end,
		shell = function(command, env, deadline, done)
			world.calls[#world.calls + 1] = { name = "shell", args = { command, env, deadline } }
			done(true, "out")
		end,
		app_front = function(app, done) done(app == "Front") end,
	}
	for key, value in pairs(overrides or {}) do effect_ports[key] = value end
	local owner = Owner.new({
		store = {
			path = function(name) return "/cfg/" .. name end,
			read = function(path) return world.files[path] end,
			write = function(path, text) world.files[path] = text end,
			catalogue = catalogue,
			context = { vocabulary = vocabulary, timings = { wait_max_ms = 600000 } },
		},
		effects = effect_ports,
		after = effect_ports.after,
		translate = function(key) return "<" .. key .. ">{1}|{2}|{3}|{4}" end,
		notify = function(text) world.notices[#world.notices + 1] = text end,
		timeouts = { step_timeout_ms = 10, screen_step_timeout_ms = 20, shell_timeout_ms = 30,
			wait_max_ms = 600000, wait_for_poll_ms = 5 },
	})
	return owner, world
end

--- A workflows.json holding one workflow.
--- @param steps table
--- @param origin string|nil
--- @return string
local function file_of(steps, origin)
	return Json.encode({ schema_version = 1, workflows = Json.array({
		{ id = "wf_1", name = "Mine", origin = origin or "local", steps = Json.array(steps) } }) })
end

M.harness = harness
M.file_of = file_of

--- Registers the owner checks.
--- @param helpers table Driver test API.
--- @param shared_path function Driver resolver for a path under _shared/.
function M.register(helpers, shared_path)
	local catalogue = load_json(shared_path, Model.CATALOGUE_PATH)
	local vocabulary = load_json(shared_path, "shortcuts/data/actions/send_keys.json")

	helpers.describe("workflows: owner", function()
		helpers.it("workflows: run_workflow runs every step through its port", function()
			local owner, world = harness(catalogue, vocabulary, { ["/cfg/workflows.json"] = file_of({
				{ kind = "send_keys", combo = "ctrl+a" }, { kind = "clipboard_get", into = "c" },
				{ kind = "type_text", text = "<{{c}}>" }, { kind = "open", target_kind = "url", value = "https://x.invalid" },
				{ kind = "focus_app", app = "A" }, { kind = "clipboard_set", text = "s" }, { kind = "mouse_move", x = 1, y = 2 },
				{ kind = "mouse_click", x = 3, y = 4 }, { kind = "run_action", action = "select_all" },
				{ kind = "notify", text = "n" },
			}) })
			helpers.assert_eq(owner.run({ id = "wf_1" }), true)
			local names = {}
			for index, call in ipairs(world.calls) do names[index] = call.name end
			helpers.assert_eq(table.concat(names, ","), "send_shortcut,clipboard_get,type_text,open,focus_app,"
				.. "clipboard_set,mouse_move,mouse_click,run_action,notify")
			helpers.assert_eq(world.calls[3].args[1], "<clip>")
			helpers.assert_eq(world.calls[8].args[3], "left")
			helpers.assert_eq(world.calls[8].args[4], 1)
			helpers.assert_eq(#world.notices, 0)
		end)

		helpers.it("workflows: a missing workflow and an invalid file are told", function()
			local owner, world = harness(catalogue, vocabulary, {})
			helpers.assert_eq(owner.run({ id = "gone" }), false)
			helpers.assert_true(world.notices[1]:find("<workflows.notice.missing>gone", 1, true) ~= nil, world.notices[1])
			world.files["/cfg/workflows.json"] = '{"schema_version":1,"workflows":[{"id":"a"}]}'
			helpers.assert_eq(owner.run({ id = "a" }), false)
			helpers.assert_true(world.notices[2]:find("<workflows.notice.file_invalid>missing_field|/workflows/0/name", 1, true) ~= nil,
				world.notices[2])
			helpers.assert_eq(owner.run(nil), false)
			helpers.assert_eq(owner.choices(), nil)
		end)

		helpers.it("workflows: a failing step names the step, its kind and the reason", function()
			local owner, world = harness(catalogue, vocabulary, { ["/cfg/workflows.json"] = file_of({
				{ kind = "if", condition = { type = "app_front", app = "Front" },
					["then"] = Json.array({ { kind = "focus_app", app = "B" } }) },
			}) }, { focus_app = function(_, done) done(false, "timeout") end })
			owner.run({ id = "wf_1" })
			helpers.assert_eq(world.notices[1], "<workflows.notice.failed>Mine|1 › ✓ 1|<workflows.step.focus_app>{1}|{2}|{3}|{4}|"
				.. "<workflows.reason.timeout>{1}|{2}|{3}|{4}")
		end)

		helpers.it("workflows: a screen step without the screen services is named", function()
			local owner, world = harness(catalogue, vocabulary, { ["/cfg/workflows.json"] = file_of({
				{ kind = "ocr", mode = "full", into = "t" } }) })
			owner.run({ id = "wf_1" })
			helpers.assert_true(world.notices[1]:find("<workflows.reason.screen_service_missing>", 1, true) ~= nil, world.notices[1])
		end)

		helpers.it("workflows: Escape stops a wait at once", function()
			local owner, world = harness(catalogue, vocabulary, { ["/cfg/workflows.json"] = file_of({
				{ kind = "wait", duration_ms = 5000 }, { kind = "notify", text = "never" } }) })
			owner.run({ id = "wf_1" })
			helpers.assert_eq(owner.is_running("wf_1"), true)
			helpers.assert_eq(owner.run({ id = "wf_1" }), false, "a second trigger is ignored")
			helpers.assert_eq(owner.abort_all(), 1)
			helpers.assert_eq(owner.is_running(), false)
			for _, timer in ipairs(world.timers) do helpers.assert_eq(timer.live, false) end
			helpers.assert_true(world.notices[1]:find("<workflows.notice.aborted>Mine", 1, true) ~= nil, world.notices[1])
		end)

		helpers.it("workflows: a shell step runs at once with the variables in its environment", function()
			local steps = { { kind = "set_variable", name = "who", value = "; rm -rf ~" },
				{ kind = "shell", command = "echo \"$ERGOPTI_VAR_who\"", into = "out" }, { kind = "type_text", text = "{{out}}" } }
			local owner, world = harness(catalogue, vocabulary, { ["/cfg/workflows.json"] = file_of(steps) })
			owner.run({ id = "wf_1" })
			helpers.assert_eq(world.calls[1].name, "shell", "a workflow the user made asks nothing")
			helpers.assert_eq(world.calls[1].args[1], "echo \"$ERGOPTI_VAR_who\"")
			helpers.assert_eq(world.calls[1].args[2].ERGOPTI_VAR_who, "; rm -rf ~")
			helpers.assert_eq(world.calls[1].args[3], 30)
			helpers.assert_eq(world.calls[2].args[1], "out")
			helpers.assert_eq(world.files["/cfg/workflow_approvals.json"], nil, "running writes no approval")
		end)

		helpers.it("workflows: an imported shell step without approval asks nothing and runs nothing", function()
			local owner, world = harness(catalogue, vocabulary, { ["/cfg/workflows.json"] = file_of({
				{ kind = "shell", command = "true" } }, "import") })
			owner.run({ id = "wf_1" })
			helpers.assert_eq(#world.calls, 0)
			helpers.assert_true(world.notices[1]:find("<workflows.reason.shell_not_approved>", 1, true) ~= nil, world.notices[1])
		end)

		helpers.it("workflows: the store refuses to save an invalid file and lists the choices", function()
			local owner, world = harness(catalogue, vocabulary, {})
			local saved, refusal = owner.store.save(Json.decode_lossless('{"schema_version":1,"workflows":[{"id":"x y"}]}'))
			helpers.assert_eq(saved, false)
			helpers.assert_eq(refusal.reason, "missing_field")
			helpers.assert_eq(world.files["/cfg/workflows.json"], nil)
			helpers.assert_eq(owner.store.save(Json.decode_lossless(file_of({}))), true)
			local choices = owner.choices()
			helpers.assert_eq(choices[1].value, "wf_1")
			helpers.assert_eq(choices[1].label, "Mine")
		end)

		helpers.it("workflows: the environment names carry the prefix", function()
			helpers.assert_eq(Effects.environment({ a = "1" }).ERGOPTI_VAR_a, "1")
		end)
	end)
end

return M
