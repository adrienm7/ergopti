--- tests/unit/ui/webview/test_every_app_window_title.lua

--- ==============================================================================
--- MODULE: Every App Window Title
--- DESCRIPTION:
--- Composes the native caption of every window the shared UI manifest declares,
--- through the caption owner the GTK window uses, in every shipped locale, and
--- refuses a caption that names the product twice or repeats a segment.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

--- Reads one shared JSON document.
--- @param relative string Path under the shared tree.
--- @return table
local function read_shared(relative)
	local file = assert(io.open(helpers.driver_root() .. "/../_shared/" .. relative, "r"))
	local data = assert(Json.decode(file:read("*a")))
	file:close()
	return data
end

local MANIFEST = read_shared("ui/apps.manifest.json")
local LOCALES = read_shared("data/locale_order.json").order

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

helpers.describe("every manifest window title (linux)", function()
	helpers.it("(window-title-brand-once) names the product once in every locale", function()
		helpers.assert_eq(#LOCALES, 21)
		local apps = {}
		for app_id in pairs(MANIFEST.apps) do apps[#apps + 1] = app_id end
		table.sort(apps)
		helpers.assert_true(#apps > 0, "the shared UI manifest declares its windows")
		local locale = require("infra.locale")
		local i18n = require("infra.i18n")
		local manager = helpers.load_module("ui.webview_manager")
		local previous = locale.current_locale()
		local ok, failure = xpcall(function()
			for _, code in ipairs(LOCALES) do
				locale.set_locale(code)
				for _, app_id in ipairs(apps) do
					local key = MANIFEST.apps[app_id].title_key
					local label = i18n.get(key)
					helpers.assert_true(type(label) == "string" and label ~= "" and label ~= key,
						code .. " " .. app_id .. " has a translated name")
					assert_caption(manager.app_caption(app_id), label, code .. " " .. app_id)
				end
			end
		end, debug.traceback)
		locale.set_locale(previous)
		if not ok then error(failure, 0) end
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
