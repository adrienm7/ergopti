--- tests/unit/ui/test_keyboard_slot_declared_presentation.lua

--- ==============================================================================
--- MODULE: Keyboard Slot Picker Declared Presentation
--- DESCRIPTION:
--- Drives the actual picker and factory through faithful native ports. Expected
--- original captions predate this change; these cases do not prove live WebKit.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local corpus = assert(Json.decode(assert(helpers.read_fixture("keyboard_slot_selection_original_presentation.json"))))

local function fixture(callback, cleanup_failures)
	cleanup_failures = cleanup_failures or {}
	local primary_failed, primary_failure = false, nil
	local previous_base = rawget(_G, "_base_dir")
	local ok, failure = xpcall(function()
		helpers.with_stub_scope({
			"ui.ui_builder", "ui.action_picker", "infra.i18n", "infra.locale", "locale.core",
			"infra.logger", "infra.paths", "infra.config_paths", "infra.deferred_work",
			"adapters.json_codec", "adapters.timer_scheduler", "adapters.storage", "webview.i18n_seed",
			"window_titles", "webview.presentation", "program_provider_picker",
			"adapters.program_providers", "adapters.apple_shortcuts_native", "hs", "tests.stubs.hs",
		}, function()
			local state = { creates = 0, bridges = 0, views = {}, contents = {}, payloads = {}, confirmations = 0 }
			state.cleanup_failures = cleanup_failures
			local owned_timers = {}
			local close_owned_picker, cancel_owned_timer
			local body_ok, body_failure = xpcall(function()
				local native = {
					windowMasks = { titled = 1, closable = 2, utility = 16 },
					usercontent = { new = function()
						state.bridges = state.bridges + 1
						local content = {}
						function content:setCallback(fn) self.callback = fn end
						state.contents[#state.contents + 1] = content
						return content
					end },
					new = function()
						state.creates = state.creates + 1
						local view = { captions = {}, scripts = {}, deletes = 0 }
						function view:windowTitle(caption) self.captions[#self.captions + 1] = caption; return self end
						for _, name in ipairs({ "windowStyle", "level", "allowTextEntry", "allowGestures",
							"shadow", "allowNewWindows", "html", "show" }) do view[name] = function() return view end end
						function view:windowCallback(fn) self.on_window = fn; return self end
						function view:navigationCallback(fn) self.on_navigation = fn; return self end
						local window = {}
						for _, name in ipairs({ "moveToScreen", "unminimize", "raise", "focus" }) do
							window[name] = function() return window end
						end
						function view:hswindow() return window end
						function view:evaluateJavaScript(script) self.scripts[#self.scripts + 1] = script; return self end
						function view:delete()
							self.deletes = self.deletes + 1
							if self.on_window then self.on_window("closed") end
							if state.delete_refused then error("controlled native close refusal") end
							return self
						end
						state.views[#state.views + 1] = view
						if state.create_hook then state.create_hook(view) end
						return view
					end,
				}
				local scheduler = helpers.load_with_stubs("adapters.timer_scheduler", {
					json = { decode = Json.decode, encode = function(payload)
						state.payloads[#state.payloads + 1] = payload
						if state.encode_hook then state.encode_hook(payload) end
						return Json.encode(payload)
					end },
					webview = native,
				})
				-- Forward real scheduler calls and retain only this fresh fixture's handles.
				cancel_owned_timer = scheduler.cancel
				state.scheduler = scheduler
				for _, method in ipairs({ "after", "every" }) do
					local schedule_owner = scheduler[method]
					scheduler[method] = function(...)
						local outcome = table.pack(schedule_owner(...))
						if type(outcome[1]) == "table" then owned_timers[#owned_timers + 1] = outcome[1] end
						return table.unpack(outcome, 1, outcome.n)
					end
				end
				-- Restore the actual locale facade before the contextual factory captures it.
				package.loaded["infra.i18n"] = nil
				local i18n = require("infra.i18n")
				local locale = require("infra.locale")
				local core = require("locale.core")
				local original_core_get = core.get
				core.get = function(key)
					if state.translate_hook then state.translate_hook(key) end
					return original_core_get(key)
				end
				package.loaded["ui.ui_builder"] = nil
				local builder = require("ui.ui_builder")
				package.loaded["adapters.program_providers"] = {}
				package.loaded["adapters.apple_shortcuts_native"] = {}
				package.loaded["ui.action_picker"] = nil
				local picker = require("ui.action_picker")
				close_owned_picker = picker.close
				local titles = require("window_titles")
				local function open(opts)
					return picker.open(opts or { presentation_id = "keyboard_slot_selection", items = {} }, function()
						state.confirmations = state.confirmations + 1
						return true
					end)
				end
				local function ready(index)
					state.contents[index or #state.contents].callback({ body = { action = "ready" } })
				end
				callback(state, builder, picker, locale, titles, open, ready, core, i18n)
			end, function(failure_value) return failure_value end)
			if not body_ok then
				primary_failed, primary_failure = true, body_failure
			end
			local function clean_owned(label, cleanup)
				local settled, outcome = xpcall(cleanup, function(failure_value) return failure_value end)
				if not settled or outcome ~= true then
					cleanup_failures[#cleanup_failures + 1] = {
						owner = label,
						failure = settled and (label .. " did not settle") or outcome,
					}
				end
			end
			-- Retire the actual fixture session while its modules and native ports exist.
			state.delete_refused = false
			if close_owned_picker then clean_owned("fixture picker", close_owned_picker) end
			for index, handle in ipairs(owned_timers) do
				clean_owned("fixture timer " .. index, function() return cancel_owned_timer(handle) end)
			end
		end)
	end, debug.traceback)
	rawset(_G, "_base_dir", previous_base)
	if not ok then
		cleanup_failures[#cleanup_failures + 1] = { owner = "fixture scope", failure = failure }
	end
	-- Keep the original assertion value separate from every cleanup failure.
	if primary_failed then error(primary_failure, 0) end
	if #cleanup_failures > 0 then error(cleanup_failures[1].failure, 0) end
end

helpers.describe("real keyboard slot picker contextual receiving", function()
	for code, original in pairs(corpus.locales) do
		helpers.it("preserves the original page and native captions in " .. code, function()
			fixture(function(state, _, _, locale, _, open, ready)
				locale.set_locale(code)
				helpers.assert_true(open())
				helpers.assert_eq(state.creates, 1)
				helpers.assert_eq(state.views[1].captions[1], original.original_native_caption_source_projection)
				ready()
				local payload = state.payloads[#state.payloads]
				helpers.assert_eq(payload.title, original.original_page_title)
				helpers.assert_eq(payload.label, original.original_page_label)
				helpers.assert_eq(payload.current, "none")
				helpers.assert_eq(state.confirmations, 0)
			end)
		end)
	end

	helpers.it("unknown and conflicting contexts preserve the existing actual picker", function()
		fixture(function(state, _, _, _, _, open)
			helpers.assert_true(open({ title = "Original legacy title", items = {} }))
			for _, opts in ipairs({
				{ presentation_id = "unknown_context" },
				{ presentation_id = "keyboard_slot_selection", title = "Borrowed title" },
				{ presentation_id = "keyboard_slot_selection", label = "Borrowed prompt" },
			}) do helpers.assert_eq(open(opts), false) end
			helpers.assert_eq(state.bridges, 1)
			helpers.assert_eq(state.creates, 1)
			helpers.assert_eq(state.views[1].deletes, 0)
		end)
	end)

	helpers.it("a borrowed receipt cannot acquire a different app or context", function()
		fixture(function(state, builder)
			local receipt = builder.prepare_app_presentation("action_picker", "keyboard_slot_selection")
			helpers.assert_type(receipt, "table")
			for _, opts in ipairs({
				{ app_id = "paths_editor", presentation_id = "keyboard_slot_selection", presentation_receipt = receipt },
				{ app_id = "action_picker", presentation_id = "unknown_context", presentation_receipt = receipt },
				{ app_id = "action_picker", presentation_id = "keyboard_slot_selection", presentation_receipt = {} },
			}) do helpers.assert_nil(builder.show_webview(opts)) end
			helpers.assert_eq(state.creates, 0)
		end)
	end)

	helpers.it("replaced actual compiled lookup refuses without invoking it and permits exact repair", function()
		fixture(function(state, _, _, _, titles, open)
			local original, observed = titles.presentation_for_app, 0
			titles.presentation_for_app = function() observed = observed + 1; return {} end
			helpers.assert_eq(open(), false)
			helpers.assert_eq(observed, 0)
			helpers.assert_eq(state.bridges, 0)
			helpers.assert_eq(state.creates, 0)
			titles.presentation_for_app = original
			helpers.assert_true(open())
			helpers.assert_eq(state.creates, 1)
		end)
	end)

	helpers.it("replaced actual delegated translation refuses without observer effects", function()
		fixture(function(state, _, _, _, _, open, _, core)
			local original, observed = core.get, 0
			core.get = function() observed = observed + 1; return "Borrowed translation" end
			helpers.assert_eq(open(), false)
			helpers.assert_eq(observed, 0)
			helpers.assert_eq(state.bridges, 0)
			core.get = original
			helpers.assert_true(open())
		end)
	end)

	helpers.it("a locale switch during the original translation read refuses before replacement", function()
		fixture(function(state, _, _, locale, _, open)
			locale.set_locale("fr")
			helpers.assert_true(open({ title = "Retained legacy title", items = {} }))
			state.translate_hook = function(key)
				if key == corpus.original_title_key then locale.set_locale("de") end
			end
			helpers.assert_eq(open(), false)
			helpers.assert_eq(state.creates, 1)
			helpers.assert_eq(state.views[1].deletes, 0)
			state.translate_hook = nil
			locale.set_locale("fr")
			helpers.assert_true(open())
		end)
	end)

	helpers.it("translation reentry cannot let the old request close its actual successor", function()
		fixture(function(state, _, _, _, _, open)
			helpers.assert_true(open({ title = "Original first target", items = {} }))
			state.translate_hook = function(key)
				if key ~= corpus.original_title_key then return end
				state.translate_hook = nil
				helpers.assert_true(open({ title = "Actual reentrant successor", items = {} }))
			end
			helpers.assert_eq(open(), false)
			helpers.assert_eq(state.creates, 2)
			helpers.assert_eq(state.views[1].deletes, 1)
			helpers.assert_eq(state.views[2].deletes, 0)
		end)
	end)

	helpers.it("existing ambiguous native close blocks contextual replacement without a second target", function()
		fixture(function(state, _, _, _, _, open)
			helpers.assert_true(open())
			state.delete_refused = true
			helpers.assert_eq(open(), false)
			helpers.assert_eq(state.creates, 1)
			helpers.assert_eq(state.bridges, 1)
			state.delete_refused = false
			helpers.assert_true(open())
			helpers.assert_eq(state.creates, 2)
		end)
	end)

	helpers.it("late withdrawal during actual encoding cannot inject the old page", function()
		fixture(function(state, _, _, _, titles, open, ready)
			helpers.assert_true(open())
			local original, observed = titles.presentation_for_app, 0
			local existing_provider_scripts = #state.views[1].scripts
			state.encode_hook = function(payload)
				if payload.title == nil then return end
				state.encode_hook = nil
				titles.presentation_for_app = function() observed = observed + 1; return {} end
			end
			ready()
			helpers.assert_eq(#state.views[1].scripts, existing_provider_scripts, "the original provider delivery remains; no stale init is added")
			helpers.assert_eq(state.views[1].deletes, 1)
			helpers.assert_eq(observed, 0)
			titles.presentation_for_app = original
		end)
	end)
end)

helpers.describe("keyboard slot presentation fixture retirement", function()
	helpers.it("retires its actual picker and navigation timer when an assertion raises", function()
		local retained_state
		local assertion_failure = "original keyboard slot assertion failure"
		local cleanup_failures = {}
		local ok, failure = pcall(function()
			fixture(function(state, _, _, _, _, open)
				retained_state = state
				helpers.assert_true(open())
				local view = state.views[1]
				view.on_navigation("didFinishNavigation", view)
				helpers.assert_true(state.scheduler.activeCount() > 0)
				state.delete_refused = true
				error(assertion_failure, 0)
			end, cleanup_failures)
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_eq(failure, assertion_failure)
		helpers.assert_eq(#cleanup_failures, 0)
		helpers.assert_eq(retained_state.views[1].deletes, 1)
		helpers.assert_eq(retained_state.scheduler.activeCount(), 0)
	end)

	helpers.it("retires successful receiving with actual one-shot and repeating timers", function()
		local retained_state, repeating_handle
		fixture(function(state, _, _, _, _, open)
			retained_state = state
			helpers.assert_true(open())
			local view = state.views[1]
			view.on_navigation("didFinishNavigation", view)
			local committed
			repeating_handle, committed = state.scheduler.every(1, function() end)
			helpers.assert_eq(committed, true)
			helpers.assert_true(state.scheduler.activeCount() >= 2)
		end)
		helpers.assert_eq(retained_state.views[1].deletes, 1)
		helpers.assert_eq(retained_state.scheduler.activeCount(), 0)
		helpers.assert_nil(repeating_handle.timer)
	end)
end)

helpers.describe("keyboard slot presentation saved-locale initialization", function()
	helpers.it("keeps genuine factory owners through persisted locale initialization and receives the original captions", function()
		local retained_state
		local cleanup_failures = {}
		fixture(function(state, builder, _, locale, _, open, ready, core, i18n)
			retained_state = state
			local original = assert(corpus.locales.de)
			local Storage = require("adapters.storage")
			local translate_owner = i18n.get
			local locale_get_owner, locale_current_owner = locale.get, locale.current_locale
			local core_get_owner, core_current_owner = core.get, core.current_locale
			helpers.assert_eq(i18n.get_locale(), "fr")
			helpers.assert_eq(locale.current_locale(), "fr")
			local before = builder.prepare_app_presentation("action_picker", "keyboard_slot_selection")
			helpers.assert_type(before, "table")
			helpers.assert_eq(builder.presentation_current(before), true)
			helpers.assert_eq(state.creates, 0)

			-- Seed the real saved setting, then use root boot's backend wiring and initializer.
			helpers.assert_eq(i18n.persist_locale("de"), true)
			helpers.assert_eq(Storage.get("i18n_locale"), "de")
			helpers.assert_eq(i18n.get_locale(), "fr", "persistence alone must not change the active locale")
			i18n.set_locale_injector(function(code) locale.set_locale(code) end)
			i18n.init()
			helpers.assert_eq(i18n.get_locale(), "de")
			helpers.assert_eq(locale.current_locale(), "de")
			helpers.assert_eq(core.current_locale(), "de")
			for name, owner in pairs({ ["infra.i18n"] = i18n, ["infra.locale"] = locale, ["locale.core"] = core }) do
				helpers.assert_true(rawequal(package.loaded[name], owner), "initialization must retain " .. name)
			end
			helpers.assert_eq(i18n.get, translate_owner)
			helpers.assert_eq(locale.get, locale_get_owner)
			helpers.assert_eq(locale.current_locale, locale_current_owner)
			helpers.assert_eq(core.get, core_get_owner)
			helpers.assert_eq(core.current_locale, core_current_owner)
			helpers.assert_eq(builder.presentation_current(before), false, "the former French receipt must become stale")
			local after = builder.prepare_app_presentation("action_picker", "keyboard_slot_selection")
			helpers.assert_type(after, "table")
			helpers.assert_eq(builder.presentation_current(after), true)
			local title, label = builder.presentation_fields(after)
			helpers.assert_eq(title, original.original_page_title)
			helpers.assert_eq(label, original.original_page_label)
			helpers.assert_eq(state.creates, 0)

			helpers.assert_true(open())
			helpers.assert_eq(state.creates, 1)
			helpers.assert_eq(state.views[1].captions[1], original.original_native_caption_source_projection)
			ready()
			local payload = state.payloads[#state.payloads]
			helpers.assert_eq(payload.title, original.original_page_title)
			helpers.assert_eq(payload.label, original.original_page_label)
			helpers.assert_eq(payload.current, "none")
			helpers.assert_eq(state.confirmations, 0)
			helpers.assert_eq(builder.presentation_current(after), true)
			state.views[1].on_navigation("didFinishNavigation", state.views[1])
			helpers.assert_true(state.scheduler.activeCount() > 0)
		end, cleanup_failures)
		helpers.assert_eq(#cleanup_failures, 0)
		helpers.assert_eq(retained_state.views[1].deletes, 1)
		helpers.assert_eq(retained_state.scheduler.activeCount(), 0)
	end)
end)
