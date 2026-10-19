--- tests/unit/ui/editors/physical/test_picker_refusal.lua

--- Exercises genuine editor/window/picker callbacks over an exact file receipt.
local helpers = require("tests.helpers")
local Writer = require("toml_codec.writer")
require("adapters.shell_runner")
require("ui.physical_shortcuts.bridge")
require("ui.action_picker.bridge")

local function with_editor(body)
	local names = { "ui.physical_shortcuts.bridge", "ui.action_picker.bridge", "ui.webview_manager",
		"modules.gestures.manager", "adapters.keyboard_hook", "adapters.program_providers", "infra.i18n",
		"ui.text_prompt", "ui.app_chooser", "logger.shim" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = { package.loaded[name] } end
	local path = os.tmpname()
	local function write(text)
		local file = assert(io.open(path, "wb")); assert(file:write(text)); assert(file:close())
	end
	write("# displayed source\n")
	local bytes, status = Writer.read_classified(path)
	local source = { content = assert(bytes), status = status }
	local state = { notices = {}, scripts = {}, writes = 0, errors = 0, prompts = 0 }
	local epochs, serial, host = {}, 0, nil
	local manager = { native_available = function() return true end }
	function manager.current_epoch(app) return epochs[app] end
	function manager.page_current(app, epoch)
		local current = epochs[app] == epoch
		if state.on_page then state.on_page(app) end
		return current
	end
	function manager.eval_js(app, script)
		state.scripts[#state.scripts + 1] = { app = app, script = script }
		if state.on_send then state.on_send(app, script) end
		return state.send_refused ~= true
	end
	function manager.show(app)
		serial = serial + 1; epochs[app] = serial
		if app == "physical_shortcuts" then return host.on_window_acquiring(serial) end
		return true
	end
	function manager.hide(app, epoch)
		if epoch ~= nil and epochs[app] ~= epoch then return false end
		local old = epochs[app]; epochs[app] = nil
		if app == "physical_shortcuts" then host.on_window_closed(old) end
		return true
	end
	function manager.is_visible(app) return epochs[app] ~= nil end
	local daemon = { notify_error = function(key)
		state.notices[#state.notices + 1] = key
		if state.on_notice then state.on_notice() end
	end }
	function manager.get_daemon_state() return daemon end
	local scope = { physical_delivery_available = function() return true end,
		capture_editor_inventory = function() return { assignments = {}, parameters = {} }, source end,
		editor_source_current = function(receipt)
			local now, kind = Writer.read_classified(path)
			return receipt == source and now == source.content and kind == source.status
		end,
		edit = function() state.writes = state.writes + 1; return true end }
	local catalogue = {
		get_action_label = function(action) return action end,
		is_assignable = function(action) return action == "copy" or action == "send_text" or action == "open_app" end,
		get_action_parameter_spec = function(action)
			if action == "send_text" then return "text" elseif action == "open_app" then return "app" end
		end,
		get_action_parameter_prompt = function() return "existing prompt" end,
		get_action_parameter = function() return "" end,
		validate_action_parameter = function(_, parameter) return type(parameter) == "string" and parameter ~= "" end,
		split_action_parameter_key = function(key) return key:match("^(keyboard__.+)__(.+)$") end,
		get_picker_items = function() return {} end, get_picker_parameter_fields = function() return {} end,
	}
	local called, detail = xpcall(function()
		package.loaded["ui.webview_manager"], package.loaded["modules.gestures.manager"] = manager, catalogue
		package.loaded["adapters.keyboard_hook"] = { position_capture_available = function() return false end }
		package.loaded["adapters.program_providers"] = {}
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		local logger = helpers.make_logger_stub()
		logger.error = function() state.errors = state.errors + 1 end
		package.loaded["logger.shim"] = logger
		package.loaded["ui.text_prompt"] = { ask = function()
			state.prompts = state.prompts + 1
			if state.on_prompt then state.on_prompt() end
			return state.parameter
		end }
		package.loaded["ui.app_chooser"] = { pick = package.loaded["ui.text_prompt"].ask }
		host = helpers.load_module("ui.physical_shortcuts.bridge")
		local picker = helpers.load_module("ui.action_picker.bridge")
		function state.open()
			helpers.assert_true(host.open({ scope = scope, is_paused = function() return false end }))
			helpers.assert_true(host.on_message({ action = "ready" }, daemon,
				{ app_name = "physical_shortcuts", epoch = epochs.physical_shortcuts }))
		end
		function state.choose()
			return host.on_message({ action = "choose", request = { code = "KeyJ", mods = {}, request_id = 1 } },
				daemon, { app_name = "physical_shortcuts", epoch = epochs.physical_shortcuts })
		end
		function state.confirm(action)
			picker.on_message({ action = "confirm", id = action or "copy" }, daemon,
				{ close_owned_window = function() return manager.hide("action_picker", epochs.action_picker) end })
		end
		function state.count(prefix)
			local count = 0
			for _, row in ipairs(state.scripts) do
				if row.app == "physical_shortcuts" and row.script:sub(1, #prefix) == prefix then count = count + 1 end
			end
			return count
		end
		function state.read() return Writer.read_classified(path) end
		function state.external()
			local file = assert(io.open(path .. ".external", "wb"))
			assert(file:write("# external winner\n")); assert(file:close()); assert(os.rename(path .. ".external", path))
		end
		state.host, state.picker, state.daemon, state.manager = host, picker, daemon, manager
		state.open(); helpers.assert_true(state.choose()); body(state)
		state.on_page, state.on_send, state.on_prompt, state.on_notice = nil, nil, nil, nil
		if picker.is_open() then picker.on_message({ action = "cancel" }, daemon) end
		helpers.assert_true(host.close())
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name][1] end
	os.remove(path); os.remove(path .. ".external")
	if not called then error(detail, 0) end
end

helpers.describe("Physical shortcut picker refusal feedback", function()
	helpers.it("reports a stale real-file choice once while preserving its source and runtime", function()
		with_editor(function(state)
			state.external(); state.confirm(); state.confirm()
			helpers.assert_eq(#state.notices, 1)
			helpers.assert_eq(state.notices[1], "physical_shortcuts.save_failed")
			helpers.assert_eq(state.count('refused("save_failed")'), 1)
			helpers.assert_eq(state.count("selected("), 0)
			helpers.assert_eq(state.writes, 0)
			helpers.assert_eq(state.read(), "# external winner\n")
			helpers.assert_eq(state.errors, 0)
			helpers.assert_true(state.picker.is_open())
		end)
	end)
	helpers.it("retains successful draft selection without errors or premature writes", function()
		with_editor(function(state)
			state.confirm()
			helpers.assert_eq(state.count("selected("), 1)
			helpers.assert_eq(#state.notices, 0)
			helpers.assert_eq(state.errors, 0)
			helpers.assert_eq(state.writes, 0)
			helpers.assert_eq(state.picker.is_open(), false)
		end)
	end)
	for _, action in ipairs({ "send_text", "open_app" }) do
		helpers.it("keeps native parameter cancellation silent for " .. action, function()
			with_editor(function(state)
				state.confirm(action)
				helpers.assert_eq(state.prompts, 1)
				helpers.assert_eq(#state.notices, 0)
				helpers.assert_eq(state.count("refused("), 0)
				helpers.assert_eq(state.count("selected("), 0)
				helpers.assert_eq(state.writes, 0)
			end)
		end)
	end
	helpers.it("keeps the action-picker Cancel silent", function()
		with_editor(function(state)
			state.picker.on_message({ action = "cancel" }, state.daemon)
			helpers.assert_eq(#state.notices, 0)
			helpers.assert_eq(state.count("refused("), 0)
		end)
	end)
	helpers.it("does not notify after the original editor closes during a native parameter prompt", function()
		with_editor(function(state)
			state.parameter = "typed"
			state.on_prompt = function() helpers.assert_true(state.host.close()) end
			state.confirm("send_text")
			helpers.assert_eq(#state.notices, 0)
			helpers.assert_eq(state.count("refused("), 0)
		end)
	end)
	helpers.it("does not adopt a notification callback replaced during publication", function()
		with_editor(function(state)
			state.external()
			local foreign = 0
			state.on_send = function(_, script)
				if script:match("^refused%(") then state.daemon.notify_error = function() foreign = foreign + 1 end end
			end
			state.confirm()
			helpers.assert_eq(foreign, 0)
			helpers.assert_eq(#state.notices, 0)
		end)
	end)
	helpers.it("fences a successor opened during refused-response publication", function()
		with_editor(function(state)
			state.external()
			state.on_send = function(_, script)
				if script:match("^refused%(") then
					state.on_send = nil; helpers.assert_true(state.host.close()); state.open()
				end
			end
			state.confirm()
			helpers.assert_eq(#state.notices, 0)
			helpers.assert_eq(state.count("selected("), 0)
		end)
	end)
	helpers.it("contains a notification observer exception without retry spam", function()
		with_editor(function(state)
			state.external(); state.on_notice = function() error("observer failure") end
			state.confirm(); state.confirm()
			helpers.assert_eq(#state.notices, 1)
			helpers.assert_eq(state.errors, 0)
		end)
	end)
	helpers.it("keeps notification feedback when native draft publication is refused", function()
		with_editor(function(state)
			state.send_refused = true; state.confirm(); state.confirm()
			helpers.assert_eq(#state.notices, 1)
			helpers.assert_true(state.picker.is_open())
			helpers.assert_eq(state.writes, 0)
			helpers.assert_eq(state.read(), "# displayed source\n")
		end)
	end)
	helpers.it("reserves the notification before a reentrant observer confirms again", function()
		with_editor(function(state)
			state.external(); state.on_notice = function() state.confirm() end
			state.confirm()
			helpers.assert_eq(#state.notices, 1)
			helpers.assert_eq(state.count('refused("save_failed")'), 1)
			helpers.assert_eq(state.count("selected("), 0)
		end)
	end)
	helpers.it("retains an inline refusal when no desktop notification port exists", function()
		with_editor(function(state)
			state.daemon.notify_error = nil; state.external(); state.confirm()
			helpers.assert_eq(state.count('refused("save_failed")'), 1)
			helpers.assert_eq(state.count("selected("), 0)
		end)
	end)
end)
