--- tests/unit/ui/menu/test_menu_apps_discovery_outcome.lua

--- ==============================================================================
--- MODULE: Bundled App Discovery Outcome Tests
--- DESCRIPTION:
--- Failed enumeration remains retryable and cannot poison the session cache.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_apps(callback)
	local previous_hs = _G.hs
	local ok, err = xpcall(function()
		helpers.with_stub_scope({ "ui.menu.menu_apps", "infra.logger", "infra.paths",
			"infra.i18n", "infra.manifest_menu", "adapters.task_lifecycle", "infra.text_utils",
			"adapters.json_codec", "menu.renderer", "logger.shim" }, function()
			local state = { calls = {}, warnings = {}, images = {}, app_scans = 0,
				output = "", status = true, kind = "exit", code = 0 }
			local logger = helpers.make_logger_stub()
			logger.warn = function(_, message, ...)
				state.warnings[#state.warnings + 1] = string.format(message, ...)
			end
			package.loaded["infra.logger"] = logger
			package.loaded["infra.paths"] = {}
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["infra.manifest_menu"] = { build = function(key, title, dynamic, on_click, ctx, providers)
				if state.render_native then
					return state.binding.build(key, title, dynamic, on_click, ctx, providers)
				end
				return providers.apps_installed()
			end }
			package.loaded["adapters.task_lifecycle"] = {}
			local module = helpers.load_with_stubs("ui.menu.menu_apps", {
				fs = { attributes = function() return { mode = "directory" } end },
				execute = function(command)
					state.calls[#state.calls + 1] = command
					if command:find("*.icns", 1, true) then
						if state.icon_failure then return "/private/Partial.icns\n", nil, "exit", 1 end
						return "", true, "exit", 0
					end
					state.app_scans = state.app_scans + 1
					if state.throw then error("PRIVATE_FAILURE") end
					return state.output, state.status, state.kind, state.code
				end,
				application = { infoForBundlePath = function() return {} end },
				image = { imageFromPath = function(path)
					state.images[#state.images + 1] = path
					return nil
				end },
			})
			-- Keep the discovery fixture's direct provider view, while forwarding its
			-- template port to the actual native binding and generated shared data.
			local provider_view = package.loaded["infra.manifest_menu"]
			package.loaded["infra.manifest_menu"] = nil
			state.binding = require("infra.manifest_menu")
			package.loaded["infra.manifest_menu"] = provider_view
			provider_view.template_rows = state.binding.template_rows
			provider_view.get_root = state.binding.get_root
			provider_view.group_row = state.binding.group_row
			callback(module, state, { base_dir = "/virtual/apps-fixture" })
		end)
	end, debug.traceback)
	_G.hs = previous_hs
	if not ok then error(err, 0) end
end

helpers.describe("Bundled app discovery outcome", function()
	for _, mode in ipairs({ "exit", "signal", "throw", "invalid" }) do
		helpers.it("(apps-discovery-outcome) retries after " .. mode .. " without caching partial output", function()
			with_apps(function(module, state, ctx)
				state.output = "/virtual/Partial.app\n"
				state.status = nil
				state.code = 1
				state.kind = mode == "signal" and "signal" or "exit"
				state.throw = mode == "throw"
				if mode == "invalid" then state.status = true; state.output = false end
				module.prime(ctx)
				module.prime(ctx)
				helpers.assert_eq(state.app_scans, 2, "failed scans must remain retryable")
				helpers.assert_eq(#state.warnings, 1, "repeat failures must be bounded")
				helpers.assert_nil(state.warnings[1]:find("PRIVATE", 1, true))
				helpers.assert_nil(state.warnings[1]:find("/private", 1, true))
				helpers.assert_nil(state.warnings[1]:find("/virtual", 1, true))
				state.throw, state.status, state.kind, state.code = false, true, "exit", 0
				state.output = "/virtual/Zebra.app\n/virtual/Alpha.app\n"
				local rows = module.build(ctx).submenu
				helpers.assert_eq(rows[1].label, "Alpha")
				helpers.assert_eq(rows[2].label, "Zebra")
				local count = #state.calls
				module.build(ctx)
				helpers.assert_eq(#state.calls, count, "successful discovery must cache")
			end)
		end)
	end
	helpers.it("(apps-discovery-outcome) discards failed icon output without hiding valid apps", function()
		with_apps(function(module, state, ctx)
			state.output = "/virtual/First.app\n/virtual/Second.app\n"
			state.icon_failure = true
			local rows = module.build(ctx).submenu
			helpers.assert_eq(#rows, 2)
			helpers.assert_eq(rows[1].label, "First")
			helpers.assert_eq(#state.warnings, 1)
			helpers.assert_nil(state.warnings[1]:find("PRIVATE", 1, true))
			helpers.assert_nil(state.warnings[1]:find("/private", 1, true))
			helpers.assert_nil(state.warnings[1]:find("/virtual", 1, true))
			for _, path in ipairs(state.images) do
				helpers.assert_nil(path:find("Partial.icns", 1, true))
			end
		end)
	end)
	helpers.it("(apps-discovery-outcome) caches a successfully empty directory", function()
		with_apps(function(module, state, ctx)
			module.prime(ctx)
			local rows = module.build(ctx).submenu
			helpers.assert_eq(#state.calls, 1)
			helpers.assert_eq(rows[1].disabled, true)
			helpers.assert_eq(#state.warnings, 0)
		end)
	end)
end)

-- Handwritten caption expectations are independent of the generated declaration.
helpers.describe("the shared empty Applications caption", function()
	local Json = require("json")
	local file = assert(io.open(helpers.shared("tests/corpus/menu/apps_empty_caption.json"), "rb"))
	local corpus = assert(Json.decode(file:read("*a")))
	file:close()

	helpers.it("(apps-empty-template) retains the exact independent inert declaration", function()
		with_apps(function(_, state)
			helpers.assert_eq(state.binding.get_array(corpus.section), { corpus.row })
			local count = 0
			for _ in pairs(corpus.captions) do count = count + 1 end
			helpers.assert_eq(count, 21, "all supported languages retain independent expectations")
		end)
	end)

	for locale, expected in pairs(corpus.captions) do
		helpers.it("(apps-empty-template) relabels the cached empty provider in " .. locale, function()
			with_apps(function(module, state, ctx)
				state.render_native = true
				module.prime(ctx)
				local locale_file = assert(io.open(helpers.shared("data/locales/" .. locale .. ".json"), "rb"))
				local catalogue = assert(Json.decode(locale_file:read("*a")))
				locale_file:close()
				helpers.assert_eq(catalogue[corpus.row.i18n], expected)
				package.loaded["infra.i18n"].get = function(key) return catalogue[key] or key end
				local rows = module.build(ctx).submenu
				helpers.assert_eq(rows, { { title = expected, disabled = true } })
				helpers.assert_nil(rows[1].fn)
				helpers.assert_nil(rows[1].menu)
				helpers.assert_eq(state.app_scans, 1)
				helpers.assert_eq(next(module._active_tasks), nil, "building an inert caption cannot launch a task")
				local definition = state.binding.get_array(corpus.section)[1]
				definition.i18n = "menu.apps.title"
				helpers.assert_eq(module.build(ctx).submenu[1].title, catalogue["menu.apps.title"],
					"the provider consumes the actual shared caption, rather than repeating it natively")
				helpers.assert_eq(state.app_scans, 1, "a caption change does not invalidate discovery")
			end)
		end)
	end

	for _, mutation in ipairs({ { field = "i18n", value = "" },
		{ field = "command", value = "unowned_launch" }, { field = "foreign_field", value = true } }) do
		helpers.it("(apps-empty-template) refuses malformed " .. mutation.field .. " without launching", function()
			with_apps(function(module, state, ctx)
				state.binding.get_array(corpus.section)[1][mutation.field] = mutation.value
				helpers.assert_nil(module.build(ctx), "refused shared templates cannot fabricate a native caption")
				helpers.assert_eq(next(module._active_tasks), nil)
				helpers.assert_eq(state.app_scans, 1)
			end)
		end)
	end

	helpers.it("(apps-empty-template) retains the declared Mac-only capability", function()
		with_apps(function(module, state, ctx)
			state.binding.get_array(corpus.section)[1].platforms = { "linux" }
			helpers.assert_eq(module.build(ctx).submenu, {}, "hidden shared captions get no native stand-in")
			helpers.assert_eq(next(module._active_tasks), nil)
		end)
	end)
end)

--- Builds the real Apps owner under a genuine isolated native translator cohort.
--- @param language string Actual locale to admit through the native ownership API.
--- @param body function Independent native parent assertions.
local function with_native_apps_parent(language, body)
	local previous, previous_hs, previous_getenv = {}, rawget(_G, "hs"), os.getenv
	for name, value in pairs(package.loaded) do previous[name] = value end
	local native, owner, receipt, acquired, scratch
	local result, detail = xpcall(function()
		for _, name in ipairs({ "ui.menu.menu_apps", "infra.i18n", "infra.locale", "locale.core",
			"infra.manifest_menu", "infra.config_paths", "infra.paths", "adapters.json_codec", "menu.renderer",
			"adapters.task_lifecycle", "infra.text_utils" }) do
			package.loaded[name] = nil
		end
		helpers.load_with_stubs("infra.logger")
		scratch = assert(os.tmpname()); assert(os.remove(scratch)); assert(hs.fs.mkdir(scratch))
		assert(hs.fs.mkdir(scratch .. "/metrics"))
		local ledger = assert(io.open(scratch .. "/metrics/karabiner_kc.log", "wb")); assert(ledger:close())
		local bootstrap = assert(io.open(scratch .. "/paths.toml", "wb"))
		assert(bootstrap:write('ConfigDirPath = "' .. scratch .. '/"\n')); assert(bootstrap:close())
		os.getenv = function(name)
			if name == "ERGOPTI_PATHS_FILE" then return scratch .. "/paths.toml" end
			return previous_getenv(name)
		end
		local paths = require("infra.config_paths"); helpers.assert_eq(paths.init(scratch .. "/"), true)
		package.loaded["infra.i18n"] = nil
		native = require("infra.i18n")
		local backend = require("infra.locale")
		native.set_locale_injector(function(code) backend.set_locale(code) end); native.init()
		owner = { pending = function() return false end }
		acquired = native.scope_acquire(owner); helpers.assert_eq(acquired, true)
		receipt = assert(native.scope_capture(owner)); helpers.assert_eq(native.scope_apply(owner, receipt, language), true)
		local state = { scans = 0, launches = 0, output = "/virtual/Apps/Zebra.app\n/virtual/Apps/Alpha.app\n" }
		local old_attributes = hs.fs.attributes
		hs.fs.attributes = function(path)
			if path == "/virtual/Apps/apps" then return { mode = "directory" } end
			return old_attributes(path)
		end
		hs.execute = function(command)
			state.scans = state.scans + 1
			if state.on_scan then state.on_scan() end
			if command:find("*.icns", 1, true) then return "", true, "exit", 0 end
			return state.output, true, "exit", 0
		end
		hs.application.infoForBundlePath = function() return nil end
		local icon = {}
		hs.image.imageFromPath = function() return icon end
		local renderer = require("infra.manifest_menu")
		local lifecycle = require("adapters.task_lifecycle")
		local original_task = lifecycle.native
		lifecycle.native = function(...)
			state.launches = state.launches + 1
			return original_task(...)
		end
		local original_build = renderer.build
		renderer.build = function(...)
			local finished = original_build(...)
			state.finished = finished
			return finished
		end
		local module = require("ui.menu.menu_apps")
		body(module, renderer, state, { base_dir = "/virtual/Apps" }, native)
	end, debug.traceback)
	local restored, released, forgotten = true, true, true
	if receipt then restored = native.scope_restore(owner, receipt) == true end
	if acquired then released = native.scope_release(owner) == true end
	if receipt then forgotten = native.scope_forget(owner, receipt) == true end
	local cleanup, cleanup_error = pcall(function()
		local bridge = package.loaded["modules.keylogger.kc_bridge"]
		if bridge and not rawequal(bridge, previous["modules.keylogger.kc_bridge"]) then bridge.stop() end
		local scheduler = package.loaded["adapters.timer_scheduler"]
		if scheduler and not rawequal(scheduler, previous["adapters.timer_scheduler"]) then helpers.assert_eq(scheduler.cancelAll(), true) end
		if scratch then
			os.remove(scratch .. "/metrics/karabiner_kc.log"); os.remove(scratch .. "/paths.toml")
			if hs.fs.attributes(scratch .. "/hammerspoon") then assert(hs.fs.rmdir(scratch .. "/hammerspoon")) end
			assert(hs.fs.rmdir(scratch .. "/metrics")); assert(hs.fs.rmdir(scratch))
		end
	end)
	for name, value in pairs(package.loaded) do
		if not rawequal(value, rawget(previous, name)) then package.loaded[name] = rawget(previous, name) end
	end
	for name, value in pairs(previous) do package.loaded[name] = value end
	_G.hs = previous_hs; os.getenv = previous_getenv
	helpers.assert_eq(restored, true); helpers.assert_eq(released, true); helpers.assert_eq(forgotten, true)
	helpers.assert_eq(cleanup, true, tostring(cleanup_error))
	for name, value in pairs(previous) do helpers.assert_eq(rawequal(package.loaded[name], value), true, name) end
	if not result then error(detail, 0) end
end

helpers.describe("the complete shared Apps parent", function()
	for _, language in ipairs({ "en", "fr" }) do
		helpers.it("(apps-parent-native) retains actual complete installed rows and callbacks in " .. language, function()
			with_native_apps_parent(language, function(module, renderer, state, ctx, native)
				local file = assert(io.open(helpers.shared("tests/corpus/menus/apps_parent.json"), "rb"))
				local expected = assert(require("adapters.json_codec").decode(file:read("*a"))); assert(file:close())
				local parent = assert(module.build(ctx))
				helpers.assert_eq(parent.label, expected.captions[language])
				helpers.assert_eq(rawequal(parent.submenu, state.finished), true)
				helpers.assert_eq(#parent.submenu, 2)
				for index, name in ipairs(expected.installed_order) do
					helpers.assert_eq(parent.submenu[index].title, name)
					helpers.assert_eq(type(parent.submenu[index].fn), "function")
					helpers.assert_eq(rawequal(parent.submenu[index], state.finished[index]), true)
					helpers.assert_not_nil(parent.submenu[index].image)
				end
				helpers.assert_eq(state.launches, 0)
				helpers.assert_eq(next(module._active_tasks), nil)
				helpers.assert_eq(native.get("menu.apps.title"), expected.captions[language])
			end)
		end)
	end
end)

helpers.describe("Apps parent declaration admission", function()
	local function actual_parent(renderer)
		local parent
		for _, row in ipairs(renderer.get_root().top_level) do
			if row.id == "apps" then helpers.assert_nil(parent); parent = row end
		end
		return assert(parent)
	end

	helpers.it("(apps-parent-native) owns every actual caption and the existing platform absence", function()
		with_native_apps_parent("en", function(_, renderer)
			local file = assert(io.open(helpers.shared("tests/corpus/menus/apps_parent.json"), "rb"))
			local expected = assert(require("adapters.json_codec").decode(file:read("*a"))); assert(file:close())
			helpers.assert_eq(actual_parent(renderer), expected.row)
			local count = 0
			for language, caption in pairs(expected.captions) do
				local locale_file = assert(io.open(helpers.shared("data/locales/" .. language .. ".json"), "rb"))
				local locale = assert(require("adapters.json_codec").decode(locale_file:read("*a"))); assert(locale_file:close())
				helpers.assert_eq(locale["menu.apps.title"], caption); count = count + 1
			end
			helpers.assert_eq(count, 21)
			helpers.assert_eq(expected.platform_presence, { hs = true, ahk = false, linux = false })
		end)
	end)

	for _, mode in ipairs({ "missing", "wrong_kind", "wrong_platform", "unbound", "metatable" }) do
		helpers.it("(apps-parent-native) refuses " .. mode .. " before discovery and repairs the exact owner", function()
			with_native_apps_parent("en", function(module, renderer, state, ctx)
				local root, parent = renderer.get_root(), actual_parent(renderer)
				local top, kind, platforms, group = root.top_level, parent.type, parent.platforms, renderer.group_row
				local effects = 0
				if mode == "missing" then root.top_level = {}
				elseif mode == "wrong_kind" then parent.type = "command"
				elseif mode == "wrong_platform" then parent.platforms = { "linux" }
				elseif mode == "unbound" then renderer.group_row = nil
				else setmetatable(parent, { __index = function() effects = effects + 1 end }) end
				local ok, err = xpcall(function()
					helpers.assert_nil(module.build(ctx))
					helpers.assert_eq(state.scans, 0); helpers.assert_eq(state.launches, 0)
					helpers.assert_eq(effects, 0)
				end, debug.traceback)
				root.top_level, parent.type, parent.platforms, renderer.group_row = top, kind, platforms, group
				setmetatable(parent, nil)
				if not ok then error(err, 0) end
				local repaired = assert(module.build(ctx))
				helpers.assert_eq(#repaired.submenu, 2)
				helpers.assert_eq(rawequal(repaired.submenu, state.finished), true)
			end)
		end)
	end

	helpers.it("(apps-parent-native) refuses real source drift after discovery and retains retryable native cache", function()
		with_native_apps_parent("fr", function(module, renderer, state, ctx)
			local parent = actual_parent(renderer)
			local original = parent.i18n
			state.on_scan = function() parent.i18n = "menu.apps.none" end
			local ok, err = xpcall(function()
				helpers.assert_nil(module.build(ctx))
				helpers.assert_eq(state.scans, 1); helpers.assert_eq(state.launches, 0)
				helpers.assert_eq(next(module._active_tasks), nil)
			end, debug.traceback)
			parent.i18n, state.on_scan = original, nil
			if not ok then error(err, 0) end
			local repaired = assert(module.build(ctx))
			helpers.assert_eq(#repaired.submenu, 2)
			helpers.assert_eq(state.scans, 1, "declaration repair does not discard the committed discovery cache")
			helpers.assert_eq(rawequal(repaired.submenu, state.finished), true)
		end)
	end)

	helpers.it("(apps-parent-native) retains the genuine empty-directory status and valid empty finished trees", function()
		with_native_apps_parent("en", function(module, renderer, state, ctx)
			state.output = ""
			local parent = assert(module.build(ctx))
			helpers.assert_eq(#parent.submenu, 1)
			helpers.assert_eq(parent.submenu[1].disabled, true)
			helpers.assert_nil(parent.submenu[1].fn)
			helpers.assert_eq(rawequal(parent.submenu, state.finished), true)
			local finished = {}
			local empty_parent = assert(renderer.group_row("top_level", "apps", finished, {}))
			helpers.assert_eq(rawequal(empty_parent.submenu, finished), true)
			helpers.assert_eq(#empty_parent.submenu, 0)
			helpers.assert_eq(state.launches, 0)
		end)
	end)

	helpers.it("(apps-parent-native) preserves accepted deep completed children without walking them again", function()
		with_native_apps_parent("en", function(_, renderer, state)
			local callback = function() state.launches = state.launches + 1 end
			local image = {}
			local leaf = { title = "Leaf", fn = callback, image = image }
			local finished = { leaf }
			local current = finished
			for _ = 1, 24 do current = { { title = "Accepted native child", menu = current } } end
			local parent = assert(renderer.group_row("top_level", "apps", current, {}))
			helpers.assert_eq(rawequal(parent.submenu, current), true)
			local actual = parent.submenu
			for _ = 1, 24 do actual = actual[1].menu end
			helpers.assert_eq(rawequal(actual, finished), true)
			helpers.assert_eq(rawequal(actual[1], leaf), true)
			helpers.assert_eq(rawequal(actual[1].fn, callback), true)
			helpers.assert_eq(rawequal(actual[1].image, image), true)
			helpers.assert_eq(state.launches, 0)
		end)
	end)
end)

helpers.describe("Apps native locale cohort restoration", function()
	for _, raises in ipairs({ false, true }) do
		helpers.it("(apps-parent-native) restores a genuine French predecessor after " .. (raises and "raise" or "success"), function()
			with_native_apps_parent("fr", function(_, renderer, _, _, native)
				local names = { "infra.i18n", "infra.locale", "infra.manifest_menu", "ui.menu.menu_apps" }
				local prior = {}
				for _, name in ipairs(names) do prior[name] = rawget(package.loaded, name) end
				local ok, message = pcall(function()
					with_native_apps_parent("en", function(module, inner, state, ctx, english)
						helpers.assert_eq(english.get_locale(), "en")
						local parent = assert(module.build(ctx))
						helpers.assert_eq(parent.label, "🛠️ Applications")
						helpers.assert_eq(rawequal(parent.submenu, state.finished), true)
						helpers.assert_eq(state.launches, 0)
						if raises then error("APPS_PRIVATE_EXPECTED_RAISE") end
					end)
				end)
				helpers.assert_eq(ok, not raises, tostring(message))
				if raises then helpers.assert_eq(tostring(message):find("APPS_PRIVATE_EXPECTED_RAISE", 1, true) ~= nil, true, tostring(message)) end
				for _, name in ipairs(names) do helpers.assert_eq(rawequal(rawget(package.loaded, name), prior[name]), true, name) end
				helpers.assert_eq(native.get_locale(), "fr")
				helpers.assert_eq(rawequal(rawget(package.loaded, "infra.manifest_menu"), renderer), true)
			end)
		end)
	end
end)

helpers.describe("Apps final logger publication fence", function()
	for _, mode in ipairs({ "source_withdrawal", "getter_throw" }) do
		helpers.it("(apps-parent-native) refuses final Logger.done " .. mode .. " and repairs the original owner", function()
			with_native_apps_parent("fr", function(_, renderer, state, ctx)
				local root, get_root = renderer.get_root(), renderer.get_root
				local top = root.top_level
				local logger = package.loaded["infra.logger"]
				local done, final_calls, getter_throws = logger.done, 0, 0
				local throwing = false
				if mode == "getter_throw" then
					renderer.get_root = function()
						if throwing then getter_throws = getter_throws + 1; error("APPS_FINAL_GETTER_THROW") end
						return get_root()
					end
					-- Capture the actual current export in the real Apps constructor.
					package.loaded["ui.menu.menu_apps"] = nil
				end
				local module = require("ui.menu.menu_apps")
				logger.done = function(...)
					if select(2, ...) == "Applications submenu built (%d item(s))." then
						final_calls = final_calls + 1
						if mode == "source_withdrawal" then root.top_level = {} else throwing = true end
					end
					return done(...)
				end
				local called, result = pcall(module.build, ctx)
				-- Restore before assertions, preserving the exact prior exports/source.
				logger.done, renderer.get_root, root.top_level = done, get_root, top
				throwing = false
				helpers.assert_eq(final_calls, 1, "the genuine final logging boundary ran")
				if mode == "source_withdrawal" then
					helpers.assert_eq(called, true)
					helpers.assert_nil(result, "withdrawn parent cannot be returned")
					helpers.assert_eq(getter_throws, 0)
				else
					helpers.assert_eq(called, false, "a thrown final source read cannot publish a parent")
					helpers.assert_eq(tostring(result):find("APPS_FINAL_GETTER_THROW", 1, true) ~= nil, true)
					helpers.assert_eq(getter_throws, 1)
				end
				helpers.assert_eq(state.scans, 1, "already-admitted discovery is retained")
				helpers.assert_eq(state.launches, 0)
				helpers.assert_eq(next(module._active_tasks), nil)
				helpers.assert_eq(rawequal(root.top_level, top), true)
				local parent = assert(module.build(ctx))
				helpers.assert_eq(rawequal(parent.submenu, state.finished), true)
				helpers.assert_eq(#parent.submenu, 2)
				helpers.assert_eq(state.scans, 1, "repair retains the already committed discovery cache")
			end)
		end)
	end
end)
