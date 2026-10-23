--- tests/support/ui/menu/menu_llm/profiles/profile_editor_retry_fixture.lua

--- ==============================================================================
--- MODULE: Profile Editor Save Retry Fixture
--- DESCRIPTION:
--- Reuses the real profile transactions and real Prompt Editor over native UI ports.
--- ==============================================================================

local helpers = require("tests.helpers")
local Base = require("tests.support.ui.menu.menu_llm.profiles.profile_candidate_transaction_fixture")
local receipts = {}

local OWNED_MODULES = {}
for _, name in ipairs(Base.MODULES) do OWNED_MODULES[#OWNED_MODULES + 1] = name end
for _, name in ipairs({ "ui.ui_builder", "infra.paths", "adapters.webview_result" }) do
	OWNED_MODULES[#OWNED_MODULES + 1] = name
end

--- Drives the public editor bridge while preserving the existing transaction fixture.
--- @param options table Existing profile transaction options.
--- @param callback function Receives the profile fixture and the native observations.
local function with_fixture(options, callback)
	local previous_hs = rawget(_G, "hs")
	local previous_modules = {}
	for _, name in ipairs(OWNED_MODULES) do previous_modules[name] = package.loaded[name] end
	local receipt = { native_cleanup_attempted = false }
	local base_ok, base_err = xpcall(function() Base.with_fixture(options, function(fixture)
		helpers.with_stub_scope({ "ui.ui_builder", "infra.paths", "adapters.webview_result" }, function()
			local native = _G.hs
			local saved_json, saved_webview = native.json, native.webview
			local json = require("json")
			local state = { views = {}, bridges = {}, deletes = 0, save_callbacks = {} }
			local editor_port = package.loaded["ui.prompt_editor"]
			local saved_open, saved_idle = editor_port.open, editor_port.scope_idle
			local editor
			local ok, err = xpcall(function()
				native.json = { encode = json.encode, decode = json.decode }
				native.webview = { usercontent = { new = function()
					local bridge = {}
					function bridge:setCallback(fn) self.callback = fn; return self end
					state.bridges[#state.bridges + 1] = bridge
					return bridge
				end } }
				package.loaded["infra.paths"] = { shared = function() return "/fixture/prompt_editor" end }
				package.loaded["ui.ui_builder"] = {
					get_app_geometry = function() return { width = 640, height = 480 } end,
					get_centered_frame = function() return {} end,
					force_focus = function() return true end,
					show_webview = function(options)
						local view = { options = options, scripts = {} }
						function view:evaluateJavaScript(script)
							self.scripts[#self.scripts + 1] = script
							state.context = json.decode(assert(script:match("^init%((.*)%)$")))
							return self
						end
						function view:delete() state.deletes = state.deletes + 1; self.deleted = true end
						state.views[#state.views + 1] = view
						helpers.assert_true(options.on_webview_created(view))
						return view
					end,
				}
				editor = assert(loadfile(helpers.driver_root() .. "ui/prompt_editor/init.lua"))()
				editor_port.open = function(profile, save)
					state.save_callbacks[#state.save_callbacks + 1] = save
					return editor.open(profile, function(value)
						state.last_save_payload = value
						return save(value)
					end)
				end
				editor_port.scope_idle = editor.scope_idle
				state.editor = editor

				--- Sends a genuine current-target Save through the real native bridge callback.
				--- @param label string Draft label supplied by the page.
				function state.save(label)
					local context = assert(state.context, "navigation must publish a real editor context")
					local bridge = assert(state.bridges[#state.bridges])
					assert(type(bridge.callback) == "function", "the editor bridge must still be active")
					bridge.callback({ body = {
						action = "save", edit_id = context.edit_id, epoch = context.epoch,
						name = label, prompt = "retry draft", batch = false,
					} })
				end

				callback(fixture, state)
			end, debug.traceback)
			-- Cleanup must also run after a regression assertion raises on the old code.
			-- Fault plans belong to the scenario. Teardown restores healthy native
			-- ports before asking the exact retained rollback owners to settle.
			fixture.plan_set_profiles({})
			fixture.plan_runtime({})
			fixture.plan_save({})
			fixture.plan_menu({})
			local recovery_ok = true
			for _, key in ipairs({ "settle_llm_switcher_recovery", "settle_profile_edit_recovery",
				"settle_profile_candidate_recovery", "settle_profile_delete_recovery" }) do
				local recover = fixture.deps[key]
				if recover ~= nil then
					local recovered, accepted = pcall(recover)
					if not recovered or accepted ~= true then recovery_ok = false end
				end
			end
			local cleanup_ok, cleaned = true, true
			receipt.native_cleanup_attempted = true
			if editor ~= nil then cleanup_ok, cleaned = pcall(editor.close) end
			receipt.native_close_ok = cleanup_ok and cleaned == true
			receipt.editor_idle = editor == nil or editor.scope_idle() == true
			receipt.recovery_settled = recovery_ok
			receipt.manager_idle = fixture.manager.scope_idle() == true
			receipt.timer_count = fixture.timer_count()
			receipt.views = #state.views
			receipt.deleted_views, receipt.detached_bridges = 0, 0
			for _, view in ipairs(state.views) do
				if view.deleted == true then receipt.deleted_views = receipt.deleted_views + 1 end
			end
			for _, bridge in ipairs(state.bridges) do
				if bridge.callback == nil then receipt.detached_bridges = receipt.detached_bridges + 1 end
			end
			receipt.bridges = #state.bridges
			editor_port.open, editor_port.scope_idle = saved_open, saved_idle
			native.json, native.webview = saved_json, saved_webview
			receipt.native_fields_restored = native.json == saved_json and native.webview == saved_webview
			receipt.editor_port_restored = editor_port.open == saved_open and editor_port.scope_idle == saved_idle
			helpers.assert_true(recovery_ok, "the exact retained profile rollback owners must settle during cleanup")
			helpers.assert_true(cleanup_ok and cleaned == true, "the real editor must release its native ports")
			helpers.assert_true(receipt.editor_idle and receipt.manager_idle, "no editor or profile transaction remains owned")
			helpers.assert_eq(receipt.timer_count, 0, "the exact editor timer must already have settled")
			helpers.assert_eq(receipt.deleted_views, receipt.views, "every native view must be released")
			helpers.assert_eq(receipt.detached_bridges, receipt.bridges, "every native bridge must be detached")
			if not ok then error(err, 0) end
		end)
	end) end, debug.traceback)
	receipt.hs_restored = rawget(_G, "hs") == previous_hs
	receipt.modules_restored = true
	for _, name in ipairs(OWNED_MODULES) do
		if package.loaded[name] ~= previous_modules[name] then receipt.modules_restored = false end
	end
	receipts[#receipts + 1] = receipt
	helpers.assert_true(receipt.hs_restored and receipt.modules_restored,
		"all exact native globals and module ports must be restored before returning")
	if not base_ok then error(base_err, 0) end
end

return { with_fixture = with_fixture, receipts = receipts, clone = Base.clone,
	find_child_row = Base.find_child_row, find_row = Base.find_row }
