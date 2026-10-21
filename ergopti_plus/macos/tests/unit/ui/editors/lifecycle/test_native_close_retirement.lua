--- tests/unit/ui/editors/lifecycle/test_native_close_retirement.lua

--- ==============================================================================
--- MODULE: Editor Native Window Release
--- DESCRIPTION:
--- Editors discard their Lua owners on user close. The
--- real factory must opt those windows into native reference retirement, while
--- explicit deferred deletion cannot consume a newly opened window.
--- ==============================================================================

local helpers = require("tests.helpers")
require("logger")

--- Runs one real controller and factory over isolated native reference ownership.
--- @param module_name string Window controller to load.
--- @param scenario function Receives controller and native observations.
local function with_window(module_name, scenario)
	local prior_lfs = rawget(_G, "lfs")
	rawset(_G, "lfs", nil)
	local outcome = table.pack(xpcall(function()
		return helpers.with_stub_scope({
			"ui.layer_editor", "ui.action_picker", "ui.webview_controller_pool", "ui.layout_manager", "ui.menu.menu_paths",
			"infra.config_paths", "adapters.program_providers", "program_provider_picker", "modules.keymap.layout_registry",
			"keymap.layer_editor", "keymap.layers", "platform.remap.nav_layer", "infra.keycodes", "adapters.file_system",
			"infra.text_utils", "text_utils", "compat.utf8", "layouts.manager_bridge",

			"adapters.apple_shortcuts", "adapters.apple_shortcuts_native", "adapters.shell_runner", "adapters.task_environment",
			"diagnostics.runtime_log", "platform.remap.lease_helper", "program_parameter",
			"brightness_actions", "brightness_actions_data", "config_migrate", "diagnostics.operation_reporter",
			"infra.fs_dir", "keycodes", "lfs", "module_source_directory", "module_source_identity", "modules.keymap.layout",
			"toml_codec.basic_string", "toml_codec.bom", "toml_codec.key_path", "toml_codec.leaf_rows",
			"toml_codec.record_scanner", "toml_codec.writer",
			"adapters.webview_result", "ui.ui_builder", "ui.webview_close_owner", "adapters.timer_scheduler", "infra.deferred_work", "infra.paced_job", "infra.paced_json",
			"infra.log_folders", "locale.core", "json", "adapters.json_codec", "diagnostics.redact",
			"window_titles", "webview.presentation", "infra.launcher_environment", "adapters.log_transport",
			"app_dirs", "infra.logger", "infra.locale", "_generated.logger_sub_files", "webview.i18n_seed",
			"tests.support.native_webview_close_fixture",
		}, function()
			local h = { windows = {}, retained = {}, deferred = {}, script_refs = {}, timers = {}, bridges = {}, errors = {} }
			local logger = helpers.make_logger_stub()
			logger.error = function(_, message, ...) h.errors[#h.errors + 1] = string.format(message, ...) end
			package.loaded["infra.logger"] = logger
			local construct = require("tests.support.native_webview_close_fixture")(h)
			local function new_window()
				local view = construct()
				function view:frame() assert(not self.disposed); return { x = 0, y = 0, w = 460, h = 380 } end
				function view:evaluateJavaScript()
					assert(not self.disposed, "retired windows cannot receive JavaScript")
					return self
				end
				return view
			end
			package.loaded["adapters.program_providers"] = {}
			package.loaded["modules.keymap.layout_registry"] = { snapshot = function() return { platform = "macos", installed = {} } end }
			package.loaded["infra.config_paths"] = {
				is_initialized = function() return true end,
				get_config_dir = function() return "/virtual/config/" end,
				get_logs_dir = function() return "/virtual/logs/" end,
			}
			local window = helpers.load_with_stubs(module_name, {
				webview = { new = new_window, windowMasks = { titled = 1, closable = 2, resizable = 8 },
					usercontent = { new = function(name)
						local controller = { name = name }
						function controller:setCallback(callback)
							if callback == nil then
								h.detach_calls = (h.detach_calls or 0) + 1
								if h.on_detach then h.on_detach(self) end
								if h.bridge_refusal == "throw" then error("native callback retirement refused") end
								if h.bridge_refusal == "false" then return false end
								if h.bridge_refusal == "nil" then return nil end
								if h.bridge_refusal == "true" then return true end
								h.ack_detaches = (h.ack_detaches or 0) + 1
							end
						self.callback = callback
						h.script_refs[self] = callback
						return self
					end
						h.bridges[#h.bridges + 1] = controller
						return controller
					end } },
				timer = { absoluteTime = function() return 1000000000 end, secondsSinceEpoch = function() return 1 end,
					new = function(delay, receive)
						local timer = { active = false, receive = receive, delay = delay }
						function timer:start() self.active = true; return self end
						function timer:stop() self.active = false; return self end
						function timer:running() return self.active end
						h.timers[#h.timers + 1] = timer
						return timer
					end },
				fs = { dir = function() return function() end, {} end },
				drawing = { windowLevels = { normal = 0, floating = 3 } },
				focus = function() end,
				screen = { mainScreen = function()
					return { frame = function() return { x = 0, y = 0, w = 1400, h = 900 } end }
				end },
			})
			local translations = package.loaded["infra.i18n"]
			local translated = translations.get
			translations.get = function(key, ...)
				if key == "menu.paths.window_title" then return "Folders" end
				return translated(key, ...)
			end
			if module_name == "ui.menu.menu_paths" then assert(window.init("/virtual/app/", function() end)) end
			function h.show()
				if module_name == "ui.layer_editor" then
					return window.open({ karabiner = { regenerate = function() return true end } })
				elseif module_name == "ui.action_picker" then
					return window.open({ title = "Native close fixture", items = {} }, function() return true end)
				elseif module_name == "ui.menu.menu_paths" then return window.open_editor()
				else return window.open() end
			end
			function h.close()
				if module_name == "ui.layer_editor" or module_name == "ui.action_picker" then return window.close() end
				local bridge = h.bridges[#h.bridges]
				bridge.callback({ name = bridge.name, webView = h.windows[#h.windows],
					body = { action = module_name == "ui.layout_manager" and "close" or "cancel" } })
				return true
			end
			function h.drain()
				h.drain_native_close()
			end
			scenario(window, h)
		end)
	end, debug.traceback))
	rawset(_G, "lfs", prior_lfs)
	if not outcome[1] then error(outcome[2], 0) end
end

helpers.describe("editor close retires native references", function()
	for _, module_name in ipairs({ "ui.layer_editor", "ui.action_picker", "ui.layout_manager", "ui.menu.menu_paths" }) do
		helpers.it("retires native user close and reopens " .. module_name, function()
			with_window(module_name, function(_, h)
				helpers.assert_true(h.show(), table.concat(h.errors, "\n"))
				local first = h.windows[1]
				first:user_close()
				h.drain()
				helpers.assert_nil(h.retained[first], "dropping an editor's Lua owner cannot release native udRef")
				helpers.assert_eq(first.deletes, 1, "user close owns one deferred native delete")
				helpers.assert_true(h.show(), table.concat(h.errors, "\n"))
				local successor = h.windows[2]
				helpers.assert_true(h.retained[successor])
				helpers.assert_eq(successor.disposed, false)
				helpers.assert_true(h.close())
				h.drain()
				helpers.assert_nil(next(h.retained))
			end)
		end)
		helpers.it("keeps deferred explicit deletion exact for " .. module_name, function()
			with_window(module_name, function(_, h)
				helpers.assert_true(h.show(), table.concat(h.errors, "\n"))
				local first = h.windows[1]
				helpers.assert_true(h.close())
				helpers.assert_true(h.retained[first], "visible native delete must await its fade completion")
				helpers.assert_eq(first.deletes, 1)
				helpers.assert_true(h.show(), table.concat(h.errors, "\n"))
				local successor = h.windows[2]
				h.drain()
				helpers.assert_nil(h.retained[first])
				helpers.assert_true(h.retained[successor], "old deletion must preserve the reopened editor")
				helpers.assert_eq(successor.disposed, false)
				helpers.assert_true(h.close())
				h.drain()
				helpers.assert_nil(next(h.retained))
			end)
		end)
	end
end)

--- Decorates only this native layout-manager world with observable GC metatables.
local function with_refused_layout(scenario)
	with_window("ui.layout_manager", function(editor, h)
		h.policy_refuses_after_call = 2
		local create = hs.webview.new
		hs.webview.new = function(...)
			local view = create(...)
			setmetatable(view, {})
			local user_close, delete = view.user_close, view.delete
			function view:user_close()
				user_close(self)
				if self.disposed then setmetatable(self, nil) end
			end
			function view:delete()
				h.delete_attempts = (h.delete_attempts or 0) + 1
				if h.on_delete then h.on_delete() end
				if h.delete_refusal == "throw" then error("native delete refused before GC") end
				if h.delete_refusal == "false" then return false end
				delete(self)
				if self.disposed then setmetatable(self, nil) end
				if h.throw_after_gc then error("native delete raised after consuming userdata") end
			end
			return view
		end
		scenario(editor, h)
	end)
end

--- Reopens and explicitly closes a healthy successor after rollback settlement.
local function healthy_layout_successor(h)
	h.policy_refuses, h.delete_refusal, h.throw_after_gc, h.on_delete = nil, nil, nil, nil
	helpers.assert_true(h.show(), table.concat(h.errors, "\n"))
	helpers.assert_eq(#h.windows, 2)
	helpers.assert_true(h.windows[1].disposed)
	helpers.assert_true(h.retained[h.windows[2]])
	helpers.assert_true(h.close())
	h.drain()
	helpers.assert_nil(next(h.retained))
end

helpers.describe("layout manager settles refused factory candidates", function()
	for _, refusal in ipairs({ "throw", "false", "nil" }) do
		helpers.it("retires the published layout candidate after policy " .. refusal, function()
			with_refused_layout(function(_, h)
				h.policy_refuses = refusal
				helpers.assert_eq(h.show(), false)
				helpers.assert_eq(#h.windows, 1, "the required native mutation must actually be reached")
				helpers.assert_true(h.windows[1].disposed)
				helpers.assert_nil(h.retained[h.windows[1]])
				helpers.assert_eq(h.delete_attempts, 1)
				healthy_layout_successor(h)
			end)
		end)
	end
	for _, refusal in ipairs({ "throw", "false" }) do
		helpers.it("retains exact layout rollback debt after delete " .. refusal, function()
			with_refused_layout(function(_, h)
				h.policy_refuses, h.delete_refusal = "false", refusal
				helpers.assert_eq(h.show(), false)
				helpers.assert_eq(h.delete_attempts, 1)
				helpers.assert_true(h.retained[h.windows[1]])
				helpers.assert_eq(h.show(), false, "unsettled debt must block a successor allocation")
				helpers.assert_eq(#h.windows, 1)
				helpers.assert_eq(h.delete_attempts, 2, "retry the same native candidate")
				healthy_layout_successor(h)
			end)
		end)
	end
	helpers.it("does not retry a layout userdata consumed before native delete throws", function()
		with_refused_layout(function(_, h)
			h.policy_refuses, h.throw_after_gc = "false", true
			helpers.assert_eq(h.show(), false)
			helpers.assert_eq(h.delete_attempts, 1)
			helpers.assert_nil(getmetatable(h.windows[1]))
			helpers.assert_nil(h.retained[h.windows[1]])
			healthy_layout_successor(h)
			helpers.assert_eq(h.windows[1].deletes, 1, "the consumed old userdata must never be deleted again")
		end)
	end)
	helpers.it("fences layout reopen during exact native rollback", function()
		with_refused_layout(function(_, h)
			local reentered
			h.policy_refuses = "false"
			h.on_delete = function() reentered = h.show() end
			helpers.assert_eq(h.show(), false)
			helpers.assert_eq(reentered, false, "rollback cannot admit or revoke its own successor")
			helpers.assert_eq(#h.windows, 1)
			healthy_layout_successor(h)
		end)
	end)
end)

--- Closes through native chrome or the actual editor action before fade settlement.
local function close_callback_editor(h, mode)
	if mode == "native" then h.windows[1]:user_close() else h.close() end; h.drain()
	h.drain()
	helpers.assert_nil(next(h.retained), "window GC must settle independently of controller callbacks")
end

--- Verifies acknowledged retirement separately from a pooled successor binding.
--- @param module_name string Real controller role.
--- @param h table Native observations.
--- @param controller table Prior native controller.
--- @param before integer Acknowledgements before the healthy retry.
local function assert_prior_callback_retired(module_name, h, controller, before)
	if module_name == "ui.action_picker" or module_name == "ui.layout_manager" then
		helpers.assert_true((h.ack_detaches or 0) > before, "old callback requires exact native acknowledgement")
		helpers.assert_eq(#h.bridges, 1, "a new pooled lease reuses the same retained native UCC")
		helpers.assert_type(h.script_refs[controller], "function", "the successor owns the rebound dispatcher")
	else helpers.assert_nil(h.script_refs[controller]) end
end

helpers.describe("editor native message callbacks retire independently of windows", function()
	for _, module_name in ipairs({ "ui.action_picker", "ui.layout_manager", "ui.menu.menu_paths" }) do
		for _, mode in ipairs({ "native", "explicit" }) do
			helpers.it(module_name .. " unrefs its script callback after " .. mode .. " close", function()
				with_window(module_name, function(_, h)
					helpers.assert_true(h.show())
					local controller, previous = h.bridges[1], h.script_refs[h.bridges[1]]
					helpers.assert_type(previous, "function")
					close_callback_editor(h, mode)
					helpers.assert_nil(h.script_refs[controller], "native window GC does not unref UCC callbacks")
					helpers.assert_true(h.show())
					local pooled = module_name == "ui.action_picker" or module_name == "ui.layout_manager"
					local successor = pooled and h.bridges[1] or h.bridges[2]
					helpers.assert_type(h.script_refs[successor], "function")
					previous({ body = { action = "cancel" } })
					previous({ name = controller.name, webView = h.windows[1], body = { action = "cancel" } })
					helpers.assert_type(h.script_refs[successor], "function", "old callbacks cannot retire the successor")
					h.close(); h.drain()
					helpers.assert_nil(next(h.script_refs))
				end)
			end)
			helpers.it(module_name .. " retains exact script debt after " .. mode .. " close", function()
				for _, refusal in ipairs({ "false", "throw", "nil", "true" }) do
					with_window(module_name, function(_, h)
						helpers.assert_true(h.show())
						local controller, previous = h.bridges[1], h.script_refs[h.bridges[1]]
						h.bridge_refusal = refusal
						close_callback_editor(h, mode)
						helpers.assert_true(h.script_refs[controller] == previous)
						local attempts = h.detach_calls
						previous({ body = { action = "cancel" } })
						helpers.assert_eq(h.detach_calls, attempts, "a retired bridge cannot run business or cleanup")
						helpers.assert_eq(h.show(), false, "an unacknowledged bridge must block successor admission")
						helpers.assert_eq(#h.windows, 1)
						h.bridge_refusal = nil
						local before_ack = h.ack_detaches or 0
						helpers.assert_true(h.show())
						assert_prior_callback_retired(module_name, h, controller, before_ack)
						helpers.assert_eq(#h.windows, 2)
						h.close(); h.drain()
						helpers.assert_nil(next(h.script_refs))
					end)
				end
			end)
		end
		helpers.it(module_name .. " fences reopen while its exact callback is being unrefed", function()
			with_window(module_name, function(_, h)
				helpers.assert_true(h.show())
				local reopened
				h.on_detach = function() reopened = h.show() end
				close_callback_editor(h, "native")
				helpers.assert_eq(reopened, false)
				helpers.assert_eq(#h.windows, 1)
				h.on_detach = nil
				helpers.assert_true(h.show())
				h.close(); h.drain()
				helpers.assert_nil(next(h.script_refs))
			end)
		end)
	end
end)

helpers.describe("editor bridge retirement without a native candidate", function()
	for _, module_name in ipairs({ "ui.action_picker", "ui.layout_manager", "ui.menu.menu_paths" }) do
		for _, refusal in ipairs({ "nil", "false" }) do
			helpers.it(module_name .. " retires a bound bridge when native creation returns " .. refusal, function()
				with_window(module_name, function(_, h)
					local construct = hs.webview.new
					hs.webview.new = function() if refusal == "false" then return false end end
					helpers.assert_eq(h.show(), false)
					helpers.assert_eq(#h.windows, 0)
					helpers.assert_nil(next(h.script_refs), "a native construction refusal cannot orphan its controller")
					hs.webview.new = construct
					helpers.assert_true(h.show())
					h.close(); h.drain()
					helpers.assert_nil(next(h.script_refs))
				end)
			end)
		end
		helpers.it(module_name .. " retains unref debt before a native candidate exists", function()
			for _, refusal in ipairs({ "false", "throw", "nil", "true" }) do
				with_window(module_name, function(_, h)
					local construct = hs.webview.new
					hs.webview.new = function() return nil end
					h.bridge_refusal = refusal
					helpers.assert_eq(h.show(), false)
					local bridge = h.bridges[1]
					helpers.assert_type(h.script_refs[bridge], "function")
					hs.webview.new = construct
					helpers.assert_eq(h.show(), false)
					helpers.assert_eq(#h.windows, 0)
					helpers.assert_eq(#h.bridges, 1, "retry must own the exact old bridge before allocating")
					h.bridge_refusal = nil
					local before_ack = h.ack_detaches or 0
					helpers.assert_true(h.show())
					assert_prior_callback_retired(module_name, h, bridge, before_ack)
					h.close(); h.drain()
					helpers.assert_nil(next(h.script_refs))
				end)
			end
		end)
	end
end)

helpers.describe("layout bridge retirement survives native construction exceptions", function()
	for _, mode in ipairs({ "frame", "constructor" }) do
		helpers.it("retires the exact layout callback after a native " .. mode .. " exception", function()
			with_window("ui.layout_manager", function(_, h)
				local boundary = mode == "frame" and hs.screen or hs.webview
				local key = mode == "frame" and "mainScreen" or "new"
				local original = boundary[key]
				boundary[key] = function() error("native " .. mode .. " failure marker") end
				helpers.assert_eq(h.show(), false)
				helpers.assert_nil(next(h.script_refs))
				local logged = false
				for _, message in ipairs(h.errors) do
					if message:find("native " .. mode .. " failure marker", 1, true) then logged = true end
				end
				helpers.assert_true(logged, "native exception diagnostics must retain the original cause")
				boundary[key] = original
				helpers.assert_true(h.show(), "an exception must not permanently fence the healthy successor")
				h.close(); h.drain()
				helpers.assert_nil(next(h.script_refs))
			end)
		end)
	end
end)
