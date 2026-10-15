--- tests/unit/ui/menu/test_gesture_picker_parameter_transaction.lua

--- Exercises the actual gesture provider, picker callback and parameter helper.
local helpers = require("tests.helpers")

local function with_picker(options, callback)
	local selected = options.action == nil and "run_program" or options.action
	local scalar = options.scalar == nil and "new scalar" or options.scalar
	local saved = {}
	for name, value in pairs(package.loaded) do saved[name] = value end
	local fixture = { assigned = "none", parameters = { retained = "unrelated" },
		saves = 0, updates = 0, assignments = 0, conflicts = 0, errors = 0 }
	local function copy(source)
		local result = {}
		for key, value in pairs(source) do result[key] = value end
		return result
	end
	local function result(mode)
		if mode == "throw" then error("synthetic refusal") end
		if mode == "nil" then return nil end
		return mode ~= "false"
	end
	local runtime = {
		get_action = function() return fixture.assigned end,
		set_action = function(_, value)
			fixture.assignments = fixture.assignments + 1
			fixture.assigned = value
			if value == selected then return result(options.assign) end
			return true
		end,
		get_action_parameter = function() return fixture.parameters["tap_3__" .. selected] or "" end,
		get_all_action_parameters = function() return copy(fixture.parameters) end,
		replace_action_parameters = function(snapshot)
			fixture.parameters = copy(snapshot)
			return true
		end,
		set_action_parameter = function(binding, action, value)
			fixture.parameters[binding .. "__" .. action] = value
			return result(options.parameter)
		end,
		validate_action_parameter = function(_, value) return value == scalar end,
		get_action_parameter_spec = function(action)
			local row = require("_generated.action_catalogue").actions[action]
			return row and row.parameter
		end,
		get_action_label = function(action) return action end,
		get_sg_names = function() return { "none", selected } end,
		parameter_prompt = function() return "prompt" end,
		parameter_error = function() return "error" end,
		on_action_changed = function() fixture.conflicts = fixture.conflicts + 1 end,
	}
	local picker_callback, provider
	local ok, failure = xpcall(function()
		package.loaded["modules.gestures"] = { DEFAULT_STATE = { gestures = true } }
		package.loaded["ui.menu.menu_utils"] = {}
		package.loaded["infra.i18n"] = { get = function(key) return key end, section = function(key) return key end }
		local logger = helpers.make_logger_stub()
		logger.error = function() fixture.errors = fixture.errors + 1 end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.dialog_util"] = {
			text_prompt = function(_, _, _, confirm, cancel)
				if options.cancel then return cancel end
				return confirm, scalar
			end,
		}
		package.loaded["infra.deferred_work"] = { after = function(_, work) work(); return true end }
		-- The provider's declared child must use a fresh real renderer. Keep
		-- only the original fixture's parent-provider capture controlled.
		local renderer = assert(require("menu.renderer").new({
			platform = "hs",
			manifest_path = function() return helpers.shared("modules/menu/menu_manifest.json") end,
			json_decode = require("json").decode,
			i18n = package.loaded["infra.i18n"], logger = logger,
		}))
		package.loaded["infra.manifest_menu"] = {
			group_receiver = renderer.group_receiver,
			template_rows = renderer.template_rows,
			get_root = function() return { gesture_slots = { ["3"] = { "tap_3" } } } end,
			build = function(_, _, _, _, _, providers) provider = providers.gesture_slots_3; return {} end,
		}
		package.loaded["ui.action_picker"] = { open = function(_, picked) picker_callback = picked end }
		package.loaded["ui.menu.menu_gestures"] = nil
		package.loaded["ui.menu.shortcut_utils"] = nil
		runtime.is_assignable = function() return true end
		local owner = require("tests.support.program_parameter_fixture")(runtime, { gestures = true }, "gesture",
			function() return fixture.assigned end,
			function() fixture.saves = fixture.saves + 1; return result(options.save) end)
		local menu = require("ui.menu.menu_gestures")
		menu.build({ gestures = runtime, state = { gestures = true },
			commit_program_parameter = owner.apply,
			save_prefs = function() error("program must use its fenced owner") end,
			updateMenu = function() fixture.updates = fixture.updates + 1 end,
		})
		local rows = provider()
		helpers.assert_eq(#rows, 1)
		rows[1].items[1].action()
		helpers.assert_type(picker_callback, "function")
		callback(fixture, function()
			if options.cancel then return picker_callback(selected) end
			return picker_callback(selected, scalar)
		end)
	end, debug.traceback)
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not ok then error(failure, 0) end
end

