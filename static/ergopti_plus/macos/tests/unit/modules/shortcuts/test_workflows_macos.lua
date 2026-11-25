--- tests/unit/modules/shortcuts/test_workflows_macos.lua

--- ==============================================================================
--- MODULE: User Workflows (macOS)
--- DESCRIPTION:
--- Runs the macOS workflow owner against recording services: the stored
--- workflow runs through the gesture registry's synthetic input, `open` and
--- the clipboard adapter, a shell step runs under /usr/bin/env with its
--- variables as argv with no prompt, Escape stops
--- a run, a click at coordinates reaches the synthetic click owner (and its
--- refusal stops the run with a notice), and the binding editor offers the
--- workflows by name.
---
--- ROOT CAUSE ENCODED:
--- The run_workflow action had no macOS owner: nothing read workflows.json,
--- ran a step, or stopped a run on Escape.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")

local FILES = {}

--- Fresh owner over recording services.
--- @param overrides table|nil
--- @return table Workflows, table world
local function fixture(overrides)
	package.loaded["modules.shortcuts.workflows"] = nil
	local Workflows = require("modules.shortcuts.workflows")
	local world = { runs = {}, sent = {}, typed = {}, notices = {}, timers = {}, clicked = nil }
	local vocabulary
	do
		local file = assert(io.open(helpers.shared("shortcuts/data/actions/send_keys.json"), "rb"))
		vocabulary = Json.decode(file:read("*a")); file:close()
	end
	local deps = {
		shell = { run = function(program, args, on_done)
			world.runs[#world.runs + 1] = { program = program, args = args }
			on_done(true, "hello")
			return true, { terminate = function() world.terminated = true end }
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
				if path:find("_shared", 1, true) then
					local file = io.open(path, "rb")
					if not file then return nil, "absent" end
					local text = file:read("*a"); file:close()
					return text, "ok"
				end
				if FILES[path] == nil then return nil, "absent" end
				return FILES[path], "ok"
			end,
			write = function(path, text) FILES[path] = text; return true end,
		},
		paths = { get_config_dir = function() return "/cfg" end },
		shared_paths = { shared = function(relative) return helpers.shared(relative) end },
		actions = function() return {
			send_vocabulary = function() return vocabulary end,
			send_input_value = function(_, combo) world.sent[#world.sent + 1] = combo; return true end,
			type_text = function(text) world.typed[#world.typed + 1] = text; return true end,
			get_action_parameter_spec = function() return nil end,
			execute_single = function() return true end,
		} end,
		clipboard = { read = function() return "clip" end, write = function() return true end },
		mouse = { setPos = function() return true end },
		click = { click = function(x, y, button, count)
			world.clicked = { x = x, y = y, button = button, count = count }
			return world.click_refused ~= true
		end },
		notifications = { notify = function(text) world.notices[#world.notices + 1] = text; return true end },
		window_info = { frontmost_application = function() return { pid = 1, bundle_id = "com.apple.Safari" } end },
		i18n = { get = function(key) return key end },
		vision_session = {
			cache_dir = function() return "/cache/vision" end,
			service = function() return {
				capture_window = function(window, done)
					world.captured = window
					done({ source = "/cache/vision/capture_1.png", scale = 2, frame = { x = 10, y = 20, width = 100, height = 50 } })
				end,
				capture_region = function(rect, done)
					world.region = rect
					done({ source = "/cache/vision/capture_2.png", scale = 2, frame = rect })
				end,
				match = function(_, templates, _, done)
					world.template = templates[1]
					done({ { id = templates[1].id, x = 40, y = 20, width = 8, height = 8, score = 1, scale = 1 } }, {})
				end,
				find_text = function() return {} end,
			} end,
		},
		screen_ports = function() return {
			foreground = function() return { window = 77 } end,
			languages = function() return { "fr-FR" } end,
			now_ms = function() return 0 end,
		} end,
	}
	deps.mouse.getMonitorBounds = function() return { left = 0, top = 0, right = 1440, bottom = 900 } end
	for key, value in pairs(overrides or {}) do deps[key] = value end
	Workflows.init(deps)
	return Workflows, world
end

--- @param steps table
local function store(steps)
	for key in pairs(FILES) do FILES[key] = nil end
	FILES["/cfg/workflows.json"] = Json.encode({ schema_version = 1, workflows = Json.array({
		{ id = "wf_1", name = "Mine", origin = "local", steps = Json.array(steps) } }) })
end

helpers.describe("workflows on macOS (workflows-macos)", function()
	helpers.it("keys, text, open and the shell step reach the macOS services (workflows-macos)", function()
		store({ { kind = "send_keys", combo = "primary+a" }, { kind = "open", target_kind = "app", value = "Safari" },
			{ kind = "set_variable", name = "n", value = "x" }, { kind = "shell", command = "echo $ERGOPTI_VAR_n", into = "o" },
			{ kind = "type_text", text = "{{o}}" } })
		local Workflows, world = fixture()
		helpers.assert_eq(Workflows.run({ id = "wf_1" }), true)
		helpers.assert_eq(world.sent[1], "primary+a")
		helpers.assert_eq(table.concat(world.runs[1].args, "|"), "-a|Safari")
		helpers.assert_eq(world.runs[2].program, "/usr/bin/env")
		helpers.assert_eq(table.concat(world.runs[2].args, "|"), "ERGOPTI_VAR_n=x|/bin/sh|-l|-c|echo $ERGOPTI_VAR_n")
		helpers.assert_eq(world.typed[1], "hello")
		helpers.assert_eq(FILES["/cfg/workflow_approvals.json"], nil, "no prompt, no approval")
		Workflows.stop()
	end)

	helpers.it("a click at coordinates reaches the click owner (workflows-macos)", function()
		store({ { kind = "mouse_click", x = 12, y = 34, button = "right", count = 2 }, { kind = "notify", text = "done" } })
		local Workflows, world = fixture()
		Workflows.run({ id = "wf_1" })
		helpers.assert_eq(world.clicked.x, 12)
		helpers.assert_eq(world.clicked.y, 34)
		helpers.assert_eq(world.clicked.button, "right")
		helpers.assert_eq(world.clicked.count, 2)
		helpers.assert_eq(world.notices[1], "done", "the run goes on after the click")
		Workflows.stop()
	end)

	helpers.it("a refused click stops the run with a notice (workflows-macos)", function()
		store({ { kind = "mouse_click", x = 1, y = 1 } })
		local Workflows, world = fixture()
		world.click_refused = true
		Workflows.run({ id = "wf_1" })
		helpers.assert_eq(world.clicked.button, "left", "the default button")
		helpers.assert_eq(world.clicked.count, 1, "the default count")
		helpers.assert_true(world.notices[1]:find("workflows.notice.failed", 1, true) ~= nil, tostring(world.notices[1]))
		Workflows.stop()
	end)

	helpers.it("an embedded image is clicked where the front window shows it (workflows-macos)", function()
		store({ { kind = "click_target", target = { type = "image", image = "send" } } })
		local workflows = Json.decode(FILES["/cfg/workflows.json"])
		workflows.workflows[1].images = { send = "iVBORw0KGgoAAAA=" }
		FILES["/cfg/workflows.json"] = Json.encode(workflows)
		local Workflows, world = fixture()
		Workflows.run({ id = "wf_1" })
		helpers.assert_eq(world.captured, 77)
		helpers.assert_eq(world.template.path, "/cache/vision/workflow_template_1.png")
		helpers.assert_true(FILES["/cache/vision/workflow_template_1.png"]:sub(1, 4) == "\137PNG", "the PNG is written")
		helpers.assert_eq(world.clicked.x, 32)
		helpers.assert_eq(world.clicked.y, 32)
		helpers.assert_eq(world.clicked.count, 1)
		helpers.assert_eq(#world.notices, 0, tostring(world.notices[1]))
		Workflows.stop()
	end)

	helpers.it("a whole-screen capture stores its private file (workflows-macos)", function()
		store({ { kind = "capture", mode = "full", into = "shot" }, { kind = "type_text", text = "{{shot}}" } })
		local Workflows, world = fixture()
		Workflows.run({ id = "wf_1" })
		helpers.assert_eq(world.region.width, 1440)
		helpers.assert_eq(world.typed[1], "/cache/vision/capture_2.png")
		Workflows.stop()
	end)

	helpers.it("Escape stops a running wait (workflows-macos)", function()
		store({ { kind = "wait", duration_ms = 9000 } })
		local Workflows, world = fixture()
		Workflows.run({ id = "wf_1" })
		helpers.assert_eq(Workflows.on_escape(), true)
		helpers.assert_eq(world.timers[1].live, false)
		helpers.assert_eq(Workflows.on_escape(), false)
		Workflows.stop()
	end)

	helpers.it("the app-in-front condition reads the frontmost bundle id (workflows-macos)", function()
		store({ { kind = "if", condition = { type = "app_front", app = "safari" },
			["then"] = Json.array({ { kind = "notify", text = "front" } }) } })
		local Workflows, world = fixture()
		Workflows.run({ id = "wf_1" })
		helpers.assert_eq(world.notices[1], "front")
		Workflows.stop()
	end)

	helpers.it("the binding editor offers the workflows by name (workflows-macos)", function()
		local Utils = require("ui.menu.shortcut_utils")
		helpers.assert_eq(type(Utils.ask_workflow_parameter), "function")
	end)
end)
