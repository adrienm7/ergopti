--- tests/unit/modules/shortcuts/test_workflows_linux.lua

--- ==============================================================================
--- MODULE: User Workflows (Linux)
--- DESCRIPTION:
--- Runs the Linux workflow owner against recording OS services: the
--- run_workflow action of the gesture executor reaches the stored workflow,
--- keys go through the uinput send_shortcut handler, a shell step runs under
--- env with its variables as argv and an imported one waits for approval, the pointer steps refuse under Wayland,
--- Escape and the script pause stop a run, and the binding editor offers the
--- workflows by name or says there are none.
---
--- ROOT CAUSE ENCODED:
--- The run_workflow action had no Linux owner: nothing read workflows.json,
--- ran a step, or stopped a run on Escape.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")

local CONFIG = {}

--- Fresh owner over recording services.
--- @param session string|nil XDG_SESSION_TYPE.
--- @return table Workflows, table world
local function fixture(session)
	package.loaded["modules.shortcuts.workflows"] = nil
	local Workflows = require("modules.shortcuts.workflows")
	local world = { runs = {}, sent = {}, typed = {}, notices = {}, timers = {}, files = CONFIG }
	Workflows.init({
		shell = { run_async = function(program, args, options, callback)
			world.runs[#world.runs + 1] = { program = program, args = args, options = options }
			callback({ ok = true, stdout = "hello\n" })
			return { cancel = function() world.cancelled = true end }
		end },
		timer = {
			after = function(sec, fn)
				local timer = { sec = sec, fn = fn, live = true }
				world.timers[#world.timers + 1] = timer
				return timer
			end,
			cancel = function(timer) timer.live = false end,
		},
		file_system = {
			read_with_status = function(path)
				if world.files[path] == nil then return nil, "absent" end
				return world.files[path], "ok"
			end,
			write = function(path, text) world.files[path] = text; return true end,
		},
		settings_paths = { config = function(name) return "/tmp/ergopti-workflows-test/" .. name end },
		shortcuts = {
			send_vocabulary = function() return require("modules.shortcuts.manager").send_vocabulary() end,
			action_handlers = function()
				return { send_shortcut = function(_, combo) world.sent[#world.sent + 1] = combo; return true end }
			end,
			insert_text = function(text) world.typed[#world.typed + 1] = text; return true end,
		},
		gestures = function() return { is_runnable = function() return true end,
			get_action_parameter_spec = function() return nil end, execute_action = function() return true end } end,
		clipboard = { read_checked = function() return true, "clip" end, write = function() return true end },
		notifier = { send = function(text) world.notices[#world.notices + 1] = text; return true end },
		window_info = { getFocused = function() return { appId = "org.mozilla.firefox" } end },
		i18n = { get = function(key) return key end },
		session_type = function() return session or "x11" end,
		rename = function(from, to) world.files[to] = world.files[from]; world.files[from] = nil; return true end,
	})
	return Workflows, world
end

--- Stores one workflow in the fake config folder.
--- @param steps table
local function store(steps)
	for key in pairs(CONFIG) do CONFIG[key] = nil end
	CONFIG["/tmp/ergopti-workflows-test/workflows.json"] = Json.encode({ schema_version = 1, workflows = Json.array({
		{ id = "wf_1", name = "Mine", origin = "local", steps = Json.array(steps) } }) })
end

helpers.describe("workflows on Linux (workflows-linux)", function()
	helpers.it("keys, text and the shell step reach the Linux services (workflows-linux)", function()
		store({ { kind = "send_keys", combo = "ctrl+a" }, { kind = "set_variable", name = "n", value = "x y" },
			{ kind = "shell", command = "echo \"$ERGOPTI_VAR_n\"", into = "out" }, { kind = "type_text", text = "{{out}}!" } })
		local Workflows, world = fixture()
		helpers.assert_eq(Workflows.run({ id = "wf_1" }), true)
		helpers.assert_eq(world.sent[1], "ctrl+a")
		helpers.assert_eq(world.runs[1].program, "env")
		helpers.assert_eq(table.concat(world.runs[1].args, "|"), "ERGOPTI_VAR_n=x y|/bin/sh|-l|-c|echo \"$ERGOPTI_VAR_n\"")
		helpers.assert_eq(world.typed[1], "hello!")
		helpers.assert_eq(CONFIG["/tmp/ergopti-workflows-test/workflow_approvals.json"], nil, "no prompt, no approval")
		Workflows.stop()
	end)

	helpers.it("an imported shell step runs nothing until approved (workflows-linux)", function()
		store({ { kind = "shell", command = "true" } })
		CONFIG["/tmp/ergopti-workflows-test/workflows.json"] = CONFIG["/tmp/ergopti-workflows-test/workflows.json"]
			:gsub('"origin":"local"', '"origin":"import"')
		local Workflows, world = fixture()
		Workflows.run({ id = "wf_1" })
		helpers.assert_eq(#world.runs, 0)
		helpers.assert_true(world.notices[1]:find("workflows.notice.failed", 1, true) ~= nil, tostring(world.notices[1]))
		Workflows.stop()
	end)

	helpers.it("the pointer steps refuse under Wayland, with a notice (workflows-linux)", function()
		store({ { kind = "mouse_click", x = 1, y = 2 } })
		local Workflows, world = fixture("wayland")
		Workflows.run({ id = "wf_1" })
		helpers.assert_eq(#world.runs, 0)
		helpers.assert_eq(#world.notices, 1)
		Workflows.stop()
		store({ { kind = "mouse_click", x = 1, y = 2, button = "right", count = 2 } })
		Workflows, world = fixture("x11")
		Workflows.run({ id = "wf_1" })
		helpers.assert_eq(table.concat(world.runs[1].args, " "), "mousemove 1 2 click --repeat 2 3")
		Workflows.stop()
	end)

	helpers.it("Escape and the pause stop a running wait (workflows-linux)", function()
		store({ { kind = "wait", duration_ms = 5000 }, { kind = "notify", text = "never" } })
		local Workflows, world = fixture()
		Workflows.run({ id = "wf_1" })
		helpers.assert_eq(Workflows.on_escape(), true)
		helpers.assert_eq(Workflows.on_escape(), false)
		for _, timer in ipairs(world.timers) do helpers.assert_eq(timer.live, false) end
		Workflows.run({ id = "wf_1" })
		helpers.assert_eq(Workflows.abort_all(), 1)
		Workflows.stop()
	end)

	helpers.it("the app-in-front condition reads the focused window (workflows-linux)", function()
		store({ { kind = "if", condition = { type = "app_front", app = "Firefox" },
			["then"] = Json.array({ { kind = "notify", text = "front" } }) } })
		local Workflows, world = fixture()
		Workflows.run({ id = "wf_1" })
		helpers.assert_eq(world.notices[1], "front")
		Workflows.stop()
	end)

	helpers.it("a second init with other services is refused (workflows-linux)", function()
		store({})
		local Workflows = fixture()
		helpers.assert_eq(pcall(Workflows.init, {}), false)
		Workflows.stop()
	end)

	helpers.it("the binding editor offers the workflows by name, or says there are none (workflows-linux)", function()
		local Editor = require("ui.user_action_editor")
		helpers.assert_eq(Editor.KINDS.workflow, true)
		local offered
		local value = Editor.ask_workflow("T", "P", nil, {
			workflows = { choices = function() return { { value = "wf_1", label = "Mine" } } end },
			pick = function(_, _, choices) offered = choices; return choices[1].value end,
		})
		helpers.assert_eq(value, "wf_1")
		helpers.assert_eq(offered[1].label, "Mine")
		local told
		helpers.assert_eq(Editor.ask_workflow("T", "P", nil, {
			workflows = { choices = function() return {} end }, notify = function(text) told = text end,
		}), nil)
		helpers.assert_eq(told ~= nil, true)
	end)
end)
