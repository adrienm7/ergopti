--- tests/unit/ui/editors/lifecycle/test_prompt_bridge_retirement.lua

--- ==============================================================================
--- MODULE: Prompt Editor Native Bridge Retirement
--- DESCRIPTION:
--- Real editor/factory ownership over independent native window and UCC callback
--- registries. Window GC cannot acknowledge callback detachment; refusals retain
--- cleanup-only ownership until that exact controller acknowledges a retry.
--- ==============================================================================

local helpers = require("tests.helpers")
require("logger")

local function with_editor(scenario)
	local prior_lfs = rawget(_G, "lfs")
	rawset(_G, "lfs", nil)
	local result = table.pack(xpcall(function()
		return helpers.with_stub_scope({
			"ui.prompt_editor", "ui.ui_builder", "ui.webview_close_owner", "adapters.timer_scheduler", "adapters.webview_result",
			"infra.deferred_work", "infra.paths", "infra.logger", "infra.locale", "infra.log_folders",
			"locale.core", "json", "adapters.json_codec", "diagnostics.redact", "window_titles",
			"webview.presentation", "infra.launcher_environment", "adapters.log_transport", "app_dirs",
			"_generated.logger_sub_files", "webview.i18n_seed", "tests.support.native_webview_close_fixture",
		}, function()
			local h = { windows = {}, retained = {}, deferred = {}, callbacks = {}, bridges = {}, saves = 0, unbinds = 0, errors = {}, native_delete_calls = 0 }
			local logger = helpers.make_logger_stub()
			logger.error = function(_, text, ...) h.errors[#h.errors + 1] = string.format(text, ...) end
			package.loaded["infra.logger"] = logger
			local construct = require("tests.support.native_webview_close_fixture")(h)
			local function new_window()
				local view = construct()
				setmetatable(view, { __name = "hs.webview" })
				local native_delete, native_close = view.delete, view.user_close
				function view:user_close()
					native_close(self)
					if self.disposed then setmetatable(self, nil) end
				end
				function view:delete()
					h.native_delete_calls = h.native_delete_calls + 1
					if h.delete_refuses then error("native window delete refused before mutation") end
					native_delete(self)
					if self.disposed then setmetatable(self, nil) end
					if self.disposed and h.throw_after_gc then error("native wrapper failed after window GC") end
				end
				view.scripts = {}
				function view:evaluateJavaScript(script) self.scripts[#self.scripts + 1] = script; return self end
				return view
			end
			local editor = helpers.load_with_stubs("ui.prompt_editor", {
				webview = { new = new_window, windowMasks = { titled = 1, closable = 2 }, usercontent = { new = function()
					local bridge = {}
					function bridge:setCallback(callback)
						if callback ~= nil and h.bind_after_throw then
							h.callbacks[self] = callback
							error("native UCC binding raised after registration")
						end
						if callback == nil then
							h.unbinds = h.unbinds + 1
							if h.on_unbind then h.on_unbind(self) end
							if h.refusal == "throw" then error("native UCC detachment refused") end
							if h.refusal == "false" then return false end
							if h.refusal == "nil" then return nil end
							if h.refusal == "other" then return {} end
						end
						h.callbacks[self] = callback
						return self
					end
					h.bridges[#h.bridges + 1] = bridge
					return bridge
				end } },
				drawing = { windowLevels = { normal = 0, floating = 3 } }, focus = function() end,
				screen = { mainScreen = function()
					return { frame = function() return { x = 0, y = 0, w = 1400, h = 900 } end }
				end },
			})
			function h.open(id) return editor.open({ id = id or "A" }, function() h.saves = h.saves + 1; return true end) end
			function h.drain() h.drain_native_close() end
			function h.message(view)
				view.navigation_callback("didFinishNavigation")
				local payload = hs.json.decode(view.scripts[#view.scripts]:match("^init%((.*)%)$"))
				return { body = { action = "save", edit_id = payload.edit_id, epoch = payload.epoch, prompt = "draft" } }
			end
			scenario(editor, h)
		end)
	end, debug.traceback))
	rawset(_G, "lfs", prior_lfs)
	if not result[1] then error(result[2], 0) end
end

helpers.describe("prompt bridge retirement is independent of native window GC", function()
	helpers.it("keeps a live prompt context reusable and persists its healthy successor", function()
		with_editor(function(_, h)
			helpers.assert_true(h.open("A"))
			helpers.assert_true(h.open("B"))
			helpers.assert_eq(#h.windows, 1)
			h.callbacks[h.bridges[1]](h.message(h.windows[1]))
			helpers.assert_eq(h.saves, 1)
			h.drain()
			helpers.assert_nil(next(h.retained))
		end)
	end)
	for _, route in ipairs({ "user", "explicit", "factory refusal" }) do
		helpers.it("detaches its native callback after " .. route .. " close", function()
			with_editor(function(editor, h)
				if route == "factory refusal" then h.policy_refuses = "throw" end
				helpers.assert_eq(h.open(), route ~= "factory refusal")
				if route == "user" then h.windows[1]:user_close()
				h.drain()
				elseif route == "explicit" then helpers.assert_true(editor.close()); h.drain() end
				helpers.assert_nil(next(h.retained), "the window reference has actually retired")
				helpers.assert_nil(next(h.callbacks), "window GC must not stand in for native setCallback(nil)")
				h.policy_refuses = nil
				helpers.assert_true(h.open("B"))
				local bridge = h.bridges[2]
				h.callbacks[bridge](h.message(h.windows[2]))
				helpers.assert_eq(h.saves, 1, "a healthy successor retains working persistence")
				h.drain()
				helpers.assert_nil(next(h.callbacks))
			end)
		end)
	end
	for _, route in ipairs({ "user", "explicit" }) do
		for _, refusal in ipairs({ "throw", "false", "nil", "other" }) do
			helpers.it("retains exact bridge debt after " .. route .. " close receives " .. refusal, function()
				with_editor(function(editor, h)
					helpers.assert_true(h.open())
					local old, message = h.callbacks[h.bridges[1]], h.message(h.windows[1])
					h.refusal = refusal
					if route == "user" then h.windows[1]:user_close()
					h.drain()
					else helpers.assert_eq(editor.close(), false); h.drain() end
					helpers.assert_nil(next(h.retained))
					helpers.assert_eq(editor.scope_idle(), false, "ambiguous native acknowledgement retains cleanup custody")
					helpers.assert_eq(h.open("B"), false)
					helpers.assert_eq(#h.windows, 1)
					helpers.assert_eq(#h.bridges, 1, "retry must address the exact old UCC")
					local unbinds = h.unbinds
					old(message)
					helpers.assert_eq(h.saves, 0)
					helpers.assert_eq(h.unbinds, unbinds, "retired messages own no cleanup or persistence")
					h.refusal = nil
					helpers.assert_true(h.open("B"))
					helpers.assert_nil(h.callbacks[h.bridges[1]])
					helpers.assert_not_nil(h.callbacks[h.bridges[2]])
					helpers.assert_eq(h.windows[1].deletes, 1)
					helpers.assert_true(editor.close()); h.drain()
					helpers.assert_nil(next(h.callbacks))
				end)
			end)
		end
	end


	for _, action in ipairs({ "save", "cancel" }) do
		helpers.it("retries only native cleanup after an accepted prompt receives " .. action, function()
			with_editor(function(editor, h)
				helpers.assert_true(h.open("A"))
				local view, bridge = h.windows[1], h.bridges[1]
				local queued, message = h.callbacks[bridge], h.message(view)
				h.delete_refuses = true
				queued(message)
				helpers.assert_eq(h.saves, 1)
				helpers.assert_eq(h.native_delete_calls, 1)
				helpers.assert_true(view.visible, "refused native close leaves the same page visible")
				helpers.assert_true(h.retained[view])
				helpers.assert_eq(editor.scope_idle(), false)
				message.body.action = action
				h.delete_refuses = false
				queued(message)
				helpers.assert_eq(h.native_delete_calls, 2, "the current visible page may retry its exact native close")
				helpers.assert_eq(h.saves, 1, "cleanup retry never repeats accepted persistence")
				h.drain()
				helpers.assert_nil(next(h.retained))
				helpers.assert_nil(next(h.callbacks))
				helpers.assert_true(h.open("B"))
				queued(message)
				helpers.assert_eq(h.native_delete_calls, 2, "an old queued retry cannot close the new owner")
				helpers.assert_not_nil(h.callbacks[h.bridges[2]])
				helpers.assert_true(editor.close()); h.drain()
			end)
		end)
	end

	helpers.it("retains both binding and detachment errors and retries the exact UCC", function()
		with_editor(function(editor, h)
			h.bind_after_throw, h.refusal = true, "throw"
			helpers.assert_eq(h.open(), false)
			helpers.assert_eq(#h.windows, 0)
			helpers.assert_not_nil(h.callbacks[h.bridges[1]], "partial binding owns a real native LuaRef")
			helpers.assert_eq(#h.errors, 2, "binding and cleanup failures must both remain observable")
			helpers.assert_true(h.errors[1]:find("bridge release did not commit", 1, true) ~= nil)
			helpers.assert_true(h.errors[2]:find("bridge binding failed", 1, true) ~= nil)
			helpers.assert_eq(editor.scope_idle(), false)
			h.bind_after_throw, h.refusal = false, nil
			helpers.assert_true(h.open("B"))
			helpers.assert_eq(#h.bridges, 2)
			helpers.assert_nil(h.callbacks[h.bridges[1]])
			h.callbacks[h.bridges[2]](h.message(h.windows[1]))
			helpers.assert_eq(h.saves, 1)
			h.drain()
			helpers.assert_nil(next(h.callbacks))
		end)
	end)

	helpers.it("detaches the bridge when factory rollback consumes the window before raising", function()
		with_editor(function(editor, h)
			h.policy_refuses, h.throw_after_gc = "throw", true
			h.policy_refuses_after_call = 2
			helpers.assert_eq(h.open(), false)
			helpers.assert_nil(next(h.retained))
			helpers.assert_nil(getmetatable(h.windows[1]))
			helpers.assert_nil(next(h.callbacks), "consumed window must not prevent separate UCC retirement")
			h.policy_refuses, h.throw_after_gc = nil, false
			helpers.assert_true(h.open("B"))
			helpers.assert_eq(h.windows[1].deletes, 1)
			helpers.assert_true(editor.close()); h.drain()
		end)
	end)

	helpers.it("blocks reentrant editing while the exact native controller is detaching", function()
		with_editor(function(editor, h)
			helpers.assert_true(h.open())
			local old, message = h.callbacks[h.bridges[1]], h.message(h.windows[1])
			h.on_unbind = function(bridge)
				helpers.assert_eq(bridge, h.bridges[1])
				helpers.assert_eq(h.open("intruder"), false)
				old(message)
				helpers.assert_eq(h.saves, 0)
			end
			helpers.assert_true(editor.close()); h.drain()
			helpers.assert_eq(#h.windows, 1)
			h.on_unbind = nil
			helpers.assert_true(h.open("B"))
			helpers.assert_true(editor.close()); h.drain()
			helpers.assert_nil(next(h.callbacks))
		end)
	end)
end)
