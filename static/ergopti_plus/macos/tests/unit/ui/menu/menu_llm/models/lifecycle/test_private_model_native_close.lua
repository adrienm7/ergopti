--- tests/unit/ui/menu/menu_llm/models/lifecycle/test_private_model_native_close.lua

--- ==============================================================================
--- MODULE: Private Model Dialog Native Close
--- DESCRIPTION:
--- Runs the actual HuggingFace prompt flow and add-model menu action through
--- the real factory. User closure must retire native window references; queued
--- explicit deletion retains its exact predecessor and never consumes a successor.
--- No token validation, model activation or process dispatch is authorized here.
--- ==============================================================================

local helpers = require("tests.helpers")
require("logger")

--- Composes a real private-model UI flow with native-shaped reference ownership.
--- @param kind string hf or custom.
--- @param scenario function Receives the fixture.
local function with_dialog(kind, scenario)
	helpers.with_stub_scope({
		"ui.menu.menu_llm.models_manager_mlx_hf", "ui.menu.menu_llm.models_selector",
		"ui.menu.menu_llm.models_manager_mlx_repo", "ui.menu.menu_llm.backend_labels",
		"adapters.task_environment", "adapters.shell_runner", "compat.utf8", "diagnostics.runtime_log",
		"infra.manifest_menu", "logger.shim", "menu.renderer", "text_utils",
		"ui.ui_builder", "adapters.timer_scheduler", "adapters.task_lifecycle", "infra.deferred_work",
		"infra.log_folders", "locale.core", "json", "adapters.json_codec", "diagnostics.redact",
		"window_titles", "webview.presentation", "infra.launcher_environment", "adapters.log_transport",
		"app_dirs", "infra.logger", "infra.locale", "_generated.logger_sub_files", "webview.i18n_seed",
		"infra.notifications", "infra.dialog_util", "tests.support.native_webview_close_fixture",
	}, function()
		local h = { windows = {}, retained = {}, deferred = {}, bridges = {}, script_refs = {}, timers = {}, terminals = {},
			saved = 0, switched = 0, settled = 0 }
		local construct = require("tests.support.native_webview_close_fixture")(h)
		local module_name = kind == "hf" and "ui.menu.menu_llm.models_manager_mlx_hf"
			or "ui.menu.menu_llm.models_selector"
		local subject = helpers.load_with_stubs(module_name, {
			webview = { windowMasks = { titled = 1, closable = 2 }, new = function()
				local view = construct()
				-- Pinned userdata_gc removes the metatable before releasing native refs.
				setmetatable(view, { __name = "hs.webview" })
				local native_delete, native_close = view.delete, view.user_close
				function view:user_close()
					native_close(self)
					if self.disposed then setmetatable(self, nil) end
				end
				function view:delete()
					if h.delete_refusal == "throw" then error("native delete refused before consumption") end
					if h.delete_refusal == "false" then return false end
					if h.delete_refusal == "nil" then return nil end
					local result = native_delete(self)
					if self.disposed then setmetatable(self, nil) end
					return result
				end
				function view:allowNewWindows() assert(not self.disposed); return self end
				function view:evaluateJavaScript() assert(not self.disposed); return self end
				return view
			end, usercontent = { new = function()
				local bridge = {}
				function bridge:setCallback(callback)
					if callback == nil then
						if h.on_release then h.on_release(self) end
						if h.release_refusal == "throw" then error("native script unref refused") end
						if h.release_refusal == "false" then return false end
						if h.release_refusal == "nil" then return nil end
						if h.release_refusal == "true" then return true end
						if h.release_refusal == "foreign" then return {} end
					end
					self.callback = callback
					h.script_refs[self] = callback
					return self
				end
				h.bridges[#h.bridges + 1] = bridge
				return bridge
			end } },
			timer = { absoluteTime = function() return 1000000000 end, secondsSinceEpoch = function() return 1 end,
				new = function(_, receive)
					local timer = { active = false }
					function timer:start() self.active = true; return self end
					function timer:stop() self.active = false; return self end
					function timer:running() return self.active end
					function timer:deliver() receive() end
					h.timers[#h.timers + 1] = timer
					return timer
				end },
			application = { get = function() return nil end, find = function() return nil end },
			pasteboard = { getContents = function() return "hf_fixture" end },
			task = { new = function() error("private window closure must never validate a token") end },
			drawing = { windowLevels = { normal = 0, floating = 3 } },
			focus = function() end,
			screen = { mainScreen = function()
				return { frame = function() return { x = 0, y = 0, w = 1400, h = 900 } end }
			end },
		})
		if kind == "hf" then
			local manager = {}
			h.manager = manager
			subject.install({ obj = manager, deps = { active_tasks = {} }, presets = {} })
			local provenance = { owner = {}, is_authorized = function()
				if h.on_authorization then h.on_authorization() end
				return true
			end,
				lifecycle = {
					adopt = function(flow) h.flow = flow; return true end,
					settle = function(flow)
						helpers.assert_eq(flow, h.flow)
						h.settled = h.settled + 1
						return true
					end,
				} }
			function h.admit()
				local admitted = manager.prompt_hf_login(function(result) h.terminals[#h.terminals + 1] = result end,
					provenance)
				h.prompt_timer = h.timers[#h.timers]
				return admitted
			end
			function h.deliver_prompt() h.prompt_timer:deliver() end
			function h.show()
				if not h.admit() then return false end
				h.deliver_prompt()
				return h.flow.webview ~= nil
			end
			function h.cancel() h.bridges[#h.bridges].callback({ body = "cancel" }) end
		else
			local menu = subject.build({
				state = { llm_backend = "mlx", llm_model = "", llm_user_models = {} },
				models_mgr = {
					get_installed_models = function() return {} end,
					get_presets = function() return {} end,
					get_model_info = function() end,
					get_model_ram = function() return 0 end,
					is_model_installed = function() return false end,
				},
				switch_model = function() h.switched = h.switched + 1 end,
				disable_model = function() return true end,
				save_prefs = function() h.saved = h.saved + 1; return true end,
				update_menu = function() return true end,
				DEFAULT_STATE = { llm_model_mlx = "", llm_model_ollama = "" },
			})
			for _, item in ipairs(menu) do
				if item.label == "menu.llm.add_model_entry" then h.show = item.action end
			end
			helpers.assert_type(h.show, "function", "the actual custom-model menu action must exist")
			function h.cancel() return h.bridges[#h.bridges].callback({ body = { action = "cancel" } }) end
		end
		function h.drain()
			while #h.deferred > 0 do table.remove(h.deferred, 1)() end
		end
		scenario(h)
	end)
end

helpers.describe("private model dialogs release abandoned native windows", function()
	for _, kind in ipairs({ "hf", "custom" }) do
		helpers.it("retires the user-closed " .. kind .. " model dialog and opens its successor", function()
			with_dialog(kind, function(h)
				helpers.assert_true(h.show())
				local first = h.windows[1]
				first:user_close()
				helpers.assert_nil(h.retained[first], "native udRef outlives a discarded Lua window owner")
				helpers.assert_eq(first.deletes, 0)
				if kind == "hf" then
					helpers.assert_eq(h.terminals, { false })
					helpers.assert_eq(h.settled, 1)
				end
				helpers.assert_true(h.show())
				local successor = h.windows[2]
				helpers.assert_true(h.retained[successor])
				helpers.assert_eq(successor.disposed, false)
				successor:user_close()
				helpers.assert_nil(next(h.retained))
				if kind == "hf" then
					helpers.assert_eq(h.terminals, { false, false })
					helpers.assert_eq(h.settled, 2)
				end
				helpers.assert_eq(h.saved, 0)
				helpers.assert_eq(h.switched, 0)
			end)
		end)

		helpers.it("keeps explicit deferred deletion exact for the " .. kind .. " model dialog", function()
			with_dialog(kind, function(h)
				helpers.assert_true(h.show())
				local first = h.windows[1]
				h.cancel()
				helpers.assert_eq(first.deletes, 1)
				helpers.assert_eq(#h.deferred, 1)
				helpers.assert_true(h.retained[first])
				if kind == "custom" then helpers.assert_true(h.show())
				else helpers.assert_eq(h.show(), false, "the prior auth flow still owns its closing window") end
				h.drain()
				helpers.assert_nil(h.retained[first])
				if kind == "hf" then
					helpers.assert_eq(h.terminals, { false })
					helpers.assert_true(h.show())
				end
				local successor = h.windows[2]
				helpers.assert_true(h.retained[successor])
				helpers.assert_eq(successor.disposed, false)
				h.cancel()
				h.drain()
				helpers.assert_nil(next(h.retained))
				if kind == "hf" then
					helpers.assert_eq(h.terminals, { false, false })
					helpers.assert_eq(h.settled, 2)
				end
				helpers.assert_eq(h.saved, 0)
				helpers.assert_eq(h.switched, 0)
			end)
		end)
	end

	for _, refusal in ipairs({ "throw", "false", "nil" }) do
		helpers.it("settles HF construction after required native setter " .. refusal, function()
			with_dialog("hf", function(h)
				h.policy_refuses = refusal
				helpers.assert_true(h.admit(), "public admission accepts the timer, not a visible window")
				helpers.assert_eq(#h.windows, 0)
				helpers.assert_eq(h.terminals, {})
				h.deliver_prompt()
				local rejected = h.windows[1]
				helpers.assert_eq(rejected.visible, false)
				helpers.assert_eq(rejected.deletes, 1)
				helpers.assert_nil(getmetatable(rejected), "native GC consumed the userdata")
				helpers.assert_nil(h.retained[rejected])
				helpers.assert_nil(h.flow.webview, "consumption without a close callback must retire its exact owner")
				helpers.assert_eq(h.terminals, { false })
				helpers.assert_eq(h.settled, 1)
				h.policy_refuses = nil
				helpers.assert_true(h.admit())
				h.deliver_prompt()
				local successor = h.windows[2]
				helpers.assert_true(successor.visible)
				helpers.assert_true(h.retained[successor])
				h.drain()
				helpers.assert_eq(h.flow.webview, successor)
				successor:user_close()
				helpers.assert_eq(h.terminals, { false, false })
				helpers.assert_eq(h.settled, 2)
				helpers.assert_nil(next(h.retained))
			end)
		end)

		helpers.it("retains HF construction debt when delete returns " .. refusal .. " without consumption", function()
			with_dialog("hf", function(h)
				h.policy_refuses, h.delete_refusal = "false", refusal
				helpers.assert_true(h.admit())
				h.deliver_prompt()
				local rejected = h.windows[1]
				helpers.assert_true(h.retained[rejected])
				helpers.assert_not_nil(getmetatable(rejected))
				helpers.assert_eq(h.flow.webview, rejected)
				helpers.assert_eq(h.terminals, {})
				helpers.assert_eq(h.settled, 0)
				helpers.assert_eq(h.admit(), false, "a real unconsumed native debt blocks its successor")
				h.delete_refusal = nil
				h.flow.close_webview(nil, false)
				helpers.assert_nil(h.flow.webview)
				helpers.assert_eq(h.terminals, { false })
				helpers.assert_eq(h.settled, 1)
				helpers.assert_nil(next(h.retained))
			end)
		end)
	end


	helpers.it("waits for the visible HF fade before settling and admitting its successor", function()
		with_dialog("hf", function(h)
			helpers.assert_true(h.admit())
			h.deliver_prompt()
			local first = h.windows[1]
			helpers.assert_true(first.visible)
			h.cancel()
			helpers.assert_not_nil(getmetatable(first))
			helpers.assert_true(h.retained[first])
			helpers.assert_eq(h.flow.webview, first)
			helpers.assert_eq(h.terminals, {})
			helpers.assert_eq(h.settled, 0)
			helpers.assert_eq(h.admit(), false)
			h.drain()
			helpers.assert_nil(getmetatable(first))
			helpers.assert_nil(h.retained[first])
			helpers.assert_nil(h.flow.webview)
			helpers.assert_eq(h.terminals, { false })
			helpers.assert_eq(h.settled, 1)
			helpers.assert_true(h.admit())
			h.deliver_prompt()
			local successor = h.windows[2]
			helpers.assert_true(successor.visible)
			helpers.assert_eq(h.flow.webview, successor)
			h.drain()
			helpers.assert_true(h.retained[successor])
			successor:user_close()
			helpers.assert_eq(h.terminals, { false, false })
			helpers.assert_eq(h.settled, 2)
			helpers.assert_nil(next(h.retained))
		end)
	end)


	for _, kind in ipairs({ "hf", "custom" }) do
		for _, close in ipairs({ "native", "explicit" }) do
			helpers.it("releases the " .. kind .. " script reference after " .. close .. " close", function()
				with_dialog(kind, function(h)
					helpers.assert_true(h.show())
					local bridge = h.bridges[1]
					helpers.assert_type(h.script_refs[bridge], "function")
					if close == "native" then h.windows[1]:user_close() else h.cancel(); h.drain() end
					helpers.assert_nil(next(h.retained))
					helpers.assert_nil(h.script_refs[bridge], "native window GC never unregisters the script callback")
					helpers.assert_true(h.show())
					helpers.assert_type(h.script_refs[h.bridges[2]], "function")
					h.windows[2]:user_close()
					helpers.assert_nil(next(h.script_refs))
				end)
			end)
		end

		for _, refusal in ipairs({ "throw", "false", "nil", "true", "foreign" }) do
			helpers.it("retains the " .. kind .. " script owner after unref " .. refusal, function()
				with_dialog(kind, function(h)
					helpers.assert_true(h.show())
					local first, bridge = h.windows[1], h.bridges[1]
					local queued = h.script_refs[bridge]
					h.release_refusal = refusal
					first:user_close()
					helpers.assert_nil(h.retained[first])
					helpers.assert_eq(h.script_refs[bridge], queued)
					if kind == "hf" then
						helpers.assert_eq(h.terminals, {})
						helpers.assert_eq(h.settled, 0)
					end
					queued({ body = kind == "hf" and "cancel" or { action = "add", value = "unowned/model" } })
					helpers.assert_eq(h.saved, 0, "retired bridges have no business authority")
					helpers.assert_eq(h.switched, 0)
					helpers.assert_eq(h.show(), false, "unacknowledged unref blocks a successor")
					helpers.assert_eq(#h.windows, 1)
					h.release_refusal = nil
					helpers.assert_true(h.show())
					helpers.assert_nil(h.script_refs[bridge])
					helpers.assert_eq(first.deletes, 0, "controller retry cannot delete its retired window")
					helpers.assert_true(h.retained[h.windows[2]])
					h.windows[2]:user_close()
					helpers.assert_nil(next(h.script_refs))
					helpers.assert_nil(next(h.retained))
				end)
			end)
		end

		helpers.it("fences reentrant cleanup and queued callbacks for the " .. kind .. " script owner", function()
			with_dialog(kind, function(h)
				helpers.assert_true(h.show())
				local old = h.script_refs[h.bridges[1]]
				local attempts = 0
				h.on_release = function()
					attempts = attempts + 1
					old({ body = kind == "hf" and "cancel" or { action = "add", value = "unowned/model" } })
					helpers.assert_eq(h.show(), false, "native unref is still on stack")
				end
				h.windows[1]:user_close()
				helpers.assert_eq(attempts, 1)
				helpers.assert_nil(next(h.script_refs))
				helpers.assert_eq(h.saved, 0)
				helpers.assert_eq(h.switched, 0)
				h.on_release = nil
				helpers.assert_true(h.show())
				helpers.assert_type(h.script_refs[h.bridges[2]], "function")
				old({ body = kind == "hf" and "cancel" or { action = "cancel" } })
				helpers.assert_true(h.retained[h.windows[2]])
				h.windows[2]:user_close()
				helpers.assert_nil(next(h.script_refs))
			end)
		end)
	end



	for _, failure in ipairs({ "geometry", "factory" }) do
		helpers.it("releases the custom script owner after " .. failure .. " admission refusal", function()
			with_dialog("custom", function(h)
				local builder = require("ui.ui_builder")
				local geometry = builder.get_app_geometry
				if failure == "geometry" then builder.get_app_geometry = function() return nil end
				else h.policy_refuses = "false" end
				helpers.assert_eq(h.show(), false)
				helpers.assert_nil(next(h.retained))
				helpers.assert_nil(next(h.script_refs), "a rejected window must not orphan its registered script callback")
				helpers.assert_eq(h.saved, 0)
				helpers.assert_eq(h.switched, 0)
				builder.get_app_geometry = geometry
				h.policy_refuses = nil
				helpers.assert_true(h.show())
				local successor = h.windows[#h.windows]
				helpers.assert_true(h.retained[successor])
				successor:user_close()
				helpers.assert_nil(next(h.retained))
				helpers.assert_nil(next(h.script_refs))
			end)
		end)
	end


	helpers.it("keeps HF cleanup retry owned across reentrant token authorization", function()
		with_dialog("hf", function(h)
			helpers.assert_true(h.show())
			local dispatched = 0
			h.manager._process_hf_token = function(token)
				helpers.assert_eq(token, "hf_fixture")
				dispatched = dispatched + 1
				return false
			end
			h.release_refusal = "false"
			h.bridges[1].callback({ body = { type = "validate", token = "hf_fixture" } })
			h.drain()
			helpers.assert_eq(dispatched, 0, "token dispatch waits for exact script unref")
			helpers.assert_nil(next(h.retained))
			helpers.assert_type(h.script_refs[h.bridges[1]], "function")
			local nested
			h.on_authorization = function()
				h.on_authorization = nil
				nested = h.admit()
			end
			h.release_refusal = nil
			helpers.assert_true(h.admit())
			helpers.assert_eq(nested, false, "the retry continuation still owns its callback stack")
			helpers.assert_eq(dispatched, 1)
			helpers.assert_eq(h.terminals, { false })
			helpers.assert_eq(h.settled, 1)
			h.deliver_prompt()
			helpers.assert_true(h.retained[h.windows[2]])
			h.windows[2]:user_close()
			helpers.assert_nil(next(h.script_refs))
		end)
	end)

end)