helpers.describe("gesture picker acknowledged parameter transaction", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("does not assign after " .. mode .. " parameter refusal", function()
			with_picker({ parameter = mode }, function(fixture, pick)
				pick()
				helpers.assert_eq(fixture.assignments, 0)
				helpers.assert_eq(fixture.parameters, { retained = "unrelated" })
				helpers.assert_eq(fixture.saves, 0)
				helpers.assert_eq(fixture.updates, 0)
				helpers.assert_eq(fixture.conflicts, 0)
				helpers.assert_true(fixture.errors > 0, "storage refusal must be diagnosed")
			end)
		end)
		helpers.it("restores parameter and assignment after " .. mode .. " preference refusal", function()
			with_picker({ save = mode }, function(fixture, pick)
				pick()
				helpers.assert_eq(fixture.assigned, "none")
				helpers.assert_eq(fixture.parameters, { retained = "unrelated" })
				helpers.assert_eq(fixture.saves, 1)
				helpers.assert_eq(fixture.updates, 0)
				helpers.assert_eq(fixture.conflicts, 0)
			end)
		end)
		helpers.it("restores parameter after " .. mode .. " assignment refusal", function()
			with_picker({ assign = mode }, function(fixture, pick)
				pick()
				helpers.assert_eq(fixture.assigned, "none")
				helpers.assert_eq(fixture.parameters, { retained = "unrelated" })
				helpers.assert_eq(fixture.saves, 0)
				helpers.assert_eq(fixture.updates, 0)
			end)
		end)
	end

	helpers.it("stores and publishes one successful choice", function()
		with_picker({}, function(fixture, pick)
			pick()
			helpers.assert_eq(fixture.assigned, "run_program")
			helpers.assert_eq(fixture.parameters, { retained = "unrelated", tap_3__run_program = "new scalar" })
			helpers.assert_eq(fixture.saves, 1)
			helpers.assert_eq(fixture.conflicts, 1)
		end)
	end)

	helpers.it("preserves both owners when the prompt is cancelled", function()
		with_picker({ cancel = true }, function(fixture, pick)
			pick()
			helpers.assert_eq(fixture.assignments, 0)
			helpers.assert_eq(fixture.parameters, { retained = "unrelated" })
			helpers.assert_eq(fixture.saves, 0)
		end)
	end)
end)


helpers.describe("non-program gesture picker transaction", function()
	for _, stage in ipairs({ "parameter", "assign", "save" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("(action-parameter-atomicity) gesture preserves both owners after " .. stage .. " " .. mode, function()
				with_picker({ action = "open_url", scalar = "https://example.com", [stage] = mode }, function(fixture, pick)
					pick()
					helpers.assert_eq(fixture.assigned, "none")
					helpers.assert_eq(fixture.parameters, { retained = "unrelated" })
					helpers.assert_eq(fixture.updates, 0)
					helpers.assert_eq(fixture.conflicts, 0)
				end)
			end)
		end
	end
	helpers.it("(action-parameter-atomicity) gesture publishes once and reports the committed choice", function()
		with_picker({ action = "open_url", scalar = "https://example.com" }, function(fixture, pick)
			pick()
			helpers.assert_eq(fixture.assigned, "open_url")
			helpers.assert_eq(fixture.parameters, { retained = "unrelated", tap_3__open_url = "https://example.com" })
			helpers.assert_eq(fixture.saves, 1)
			helpers.assert_eq(fixture.updates, 1)
			helpers.assert_eq(fixture.conflicts, 1)
		end)
	end)
end)
