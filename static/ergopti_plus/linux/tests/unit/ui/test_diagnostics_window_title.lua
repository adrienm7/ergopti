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
			local controls = { register = true, connect = true, windows = 0, views = 0, serial = 0 }
			package.loaded.lgi = {
				Gtk = {
					WindowPosition = { CENTER = 1 }, WindowType = { TOPLEVEL = 1 },
					Window = function(properties)
						captured = properties.title
						controls.windows = controls.windows + 1
						return { set_size_request = function() end, add = function() end,
							show_all = function() end, present = function() end, destroy = function() end }
					end,
				},
				WebKit2 = {
					UserContentManager = function()
						local ucm = { connected = {} }
						function ucm:register_script_message_handler(name)
							helpers.assert_true(type(name) == "string" and name ~= "")
							self.bridge_name = name
							if controls.register == "throw" then error("controlled registration refusal") end
							return controls.register
						end
						function ucm:unregister_script_message_handler(name)
							helpers.assert_eq(name, self.bridge_name, "only the owned registration retires")
							return true
						end
						ucm.on_script_message_received = { connect = function(_, callback, detail)
							helpers.assert_eq(detail, ucm.bridge_name, "only the registered detailed signal connects")
							helpers.assert_true(type(callback) == "function")
							if controls.connect == "throw" then error("controlled connection refusal") end
							if controls.connect ~= true then return controls.connect end
							controls.serial = controls.serial + 1
							ucm.connected[controls.serial] = true
							return controls.serial
						end }
						return ucm
					end,
					WebView = function()
						controls.views = controls.views + 1
						return { load_html = function() end, destroy = function(self)
							if self.on_destroy then self.on_destroy() end
						end }
					end,
				},
				GLib = {},
				GObject = {
					signal_handler_disconnect = function(ucm, id)
						helpers.assert_true(ucm.connected[id] == true, "exact owned signal connection retires")
						ucm.connected[id] = false
					end,
					signal_handler_is_connected = function(ucm, id) return ucm.connected[id] == true end,
				},
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
						helpers.assert_true(manager._destroy_gtk_window(app), "exact controlled child/signal/window retirement")
					else
						helpers.assert_eq(app, "permission_dialog", "only the macOS permission-repair dialog lacks a GTK owner")
					end
				end
			end
			-- These are controlled native-port refusals, not GUI qualification.
			label_key, label = "menu.debug.healthcheck", "Controlled diagnostic title"
			for _, port in ipairs({ "register", "connect" }) do
				for _, refusal in ipairs({ "nil", "false", "throw" }) do
					controls.register, controls.connect = true, true
					if refusal == "false" then controls[port] = false
					elseif refusal == "throw" then controls[port] = "throw"
					else controls[port] = nil end
					local windows, views = controls.windows, controls.views
					helpers.assert_true(not manager._create_gtk_window("healthcheck", "<html></html>",
						{ bridge_name = "healthcheck" }), "unacknowledged " .. port .. " refuses acquisition")
					helpers.assert_eq(controls.windows, windows + 1)
					helpers.assert_eq(controls.views, views, "no child allocated after refused " .. port)
					helpers.assert_true(not manager._create_gtk_window("healthcheck", "<html></html>",
						{ bridge_name = "healthcheck" }), "refused attempt retains native acquisition")
					helpers.assert_eq(controls.windows, windows + 1, "no successor before exact retirement")
					helpers.assert_true(manager._destroy_gtk_window("healthcheck"), "explicit exact failed-attempt retirement")
					helpers.assert_eq(manager.webview_for("healthcheck"), nil, "refused attempt physically retired")
				end
			end
		end, debug.traceback)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(failure, 0) end
	end)
end)
