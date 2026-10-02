--- tests/unit/ui/test_diagnostics_window_title.lua

--- ==============================================================================
--- MODULE: Shared Application Native Window Titles
--- DESCRIPTION:
--- Exercises the real GTK constructor path with every shipped translation and
--- captures the final title passed to Gtk.Window, after product-name composition.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

helpers.describe("shared application native window titles", function()
	helpers.it("passes every shared application caption to GTK in every locale", function()
		local names = { "lgi", "ui.webview_manager", "infra.i18n", "adapters.event_loop" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local ok, failure = xpcall(function()
			local captured, label, label_key
			package.loaded.lgi = {
				Gtk = {
					WindowPosition = { CENTER = 1 }, WindowType = { TOPLEVEL = 1 },
					Window = function(properties)
						captured = properties.title
						return { set_size_request = function() end, add = function() end,
							show_all = function() end, present = function() end, destroy = function() end }
					end,
				},
				WebKit2 = {
					UserContentManager = function()
						return { register_script_message_handler = function() end, on_script_message_received = {} }
					end,
					WebView = function() return { load_html = function() end } end,
				},
				GLib = {},
			}
			package.loaded["adapters.event_loop"] = { add_idle_handler = function() end }
			package.loaded["infra.i18n"] = { get = function(key)
				assert(key == label_key)
				return label
			end }
			package.loaded["ui.webview_manager"] = nil
			local manager = require("ui.webview_manager")
			manager.init()
			local function read_json(relative)
				local path = assert(require("infra.paths").shared(relative))
				local file = assert(io.open(path, "rb"))
				local text = file:read("*a")
				file:close()
				return Json.decode(text)
			end
			local locales = read_json("data/locale_order.json").order
			local apps = read_json("ui/apps.manifest.json").apps
			helpers.assert_eq(#locales, 21)
			for _, locale in ipairs(locales) do
				local strings = read_json("data/locales/" .. locale .. ".json")
				for app, entry in pairs(apps) do
					local key = entry.title_key
					label_key, label = key, strings[key]
					helpers.assert_true(type(label) == "string" and label ~= "", locale .. " has " .. key)
					local bridge = require("ui.webkit_host").bridge_for_app(app)
					if bridge then
						helpers.assert_true(manager._create_gtk_window(app, "<html></html>", { bridge_name = bridge }))
						helpers.assert_eq(captured, "ErgoptiPlus — " .. label, locale .. " native " .. app .. " title")
						manager._destroy_gtk_window(app)
					else
						helpers.assert_eq(app, "permission_dialog", "only the macOS permission-repair dialog lacks a GTK owner")
					end
				end
			end
		end, debug.traceback)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(failure, 0) end
	end)
end)
