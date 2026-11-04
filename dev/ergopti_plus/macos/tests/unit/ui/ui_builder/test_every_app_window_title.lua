--- tests/unit/ui/ui_builder/test_every_app_window_title.lua

--- ==============================================================================
--- MODULE: Every App Window Title
--- DESCRIPTION:
--- Opens every window the shared UI manifest declares through the real WebView
--- factory, in every shipped locale, and refuses a native caption that names the
--- product twice or repeats a segment, whichever layer added it.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

--- Reads one shared JSON document.
--- @param relative string Path under the shared tree.
--- @return table
local function read_shared(relative)
	local file = assert(io.open(helpers.shared(relative), "r"))
	local data = assert(Json.decode(file:read("*a")))
	file:close()
	return data
end

local MANIFEST = read_shared("ui/apps.manifest.json")
local LOCALES = read_shared("data/locale_order.json").order

--- Runs callback with the real factory, translator and title policy loaded over
--- a modeled native webview that records every caption it receives.
--- @param callback function Receives the factory, the captions and the translator.
local function with_factory(callback)
	local previous_base = rawget(_G, "_base_dir")
	local ok, failure = xpcall(function()
		helpers.with_stub_scope({
			"ui.ui_builder", "ui.webview_close_owner", "infra.i18n", "infra.locale", "locale.core",
			"infra.logger", "infra.paths", "infra.deferred_work", "adapters.json_codec",
			"adapters.timer_scheduler", "adapters.storage", "webview.i18n_seed", "window_titles",
			"hs", "tests.stubs.hs",
		}, function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.paths"] = { shared = helpers.shared }
			package.loaded["infra.deferred_work"] = { after = function() return true end }
			local captions = {}
			local function new_view()
				local view = {}
				function view:windowTitle(caption)
					captions[#captions + 1] = caption
					return self
				end
				for _, name in ipairs({ "windowStyle", "level", "allowTextEntry", "allowGestures",
					"shadow", "windowCallback", "navigationCallback", "html", "show" }) do
					view[name] = function() return view end
				end
				function view:allowNewWindows(value)
					if value == nil then return self.allow_new_windows ~= false end
					self.allow_new_windows = value
					return self
				end
				function view:deleteOnClose(value)
					if value == nil then return self.delete_on_close == true end
					self.delete_on_close = value
					return self
				end
				function view:hswindow() return nil end
				function view:delete() return self end
				return view
			end
			local builder = helpers.load_with_stubs("ui.ui_builder", {
				json = { decode = Json.decode, encode = Json.encode },
				webview = { windowMasks = { titled = 1, closable = 2, utility = 16 }, new = new_view },
			})
			-- The loader injects a passthrough translator; require the real one after it.
			package.loaded["infra.i18n"] = nil
			callback(builder, captions, require("infra.i18n"), require("infra.locale"))
		end)
	end, debug.traceback)
	rawset(_G, "_base_dir", previous_base)
	if not ok then error(failure, 0) end
end

--- Asserts that a caption is the brand once, then the translated window name.
--- @param caption string The native caption.
--- @param label string The window's translated name.
--- @param context string Locale and app identity for the failure message.
local function assert_caption(caption, label, context)
	local prefix, separator = MANIFEST.window_title.prefix, MANIFEST.window_title.separator
	local count, from = 0, 1
	while true do
		local at = caption:find(prefix, from, true)
		if not at then break end
		count, from = count + 1, at + #prefix
	end
	helpers.assert_eq(count, 1, context .. " names the product exactly once: " .. caption)
	local previous, rest = nil, caption
	while rest do
		local at = rest:find(separator, 1, true)
		local segment = at and rest:sub(1, at - 1) or rest
		helpers.assert_true(segment ~= previous, context .. " repeats a caption segment: " .. caption)
		previous, rest = segment, at and rest:sub(at + #separator) or nil
	end
	helpers.assert_eq(caption, prefix .. separator .. label, context .. " names its window after the brand")
end

helpers.describe("every manifest window title", function()
	helpers.it("(window-title-brand-once) names the product once in every locale", function()
		helpers.assert_eq(#LOCALES, 21)
		local apps = {}
		for app_id in pairs(MANIFEST.apps) do apps[#apps + 1] = app_id end
		table.sort(apps)
		helpers.assert_true(#apps > 0, "the shared UI manifest declares its windows")
		with_factory(function(builder, captions, i18n, locale)
			for _, code in ipairs(LOCALES) do
				locale.set_locale(code)
				for _, app_id in ipairs(apps) do
					local key = MANIFEST.apps[app_id].title_key
					local label = i18n.get(key)
					helpers.assert_true(type(label) == "string" and label ~= "" and label ~= key,
						code .. " " .. app_id .. " has a translated name")
					local before = #captions
					local acquired = false
					local view = builder.show_webview({
						app_id = app_id,
						frame = { x = 0, y = 0, w = 200, h = 150 },
						html_string = "<html></html>",
						on_webview_created = function() acquired = true; return true end,
						is_current = function() return acquired end,
						schedule_after = function() return true end,
					})
					helpers.assert_true(view ~= nil, code .. " " .. app_id .. " opens")
					helpers.assert_eq(#captions, before + 1, code .. " " .. app_id .. " receives one caption")
					assert_caption(captions[#captions], label, code .. " " .. app_id)
				end
			end
		end)
	end)

	helpers.it("(window-title-brand-once) the caption check refuses a doubled brand", function()
		local prefix, separator = MANIFEST.window_title.prefix, MANIFEST.window_title.separator
		local doubled = prefix .. separator .. prefix .. separator .. "Unused settings"
		helpers.assert_throws(function() assert_caption(doubled, prefix .. separator .. "Unused settings", "doubled") end)
		local repeated = prefix .. separator .. "Paths" .. separator .. "Paths"
		helpers.assert_throws(function() assert_caption(repeated, "Paths" .. separator .. "Paths", "repeated") end)
		assert_caption(prefix .. separator .. "Paths", "Paths", "single")
	end)
end)
