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
