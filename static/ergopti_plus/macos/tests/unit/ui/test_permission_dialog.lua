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

--- Reads one shipped locale.
--- @param code string Locale code.
--- @return table strings
local function locale_strings(code)
	local handle = assert(io.open(helpers.shared("data/locales/" .. code .. ".json"), "rb"))
	local decoded = Json.decode(handle:read("*a"))
	handle:close()
	return decoded
end

--- Reads the French locale, the maintainer's language.
--- @return table strings
local function french()
	return locale_strings("fr")
end

--- Runs one case against a fresh dialog, a recording window factory and the
--- French strings.
--- @param body function Receives the harness.
local function with_dialog(body)
	helpers.with_fresh_modules(MODULES, function()
		local fr = french()
		local h = { windows = {}, urls = {}, fr = fr }
		package.loaded["ui.ui_builder"] = {
			PERMISSION_DIALOG_CHROME = "permission_dialog",
			get_app_geometry = function(id)
				h.geometry_id = id
				return { width = 560, height = 400 }
			end,
			get_centered_frame = function(w, height) return { x = 440, y = 250, w = w, h = height } end,
			-- The shared present helper: raises and focuses, never sets a level.
			force_focus = function(wv, is_new)
				h.focuses = (h.focuses or 0) + 1
				h.focus_is_new = is_new
				return wv ~= nil
			end,
			show_webview = function(opts)
				if h.factory_error then error(h.factory_error) end
				local wv = { opts = opts, raised = 0, deleted = false }
				-- The factory double shows nothing itself, so show() is a raise.
				function wv.show(self) self.raised = self.raised + 1; return self end
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
		local active = { code = "fr", strings = fr }
		package.loaded["infra.i18n"] = {
			get_locale = function() return active.code end,
			get = function(key) return active.strings[key] or key end,
			format = function(key, ...)
				local text = active.strings[key] or key
				for n, value in ipairs({ ... }) do
					text = text:gsub("{" .. n .. "}", (tostring(value):gsub("%%", "%%%%")))
				end
				return text
			end,
		}
		--- Switches the UI language the dialog reads.
		function h.use_locale(code)
			active.code, active.strings = code, locale_strings(code)
		end
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

--- Runs one case against the real window factory while the process is
--- untrusted: the webview's window lookup goes through Accessibility, so it
--- finds nothing, and every deferred focus retry is captured to be drained.
--- @param body function Receives the harness.
local function with_untrusted_factory(body)
	local owned = { "ui.permission_dialog", "ui.ui_builder", "infra.deferred_work", "infra.i18n" }
	helpers.with_stub_scope(owned, function()
		local h = { deferred = {}, activations = 0, levels = {}, fronts = {}, shows = 0 }
		package.loaded["infra.deferred_work"] = {
			after = function(_, callback)
				h.deferred[#h.deferred + 1] = callback
				return true
			end,
		}
		local view = {}
		local native_frame
		for _, name in ipairs({ "windowTitle", "windowStyle", "shadow", "allowTextEntry", "allowGestures",
			"windowCallback", "navigationCallback", "html" }) do
			view[name] = function(self) return self end
		end
		-- The public native frame API copies scalar rectangles in both directions.
		function view.frame(self, rectangle)
			if rectangle ~= nil then
				native_frame = { x = rectangle.x, y = rectangle.y, w = rectangle.w, h = rectangle.h }
				return self
			end
			if native_frame == nil then return nil end
			return { x = native_frame.x, y = native_frame.y, w = native_frame.w, h = native_frame.h }
		end
		function view.level(self, level) h.levels[#h.levels + 1] = level; return self end
		function view.show(self) h.shows = h.shows + 1; return self end
		function view.bringToFront(self, above_all) h.fronts[#h.fronts + 1] = above_all == true; return self end
		function view.hswindow() return nil end
		function view.delete(self) return self end
		local LEVELS = { floating = 3, screenSaver = 1000 }
		h.floating = LEVELS.floating
		helpers.load_with_stubs("ui.permission_dialog", {
			webview = {
				windowMasks = { titled = 1, closable = 2, utility = 16 },
				new = function(rectangle)
					native_frame = { x = rectangle.x, y = rectangle.y, w = rectangle.w, h = rectangle.h }
					return view
				end,
				usercontent = { new = function()
					return { setCallback = function(self) return self end }
				end },
			},
			drawing = { windowLevels = LEVELS },
			focus = function() h.activations = h.activations + 1 end,
			screen = { mainScreen = function()
				return { frame = function() return { x = 0, y = 25, w = 1280, h = 775 } end }
			end },
			processInfo = { bundlePath = BUNDLE_PATH, bundleID = "com.ergoptiplus.app.hammerspoon" },
		})
		h.dialog = require("ui.permission_dialog")
		h.permission = require("adapters.accessibility_permission")
		--- Runs every deferred focus retry, including those each retry schedules.
		function h.drain()
			local ran = 0
			while #h.deferred > 0 and ran < 100 do
				table.remove(h.deferred, 1)()
				ran = ran + 1
			end
		end
		body(h)
	end)
end

helpers.describe("permission dialog (permission-dialog-native)", function()
	helpers.it("stays at the floating level and never takes focus while untrusted", function()
		with_untrusted_factory(function(h)
			h.dialog.guide_accessibility(h.permission)
			helpers.assert_eq(h.dialog.is_open("accessibility"), true)
			h.drain()
			h.dialog.guide_accessibility(h.permission)
			h.drain()
			helpers.assert_eq(h.shows, 2, "shown once, then raised within its level")
			for _, above_all in ipairs(h.fronts) do
				helpers.assert_eq(above_all, false,
					"the screen-saver level would cover System Settings and the macOS prompt")
			end
			helpers.assert_eq(#h.levels, 1)
			helpers.assert_eq(h.levels[1], h.floating, "the chrome level is the only level set")
			helpers.assert_eq(h.activations, 0, "activating Hammerspoon pulls focus away from System Settings")
		end)
	end)

	helpers.it("shows a native window with the localized title, steps and buttons", function()
		with_dialog(function(h)
			local close = h.dialog.guide_accessibility(h.permission)
			helpers.assert_eq(type(close), "function")
			helpers.assert_eq(#h.windows, 1, "one window, not a banner")
			local opts = h.windows[1].opts
			helpers.assert_eq(h.geometry_id, "permission_dialog")
			helpers.assert_eq(opts.focus, false, "the dialog never takes focus from System Settings")
			helpers.assert_eq(opts.chrome, "permission_dialog", "the factory's one floating exception")
			helpers.assert_eq(opts.title, h.fr["permission_dialog.window_title"],
				"the brand-less title: ui_builder adds the product prefix once")
			helpers.assert_true(opts.usercontent ~= nil, "buttons answer through the script bridge")
			local html = opts.html_string
			helpers.assert_contains(html, "Autoriser ErgoptiPlus dans Accessibilité")
			helpers.assert_contains(html, "<ol>")
			-- The dialog opens before the pane, which may not open at all, while
			-- macOS shows its own prompt for the same permission.
			helpers.assert_true(html:find("vient de s’ouvrir", 1, true) == nil,
				"step 1 must not say the pane has opened before it has")
			helpers.assert_contains(html, "(sinon, cliquez sur « Ouvrir les Réglages »)",
				"step 1 names the button that opens the pane when it did not open")
			helpers.assert_contains(html, "Si macOS le demande aussi, choisissez d’ouvrir Réglages Système.")
			helpers.assert_contains(html, "rouvrez ErgoptiPlus pour revoir ces étapes",
				"Later must say how to get the steps back")
			helpers.assert_contains(html, "Activez « Hammerspoon » dans la liste")
			-- A stock Hammerspoon with its own grant is listed under the same name
			-- and icon, switched on; the reset leaves the ErgoptiPlus entry off.
			helpers.assert_contains(html, "S’il y en a deux, activez celui qui est désactivé.",
				"with two “Hammerspoon” entries the step must say which one to turn on")
			helpers.assert_true(html:find("S’il semble déjà activé", 1, true) == nil,
				"toggling an entry that looks on would flip the stock Hammerspoon one")
			helpers.assert_contains(html, '<html lang="fr" dir="auto">')
			helpers.assert_contains(html, '<code dir="ltr">' .. BUNDLE_PATH .. "</code>")
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

	helpers.it("comes back on reopen and closes itself when the grant poll succeeds", function()
		with_dialog(function(h)
			local Wait = require("infra.accessibility_wait")
			local tick, reopen
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
				watch_reopen = function(on_reopen) reopen = on_reopen; return function() end end,
				on_trusted = function() events[#events + 1] = "trusted" end,
				on_timeout = function() events[#events + 1] = "timeout" end,
				poll_seconds = 1,
				deadline_seconds = 600,
			})
			helpers.assert_eq(started, true, "the wait returns at once: the dialog blocks nothing")
			helpers.assert_eq(h.open_count(), 1)
			tick()
			helpers.assert_eq(h.open_count(), 1, "still open while untrusted")
			h.click("later")
			helpers.assert_eq(h.open_count(), 0)
			reopen()
			helpers.assert_eq(h.open_count(), 1, "reopening ErgoptiPlus brings the steps back after Later")
			reopen()
			helpers.assert_eq(#h.windows, 2, "a reopen with the dialog open raises it, never a copy")
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
				locale = "fr", title = "<b>&", body = "\"x\"", steps = { "a", "b", "c /p<q" },
				open_label = "O", later_label = "L",
			}, "/p<q", nil)
			helpers.assert_contains(html, "&lt;b&gt;&amp;")
			helpers.assert_contains(html, "&quot;x&quot;")
			helpers.assert_contains(html, "<code dir=\"ltr\">/p&lt;q</code>")
			helpers.assert_true(html:find("<b>&", 1, true) == nil)
		end)
	end)

	-- Tap-holds stayed off until the remap guardian was allowed in the
	-- background, and nothing said where: the same dialog now has those steps.
	helpers.it("shows the Login Items steps as an ordinary focused window (guardian-approval-steps)", function()
		with_dialog(function(h)
			local opened = 0
			helpers.assert_eq(h.dialog.show({
				kind = "login_items", open_settings = function() opened = opened + 1; return true end,
			}), true, "the Login Items kind quotes no path")
			helpers.assert_eq(#h.windows, 1)
			local opts = h.windows[1].opts
			helpers.assert_true(opts.focus ~= false, "a trusted process presents it focused (ui-focus-not-topmost)")
			helpers.assert_nil(opts.chrome, "only the Accessibility dialog floats above other apps")
			helpers.assert_eq(opts.title, h.fr["permission_dialog.window_title"])
			local html = opts.html_string
			helpers.assert_contains(html, "<h1>Autoriser ErgoptiPlus en arrière-plan</h1>")
			helpers.assert_contains(html, "Cliquez sur « Ouvrir les Réglages » : Réglages Système s’ouvre sur "
				.. "Général &gt; Ouverture et extensions", "step 1 names the pane and the button that opens it")
			helpers.assert_contains(html, "« Autoriser en arrière-plan »", "step 2 names the list macOS shows")
			helpers.assert_contains(html, "Activez l’interrupteur à côté d’ErgoptiPlus.")
			local _, items = html:gsub("<li>", "")
			helpers.assert_eq(items, 3, "three numbered steps")
			helpers.assert_true(html:find("<code", 1, true) == nil, "no path to paste in Login Items")
			helpers.assert_true(html:find("Hammerspoon", 1, true) == nil,
				"macOS lists the guardian under the app's name")
			h.click("open_settings")
			helpers.assert_eq(opened, 1, "Open Settings runs the Login Items opener")
		end)
	end)

	helpers.it("raises an open Login Items dialog through the focus helper", function()
		with_dialog(function(h)
			local spec = { kind = "login_items", open_settings = function() return true end }
			h.dialog.show(spec)
			h.dialog.show(spec)
			helpers.assert_eq(#h.windows, 1, "one owner, one window")
			helpers.assert_eq(h.focuses, 1, "presented again like any window")
			helpers.assert_eq(h.focus_is_new, false)
			helpers.assert_eq(h.windows[1].raised, 0, "the floating raise is the Accessibility one only")
		end)
	end)

	helpers.it("tells its owner once, whoever closes the dialog", function()
		with_dialog(function(h)
			local closes = 0
			local function show()
				return h.dialog.show({
					kind = "login_items",
					open_settings = function() return true end,
					on_closed = function() closes = closes + 1 end,
				})
			end
			show()
			h.click("later")
			helpers.assert_eq(closes, 1, "Later")
			show()
			h.windows[#h.windows]:delete()
			helpers.assert_eq(closes, 2, "the close button")
			show()
			helpers.assert_eq(h.dialog.close("login_items"), true)
			helpers.assert_eq(closes, 3, "the owner's own close")
			show()
			h.dialog.guide_accessibility(h.permission)
			helpers.assert_eq(closes, 4, "another permission taking the dialog")
			helpers.assert_eq(h.dialog.close("accessibility"), true)
			helpers.assert_eq(closes, 4, "each close is reported once")
		end)
	end)

	helpers.it("reads right to left in Hebrew and Arabic", function()
		for _, code in ipairs({ "he", "ar" }) do
			with_dialog(function(h)
				h.use_locale(code)
				h.dialog.guide_accessibility(h.permission)
				local html = h.windows[1].opts.html_string
				helpers.assert_contains(html, '<html lang="' .. code .. '" dir="auto">',
					"the page direction follows the translated text")
				local title = h.dialog.content("accessibility", BUNDLE_PATH).title
				helpers.assert_contains(html, "<h1>" .. title)
				-- dir="auto" takes the first strong letter of the page, the title's:
				-- U+0590..U+06FF (Hebrew, Arabic) start with UTF-8 bytes 0xD6..0xDB.
				local lead = title:byte(1)
				helpers.assert_true(lead >= 0xD6 and lead <= 0xDB,
					"the " .. code .. " title must open with a right-to-left letter for dir=auto")
				local login_lead = h.dialog.content("login_items").title:byte(1)
				helpers.assert_true(login_lead >= 0xD6 and login_lead <= 0xDB,
					"the " .. code .. " Login Items title must open with a right-to-left letter too")
				helpers.assert_true(html:find("80px;padding:0 0 0", 1, true) == nil
					and html:find("margin-inline-start:80px", 1, true) ~= nil,
					"a left margin would keep the steps on the left of a right-to-left page")
				helpers.assert_contains(html, '<code dir="ltr">' .. BUNDLE_PATH .. "</code>",
					"the path reads left to right inside a right-to-left step")
				local code_rule = html:match("code{[^}]*}") or ""
				helpers.assert_contains(code_rule, "display:inline-block",
					"an inline path wrapped in a right-to-left line starts at the wrong end")
			end)
		end
	end)
end)
