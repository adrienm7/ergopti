--- tests/unit/ui/test_paths_editor_declared_host_title.lua

--- ==============================================================================
--- MODULE: Paths Editor Declared Native Host Title
--- DESCRIPTION:
--- Exercises the actual shared title, locale and paths producers against modeled
--- native creation/mutation ports. Frozen old-source captions remain independent.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local raw = assert(helpers.read_fixture("paths_editor_original_native_captions.json"))
local original = assert(Json.decode(raw))

local function with_fixture(callback)
	local previous_base = rawget(_G, "_base_dir")
	local ok, failure = xpcall(function()
		helpers.with_stub_scope({
			"ui.ui_builder", "ui.menu.menu_paths", "infra.i18n", "infra.locale", "locale.core",
			"infra.logger", "infra.paths", "infra.config_paths", "infra.deferred_work",
			"adapters.json_codec", "adapters.timer_scheduler", "adapters.storage", "webview.i18n_seed",
			"window_titles", "hs", "tests.stubs.hs",
		}, function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.paths"] = { shared = helpers.shared }
			package.loaded["infra.deferred_work"] = { after = function() return true end }
			local state = { creates = 0, titles = {}, deletes = 0, acquired = false }
			local view = {}
			function view:windowTitle(caption)
				state.titles[#state.titles + 1] = caption
				return self
			end
			for _, name in ipairs({"windowStyle", "level", "allowTextEntry", "allowGestures",
				"shadow", "allowNewWindows", "windowCallback", "navigationCallback", "html", "show"}) do
				view[name] = function() return view end
			end
			function view:hswindow() return nil end
			function view:delete() state.deletes = state.deletes + 1; return self end
			local builder = helpers.load_with_stubs("ui.ui_builder", {
				json = {decode = Json.decode, encode = Json.encode},
				webview = {
					windowMasks = {titled = 1, closable = 2, utility = 16},
					new = function() state.creates = state.creates + 1; return view end,
				},
			})
			-- The loader injects passthrough i18n; require the actual producer after it.
			package.loaded["infra.i18n"] = nil
			local i18n = require("infra.i18n")
			local locale = require("infra.locale")
			local titles = require("window_titles")
			local function request(app_id)
				return {
					app_id = app_id,
					frame = {x = 0, y = 0, w = 200, h = 150},
					html_string = "<html></html>",
					on_webview_created = function(candidate)
						helpers.assert_eq(candidate, view)
						state.acquired = true
						return true
					end,
					is_current = function() return state.acquired end,
					schedule_after = function() return true end,
				}
			end
			callback(builder, state, view, request, titles, i18n, locale)
		end)
	end, debug.traceback)
	rawset(_G, "_base_dir", previous_base)
	if not ok then error(failure, 0) end
end

helpers.describe("paths editor declared host title receiving", function()
	for _, old in ipairs(original.rows) do
		helpers.it("preserves the independently captured native paths caption in " .. old.locale, function()
			with_fixture(function(builder, state, view, request, titles, i18n, locale)
				locale.set_locale(old.locale)
				helpers.assert_eq(titles.key_for_app("paths_editor"), original.key)
				helpers.assert_eq(i18n.get(original.key), old.label)
				helpers.assert_eq(builder.show_webview(request("paths_editor")), view)
				helpers.assert_eq(state.creates, 1)
				helpers.assert_eq(#state.titles, 1)
				helpers.assert_eq(state.titles[1], old.caption)
				view:delete()
			end)
		end)
	end

	helpers.it("preserves the original caller-title API when no app identity is supplied", function()
		with_fixture(function(builder, state, view, request)
			local opts = request(nil)
			opts.title = "Original caller caption & identity"
			helpers.assert_eq(builder.show_webview(opts), view)
			helpers.assert_eq(state.titles[1], "ErgoptiPlus — Original caller caption & identity")
			helpers.assert_eq(state.creates, 1)
			view:delete()
		end)
	end)

	helpers.it("preserves late caller title changes from the original native ownership callback", function()
		with_fixture(function(builder, state, view, request)
			local opts = request(nil)
			opts.title = "Initial caller caption"
			local acquire = opts.on_webview_created
			opts.on_webview_created = function(candidate)
				local accepted = acquire(candidate)
				opts.title = "Updated caller caption"
				return accepted
			end
			helpers.assert_eq(builder.show_webview(opts), view)
			helpers.assert_eq(state.creates, 1)
			helpers.assert_eq(state.titles[1], "ErgoptiPlus — Updated caller caption")
			view:delete()
		end)
	end)

	helpers.it("refuses malformed, unknown and competing app titles before native allocation", function()
		with_fixture(function(builder, state, _, request)
			for _, app_id in ipairs({false, true, 0, {}, "", "Paths_Editor", "paths.editor", "unknown_app"}) do
				helpers.assert_nil(builder.show_webview(request(app_id)))
			end
			local opts = request("paths_editor")
			opts.title = "Borrowed caller override"
			helpers.assert_nil(builder.show_webview(opts))
			helpers.assert_eq(state.creates, 0)
			helpers.assert_eq(#state.titles, 0)
			helpers.assert_eq(state.acquired, false)
		end)
	end)

	for _, member in ipairs({"key_for_app", "compose"}) do
		helpers.it("refuses withdrawn shared title owner " .. member .. " without dispatch and permits exact repair", function()
			with_fixture(function(builder, state, view, request, titles)
				local owned, hits = titles[member], 0
				titles[member] = function() hits = hits + 1; return "Unowned caption" end
				local ok, result = pcall(builder.show_webview, request("paths_editor"))
				titles[member] = owned
				helpers.assert_true(ok)
				helpers.assert_nil(result)
				helpers.assert_eq(hits, 0)
				helpers.assert_eq(state.creates, 0)
				helpers.assert_eq(builder.show_webview(request("paths_editor")), view)
				helpers.assert_eq(state.creates, 1)
				view:delete()
			end)
		end)
	end

	for _, missing in ipairs({false, "", "menu.paths.window_title"}) do
		helpers.it("refuses actual translation absence " .. tostring(missing) .. " before native allocation", function()
			with_fixture(function(builder, state, view, request, _, _, locale)
				local owned = locale.get
				locale.get = function(key)
					if key == original.key then return missing end
					return owned(key)
				end
				local ok, result = pcall(builder.show_webview, request("paths_editor"))
				locale.get = owned
				helpers.assert_true(ok)
				helpers.assert_nil(result)
				helpers.assert_eq(state.creates, 0)
				helpers.assert_eq(builder.show_webview(request("paths_editor")), view)
				helpers.assert_eq(state.creates, 1)
				view:delete()
			end)
		end)
	end

	helpers.it("rechecks declared title custody after actual native ownership acquisition", function()
		with_fixture(function(builder, state, view, request, titles)
			local opts, owned, hits = request("paths_editor"), titles.key_for_app, 0
			local acquire = opts.on_webview_created
			opts.on_webview_created = function(candidate)
				local accepted = acquire(candidate)
				titles.key_for_app = function() hits = hits + 1; return original.key end
				return accepted
			end
			local ok, result = pcall(builder.show_webview, opts)
			titles.key_for_app = owned
			helpers.assert_true(ok)
			helpers.assert_nil(result)
			helpers.assert_eq(state.creates, 1)
			helpers.assert_eq(hits, 0)
			helpers.assert_eq(#state.titles, 0)
			helpers.assert_true(state.acquired)
			helpers.assert_eq(state.deletes, 0, "the acquired exact candidate remains its caller's cleanup obligation")
			view:delete()
			helpers.assert_eq(state.deletes, 1)
		end)
	end)

	helpers.it("refuses a changed app request after native acquisition without applying stale title policy", function()
		with_fixture(function(builder, state, view, request)
			local opts = request("paths_editor")
			local acquire = opts.on_webview_created
			opts.on_webview_created = function(candidate)
				local accepted = acquire(candidate)
				opts.app_id = "unknown_successor"
				return accepted
			end
			helpers.assert_nil(builder.show_webview(opts))
			helpers.assert_eq(state.creates, 1)
			helpers.assert_eq(#state.titles, 0)
			helpers.assert_eq(state.deletes, 0)
			view:delete()
			helpers.assert_eq(state.deletes, 1)
		end)
	end)

	helpers.it("refuses owner withdrawal during actual lifecycle observation before the native title call", function()
		with_fixture(function(builder, state, view, request, titles)
			local opts, owned, hits = request("paths_editor"), titles.key_for_app, 0
			local observations = 0
			opts.is_current = function()
				observations = observations + 1
				if observations == 1 then
					titles.key_for_app = function() hits = hits + 1; return original.key end
				end
				return state.acquired
			end
			local ok, result = pcall(builder.show_webview, opts)
			titles.key_for_app = owned
			helpers.assert_true(ok)
			helpers.assert_nil(result)
			helpers.assert_true(observations >= 1, "the actual pre-title lifecycle observer must run")
			helpers.assert_eq(state.creates, 1)
			helpers.assert_eq(#state.titles, 0)
			helpers.assert_eq(hits, 0)
			helpers.assert_eq(state.deletes, 0)
			view:delete()
			helpers.assert_eq(state.deletes, 1)
		end)
	end)

	helpers.it("refuses title-owner withdrawal inside the actual native caption mutation", function()
		with_fixture(function(builder, state, view, request, titles)
			local set_title, owned, hits = view.windowTitle, titles.key_for_app, 0
			view.windowTitle = function(self, caption)
				local result = set_title(self, caption)
				titles.key_for_app = function() hits = hits + 1; return original.key end
				return result
			end
			local ok, result = pcall(builder.show_webview, request("paths_editor"))
			titles.key_for_app, view.windowTitle = owned, set_title
			helpers.assert_true(ok)
			helpers.assert_nil(result)
			helpers.assert_eq(state.creates, 1)
			helpers.assert_eq(#state.titles, 1)
			helpers.assert_eq(hits, 0)
			helpers.assert_eq(state.deletes, 0)
			view:delete()
			helpers.assert_eq(state.deletes, 1)
		end)
	end)

	helpers.it("receives the genuine paths editor request through the actual native factory", function()
		with_fixture(function(builder, state, view, _, _, i18n, locale)
			locale.set_locale("en")
			-- Preserve the single modeled hs cohort captured by the actual factory,
			-- translator and adapters. These established resolver/bridge fixture
			-- ports expose only read-only directory data; no configuration is written.
			package.loaded["infra.config_paths"] = {
				is_initialized = function() return true end,
				get = function(key) return "/tmp/ergopti/" .. tostring(key) end,
				get_config_dir = function() return "/tmp/ergopti/" end,
				get_default_config_dir = function() return "/Users/test/.config/ergopti_plus/" end,
				get_logs_dir = function() return "/tmp/ergopti-logs/ergopti_plus/" end,
				get_default_logs_dir = function() return "/Users/test/Library/Logs/ergopti_plus/" end,
			}
			hs.webview.usercontent = { new = function()
				return { setCallback = function() return true end }
			end }
			local editor = require("ui.menu.menu_paths")
			local receive, received = builder.show_webview, nil
			builder.show_webview = function(opts)
				received = opts
				return receive(opts)
			end
			package.loaded["ui.ui_builder"] = builder
			helpers.assert_true(editor.init("/Applications/ErgoptiPlus.app/", function() end))
			helpers.assert_true(editor.open_editor())
			helpers.assert_eq(received.app_id, "paths_editor", "the genuine producer supplies canonical identity, never translated title text")
			helpers.assert_nil(received.title)
			helpers.assert_eq(state.creates, 1)
			helpers.assert_eq(#state.titles, 1)
			local expected
			for _, old in ipairs(original.rows) do if old.locale == "en" then expected = old.caption end end
			helpers.assert_eq(i18n.get(original.key), "Paths")
			helpers.assert_eq(state.titles[1], expected)
			view:delete()
		end)
	end)
end)
