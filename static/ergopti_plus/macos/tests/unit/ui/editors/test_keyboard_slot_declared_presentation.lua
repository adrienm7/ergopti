--- tests/unit/ui/editors/test_keyboard_slot_declared_presentation.lua

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
						function content:setCallback(fn) self.callback = fn; return self end
						state.contents[#state.contents + 1] = content
						return content
					end },
					new = function()
						state.creates = state.creates + 1
						local view = { captions = {}, scripts = {}, deletes = 0 }
						function view:windowTitle(caption) self.captions[#self.captions + 1] = caption; return self end
						function view:deleteOnClose(value) self.delete_on_close = value; return self end
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


-- Native-title contexts receive no borrowed or unused page label.
local hf_title_corpus = assert(Json.decode(assert(helpers.read_fixture("hf_window_title_original_presentation.json"))))

local function with_title_receiving(scenario)
	local cleanup_failures = {}
	local retained_state
	fixture(function(state, builder, _, locale, titles)
		retained_state = state
		local owned, closed = nil, false
		local function show(receipt, overrides)
			local opts = {
				app_id = "token_prompt", presentation_id = "hf_login", presentation_receipt = receipt,
				frame = { x = 0, y = 0, w = 1560, h = 400 }, focus = false,
				style_masks = { "titled", "closable", "nonactivating" }, allow_new_windows = false,
				on_webview_created = function(view) owned = view; return true end,
				on_close = function() closed = true end,
			}
			for key, value in pairs(overrides or {}) do opts[key] = value end
			return builder.show_webview(opts)
		end
		local passed, primary = xpcall(function()
			scenario(state, builder, locale, titles, show)
		end, function(value) return value end)
		if owned ~= nil then
			local released, result = pcall(function() return owned:delete() end)
			if not released or result == nil or result == false or not closed then
				cleanup_failures[#cleanup_failures + 1] = { owner = "title receiving view", failure = result }
			end
		end
		if not passed then error(primary, 0) end
	end, cleanup_failures)
	helpers.assert_eq(#cleanup_failures, 0)
	if retained_state then
		for _, view in ipairs(retained_state.views) do helpers.assert_eq(view.deletes, 1) end
		helpers.assert_eq(retained_state.scheduler.activeCount(), 0)
	end
end

helpers.describe("explicit native window-title contexts", function()
	for code, original in pairs(hf_title_corpus.locales) do
		helpers.it("receives the original HF native caption without a page label in " .. code, function()
			with_title_receiving(function(state, builder, locale, _, show)
				locale.set_locale(code)
				local receipt = builder.prepare_app_window_title("token_prompt", "hf_login")
				helpers.assert_type(receipt, "table")
				local title, label = builder.presentation_fields(receipt)
				helpers.assert_eq(title, original.original_hf_native_label)
				helpers.assert_nil(label)
				helpers.assert_eq(builder.presentation_current(receipt), true)
				helpers.assert_eq(state.creates, 0)
				helpers.assert_not_nil(show(receipt))
				helpers.assert_eq(state.creates, 1)
				helpers.assert_eq(state.views[1].captions, { original.original_native_caption_source_projection })
				helpers.assert_eq(#state.payloads, 0, "no page title or label is injected by the context")
			end)
		end)
	end

	helpers.it("keeps full-context and title-only preparation policies distinct", function()
		with_title_receiving(function(state, builder)
			helpers.assert_nil(builder.prepare_app_presentation("token_prompt", "hf_login"))
			helpers.assert_nil(builder.prepare_app_window_title("action_picker", "keyboard_slot_selection"))
			helpers.assert_type(builder.prepare_app_presentation("action_picker", "keyboard_slot_selection"), "table")
			helpers.assert_nil(builder.prepare_app_window_title("token_prompt", "unknown_context"))
			helpers.assert_eq(state.creates, 0)
		end)
	end)

	helpers.it("withdraws the actual compiled title lookup and repairs before native allocation", function()
		with_title_receiving(function(state, builder, _, titles, show)
			local receipt = builder.prepare_app_window_title("token_prompt", "hf_login")
			helpers.assert_type(receipt, "table")
			local original, observed = titles.presentation_for_app, 0
			titles.presentation_for_app = function() observed = observed + 1; return {} end
			helpers.assert_nil(builder.prepare_app_window_title("token_prompt", "hf_login"))
			helpers.assert_eq(builder.presentation_current(receipt), false)
			helpers.assert_nil(show(receipt))
			helpers.assert_eq(state.creates, 0)
			helpers.assert_eq(observed, 0)
			titles.presentation_for_app = original
			helpers.assert_eq(builder.presentation_current(receipt), true)
			helpers.assert_not_nil(show(receipt))
			helpers.assert_eq(state.creates, 1)
		end)
	end)

	helpers.it("refuses a borrowed context and caller labels without native allocation", function()
		with_title_receiving(function(state, builder, _, _, show)
			local receipt = builder.prepare_app_window_title("token_prompt", "hf_login")
			helpers.assert_type(receipt, "table")
			helpers.assert_nil(show(receipt, { app_id = "action_picker" }))
			helpers.assert_nil(show(receipt, { presentation_id = "keyboard_slot_selection" }))
			helpers.assert_nil(show(receipt, { title = "Borrowed caption" }))
			helpers.assert_nil(show(receipt, { label = "Borrowed page label" }))
			helpers.assert_nil(show({}))
			helpers.assert_eq(state.creates, 0)
			helpers.assert_not_nil(show(receipt))
		end)
	end)

	helpers.it("retains locale and public preparation ownership before title receiving", function()
		with_title_receiving(function(state, builder, locale, _, show)
			locale.set_locale("fr")
			local receipt = builder.prepare_app_window_title("token_prompt", "hf_login")
			helpers.assert_type(receipt, "table")
			locale.set_locale("es")
			helpers.assert_eq(builder.presentation_current(receipt), false)
			helpers.assert_nil(show(receipt))
			locale.set_locale("fr")
			helpers.assert_eq(builder.presentation_current(receipt), true)
			local original, observed = builder.prepare_app_window_title, 0
			builder.prepare_app_window_title = function() observed = observed + 1; return {} end
			helpers.assert_nil(show(receipt))
			helpers.assert_eq(observed, 0)
			helpers.assert_eq(state.creates, 0)
			builder.prepare_app_window_title = original
			helpers.assert_not_nil(show(receipt))
		end)
	end)
end)


local contextual_original = assert(Json.decode(assert(helpers.read_fixture("contextual_picker_original_prefixes.json"))))
helpers.describe("declared keyboard action contextual title receiving", function()
	for code, expected in pairs(contextual_original.locales) do
		for _, suffix in ipairs(contextual_original.suffix_cases) do
			helpers.it("keeps the original keyboard action prefix and suffix in " .. code .. ": " .. suffix, function()
				fixture(function(state, _, _, locale, _, open, ready)
					locale.set_locale(code)
					helpers.assert_true(open({ presentation_id = "keyboard_slot_action", presentation_suffix = suffix,
						items = {}, current = "none" }))
					helpers.assert_eq(state.creates, 1)
					helpers.assert_eq(state.views[1].captions[1], "ErgoptiPlus — " .. expected.mac_prefix .. suffix)
					ready()
					local payload = state.payloads[#state.payloads]
					helpers.assert_eq(payload.title, expected.mac_prefix .. suffix)
					helpers.assert_eq(payload.label, expected.picker_label)
					helpers.assert_eq(payload.current, "none")
					helpers.assert_eq(state.confirmations, 0, "Title preparation does not grant an action")
				end)
			end)
		end
	end
	for _, suffix in ipairs({ "", "bad\nline", "bad\tline", string.rep("x", 1025), true, {}, 1 }) do
		helpers.it("refuses invalid contextual suffix data before allocation: " .. type(suffix) .. tostring(suffix), function()
			fixture(function(state, _, _, _, _, open)
				helpers.assert_eq(open({ presentation_id = "keyboard_slot_action", presentation_suffix = suffix, items = {} }), false)
				helpers.assert_eq(state.bridges, 0)
				helpers.assert_eq(state.creates, 0)
				helpers.assert_true(open({ presentation_id = "keyboard_slot_action", presentation_suffix = "K1", items = {} }))
				helpers.assert_eq(state.creates, 1, "Ordinary valid display data repairs the request")
			end)
		end)
	end
	helpers.it("refuses the Linux context and forged contextual receipts before native allocation", function()
		fixture(function(state, builder, _, _, _, open)
			helpers.assert_eq(open({ presentation_id = "tap_hold_action", presentation_suffix = "K1", items = {} }), false)
			helpers.assert_eq(builder.show_webview({ app_id = "action_picker", presentation_id = "keyboard_slot_action",
				presentation_receipt = {} }), nil)
			helpers.assert_eq(state.bridges, 0); helpers.assert_eq(state.creates, 0)
			helpers.assert_true(open({ presentation_id = "keyboard_slot_action", presentation_suffix = "K1", items = {} }))
		end)
	end)
	helpers.it("refuses a withdrawn factory prepare owner then accepts its exact repair", function()
		fixture(function(state, builder, _, _, _, open)
			local original, observed = builder.prepare_app_contextual_title, 0
			builder.prepare_app_contextual_title = function() observed = observed + 1; return {} end
			local ok, failure = pcall(function()
				helpers.assert_eq(open({ presentation_id = "keyboard_slot_action", presentation_suffix = "K1", items = {} }), false)
				helpers.assert_eq(observed, 0); helpers.assert_eq(state.bridges, 0); helpers.assert_eq(state.creates, 0)
			end)
			builder.prepare_app_contextual_title = original
			if not ok then error(failure, 0) end
			helpers.assert_true(open({ presentation_id = "keyboard_slot_action", presentation_suffix = "K1", items = {} }))
		end)
	end)
	helpers.it("retains contextual Source custody across translation and repairs the exact lookup", function()
		fixture(function(state, _, _, _, titles, open)
			local original, observed = titles.presentation_for_app, 0
			state.translate_hook = function(key)
				if key == "dialog.keyboard_shortcut.title_prefix" then
					titles.presentation_for_app = function() observed = observed + 1; return nil end
				end
			end
			local ok, failure = pcall(function()
				helpers.assert_eq(open({ presentation_id = "keyboard_slot_action", presentation_suffix = "K1", items = {} }), false)
				helpers.assert_eq(state.creates, 0); helpers.assert_eq(state.bridges, 0); helpers.assert_eq(observed, 0)
			end)
			state.translate_hook = nil; titles.presentation_for_app = original
			if not ok then error(failure, 0) end
			helpers.assert_true(open({ presentation_id = "keyboard_slot_action", presentation_suffix = "K1", items = {} }))
		end)
	end)
end)
