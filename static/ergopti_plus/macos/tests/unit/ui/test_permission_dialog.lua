--- tests/unit/ui/test_permission_dialog.lua

--- ==============================================================================
--- MODULE: Permission dialog (permission-dialog-native)
--- DESCRIPTION:
--- After an update, the first launch printed the Accessibility instructions as
--- one long single-line banner along the Dock. The wait now shows a native
--- window: the localized title, numbered steps naming "Hammerspoon" and its
--- path, "Open Settings" reopening the exact pane and "Later". It must close
--- itself when the grant poll succeeds, never stack a second copy, and never
--- block or break the boot.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local ACCESSIBILITY_URL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
local BUNDLE_PATH = "/Applications/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app"

local MODULES = {
	"ui.permission_dialog", "ui.ui_builder", "infra.i18n", "infra.accessibility_wait",
	"adapters.accessibility_permission", "adapters.shell_runner",
}

--- Reads the French locale, the maintainer's language.
--- @return table strings
local function french()
	local handle = assert(io.open(helpers.shared("data/locales/fr.json"), "rb"))
	local decoded = Json.decode(handle:read("*a"))
	handle:close()
	return decoded
end

--- Runs one case against a fresh dialog, a recording window factory and the
--- French strings.
--- @param body function Receives the harness.
local function with_dialog(body)
	helpers.with_fresh_modules(MODULES, function()
		local fr = french()
		local h = { windows = {}, urls = {}, fr = fr }
		package.loaded["ui.ui_builder"] = {
			get_app_geometry = function(id)
				h.geometry_id = id
				return { width = 560, height = 400 }
			end,
			get_centered_frame = function(w, height) return { x = 440, y = 250, w = w, h = height } end,
			show_webview = function(opts)
				if h.factory_error then error(h.factory_error) end
				local wv = { opts = opts, raised = 0, deleted = false }
				function wv.show(self) return self end
				function wv.bringToFront(self) self.raised = self.raised + 1; return self end
				function wv.delete(self)
					self.deleted = true
					opts.on_close()
				end
				h.windows[#h.windows + 1] = wv
				return wv
			end,
		}
		package.loaded["adapters.shell_runner"] = {
			open = function(url) h.urls[#h.urls + 1] = url; return true end,
		}
		h.dialog = helpers.load_with_stubs("ui.permission_dialog", {
			webview = { usercontent = { new = function(name)
				h.bridge_name = name
				return { setCallback = function(self, fn) h.post = fn; return self end }
			end } },
			image = { imageFromName = function()
				return { encodeAsURLString = function() return "data:image/png;base64,AAAA" end }
			end },
			screen = { mainScreen = function()
				return { frame = function() return { x = 0, y = 25, w = 1440, h = 875 } end }
			end },
			processInfo = { bundlePath = BUNDLE_PATH, bundleID = "com.ergoptiplus.app.hammerspoon" },
		})
		-- load_with_stubs installs its key-echo i18n baseline; the dialog captures
		-- i18n at require time, so the French fake goes in and the dialog reloads.
		package.loaded["infra.i18n"] = {
			get = function(key) return fr[key] or key end,
			format = function(key, ...)
				local text = fr[key] or key
				for n, value in ipairs({ ... }) do
					text = text:gsub("{" .. n .. "}", (tostring(value):gsub("%%", "%%%%")))
				end
				return text
			end,
		}
		package.loaded["ui.permission_dialog"] = nil
		h.dialog = require("ui.permission_dialog")
		h.permission = require("adapters.accessibility_permission")
		--- Posts one button action as the page does.
		function h.click(action) h.post({ body = { action = action } }) end
		--- Counts the windows still open.
		function h.open_count()
			local count = 0
			for _, wv in ipairs(h.windows) do if not wv.deleted then count = count + 1 end end
			return count
		end
		body(h)
		-- with_fresh_modules restores the cache too; the explicit release keeps
		-- the suite-wide shell_runner stub hygiene scan able to see it.
		package.loaded["adapters.shell_runner"] = nil
	end)
end

helpers.describe("permission dialog (permission-dialog-native)", function()
	helpers.it("shows a native window with the localized title, steps and buttons", function()
		with_dialog(function(h)
			local close = h.dialog.guide_accessibility(h.permission)
			helpers.assert_eq(type(close), "function")
			helpers.assert_eq(#h.windows, 1, "one window, not a banner")
			local opts = h.windows[1].opts
			helpers.assert_eq(h.geometry_id, "permission_dialog")
			helpers.assert_eq(opts.title, h.fr["permission_dialog.window_title"],
				"the brand-less title: ui_builder adds the product prefix once")
			helpers.assert_true(opts.usercontent ~= nil, "buttons answer through the script bridge")
			local html = opts.html_string
			helpers.assert_contains(html, "Autoriser ErgoptiPlus dans Accessibilité")
			helpers.assert_contains(html, "<ol>")
			helpers.assert_contains(html, "vient de s’ouvrir")
			helpers.assert_contains(html, "Activez « Hammerspoon » dans la liste")
			helpers.assert_contains(html, "<code>" .. BUNDLE_PATH .. "</code>")
			helpers.assert_contains(html, ">Ouvrir les Réglages</button>")
			helpers.assert_contains(html, ">" .. h.fr["common.later"] .. "</button>")
			helpers.assert_contains(html, "data:image/png;base64,AAAA")
			helpers.assert_contains(html, "messageHandlers." .. h.bridge_name .. ".postMessage")
			helpers.assert_eq(opts.frame.x, 40, "the dialog leaves the Settings switches uncovered")
		end)
	end)

	helpers.it("reopens the exact Accessibility pane from Open Settings", function()
		with_dialog(function(h)
			h.dialog.guide_accessibility(h.permission)
			h.click("open_settings")
			helpers.assert_eq(#h.urls, 1)
			helpers.assert_eq(h.urls[1], ACCESSIBILITY_URL)
			helpers.assert_eq(h.open_count(), 1, "the dialog stays while the user acts")
		end)
	end)

	helpers.it("closes on Later without stopping anything else", function()
		with_dialog(function(h)
			h.dialog.guide_accessibility(h.permission)
			h.click("later")
			helpers.assert_eq(h.open_count(), 0)
			helpers.assert_eq(h.dialog.is_open("accessibility"), false)
			helpers.assert_eq(#h.urls, 0)
		end)
	end)

	helpers.it("raises the open dialog instead of stacking a duplicate", function()
		with_dialog(function(h)
			h.dialog.guide_accessibility(h.permission)
			h.dialog.guide_accessibility(h.permission)
			helpers.assert_eq(h.dialog.show({
				kind = "accessibility", open_settings = h.permission.open_settings, bundle_path = BUNDLE_PATH,
			}), true)
			helpers.assert_eq(#h.windows, 1, "one owner, one window")
			helpers.assert_eq(h.windows[1].raised, 2, "each repeat raises the existing window")
			h.windows[1]:delete()
			helpers.assert_eq(h.dialog.is_open(), false, "the user's close button releases the owner")
			h.dialog.guide_accessibility(h.permission)
			helpers.assert_eq(#h.windows, 2, "a closed dialog can be shown again")
		end)
	end)

	helpers.it("closes itself when the grant poll succeeds and resumes the boot", function()
		with_dialog(function(h)
			local Wait = require("infra.accessibility_wait")
			local tick
			local trusted = false
			local events = {}
			local permission = setmetatable({
				is_trusted = function() return trusted end,
				request_prompt = function() return true end,
				bundle_id = function() return nil, "no bundle in the test" end,
				reset_grant = function() return true end,
				open_settings = function() return true end,
			}, { __index = h.permission })
			local close_dialog = function() end
			local started = Wait.start({
				permission = permission,
				every = function(_, fn) tick = fn; return "timer", true end,
				cancel = function() return true end,
				show_guidance = function() close_dialog = h.dialog.guide_accessibility(permission) end,
				close_guidance = function() close_dialog() end,
				on_trusted = function() events[#events + 1] = "trusted" end,
				on_timeout = function() events[#events + 1] = "timeout" end,
				poll_seconds = 1,
				deadline_seconds = 600,
			})
			helpers.assert_eq(started, true, "the wait returns at once: the dialog blocks nothing")
			helpers.assert_eq(h.open_count(), 1)
			tick()
			helpers.assert_eq(h.open_count(), 1, "still open while untrusted")
			trusted = true
			tick()
			helpers.assert_eq(h.open_count(), 0, "the grant closes the dialog")
			helpers.assert_eq(events[1], "trusted")
		end)
	end)

	helpers.it("never raises into the boot when the window cannot be built", function()
		with_dialog(function(h)
			h.factory_error = "WebKit unavailable"
			local close = h.dialog.guide_accessibility(h.permission)
			helpers.assert_eq(type(close), "function", "the wait still gets a closer")
			helpers.assert_eq(h.dialog.is_open(), false, "a failed window leaves no owner behind")
			close()
			local no_path = setmetatable({ bundle_path = function() return nil, "absent" end },
				{ __index = h.permission })
			h.factory_error = nil
			helpers.assert_eq(type(h.dialog.guide_accessibility(no_path)), "function")
			helpers.assert_eq(#h.windows, 0, "a dialog that cannot name the app is not shown")
			h.dialog.guide_accessibility(h.permission)
			helpers.assert_eq(#h.windows, 1, "a later request still opens the dialog")
		end)
	end)

	helpers.it("escapes translated text and the path in the page", function()
		with_dialog(function(h)
			local html = h.dialog.render({
				title = "<b>&", body = "\"x\"", steps = { "a", "b", "c /p<q" },
				open_label = "O", later_label = "L",
			}, "/p<q", nil)
			helpers.assert_contains(html, "&lt;b&gt;&amp;")
			helpers.assert_contains(html, "&quot;x&quot;")
			helpers.assert_contains(html, "<code>/p&lt;q</code>")
			helpers.assert_true(html:find("<b>&", 1, true) == nil)
		end)
	end)
end)
