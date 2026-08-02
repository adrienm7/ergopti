--- tests/unit/lib/test_app_picker_percent_in_app_name.lua

--- ==============================================================================
--- MODULE: app_picker "%" in app name regression test
--- DESCRIPTION:
--- Guards the gsub replacement-string hazard in infra/app_picker.lua's build_menu().
---
--- ROOT CAUSE ENCODED:
--- The "Exclude {app}" entry was rendered with
---     i18n.get("app_picker.exclude_current"):gsub("{app}", appName)
--- where appName is the REPLACEMENT argument. Lua gives "%" a special meaning
--- there: "%1".."%9" are capture references, "%%" is a literal percent, and "%"
--- followed by anything else RAISES "invalid use of '%' in replacement string".
--- Application names are third-party-controlled, so an app legitimately named
--- "100% Orange Juice" made build_menu() throw while it was frontmost. The
--- manifest renderer catches, logs and skips the failing item, so the whole
--- "Exclude apps" submenu silently disappeared with no on-screen hint — and only
--- while that one app had focus, which makes it maddening to reproduce.
---
--- The fix routes every third-party string through escape_replacement() before
--- interpolation, so the "%" survives as a literal.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==================================================================
-- ==================================================================
-- ======= 1/ A "%" in the frontmost app name must not throw ========
-- ==================================================================
-- ==================================================================

helpers.describe("app_picker — a '%' in the frontmost app name", function()

	--- Loads lib.app_picker with a frontmost-application stub carrying the given
	--- name, plus the i18n template that interpolates it.
	--- @param app_name string The name the frontmost application reports.
	--- @return table The freshly loaded AppPicker module.
	local function load_picker_with_front_app(app_name)
		local AppPicker = helpers.load_with_stubs("infra.app_picker", {
			application = {
				frontmostApplication = function()
					return {
						name     = function() return app_name end,
						bundleID = function() return "com.test.percent" end,
						path     = function() return "/Applications/" .. app_name .. ".app" end,
					}
				end,
				infoForBundlePath = function() return nil end,
			},
		})

		-- load_with_stubs installs an identity i18n stub; override it so the
		-- exclude entry actually exercises the "{app}" interpolation.
		package.loaded["infra.i18n"] = {
			get = function(key)
				if key == "app_picker.exclude_current" then return "Exclude {app}" end
				return key
			end,
			get_locale       = function() return "fr" end,
			set_locale       = function() end,
			decorate_section = function(text) return "— " .. text .. " —" end,
			section          = function(key) return "— " .. key .. " —" end,
		}

		-- app_picker captures lib.i18n at require-time, so reload it now that the
		-- richer stub is in place.
		package.loaded["infra.app_picker"] = nil
		return require("infra.app_picker")
	end

	--- Finds a menu entry whose plain-string title matches exactly.
	--- @param menu table The built menu structure.
	--- @param title string The exact title to look for.
	--- @return boolean True when an entry with that title exists.
	local function has_title(menu, title)
		for _, entry in ipairs(menu) do
			if type(entry) == "table" and entry.title == title then return true end
		end
		return false
	end

	helpers.it("build_menu does not throw when the frontmost app name contains '%'", function()
		local AppPicker = load_picker_with_front_app("100% Orange Juice")

		local menu
		local ok, err = pcall(function()
			menu = AppPicker.build_menu({}, function() end, "search")
		end)

		helpers.assert_true(ok, "build_menu must not raise on '%': " .. tostring(err))
		helpers.assert_nil(err, "and must report no error")
		helpers.assert_true(type(menu) == "table", "build_menu must return a menu table")
	end)

	helpers.it("the exclude entry keeps the literal '%' in the app name", function()
		local AppPicker = load_picker_with_front_app("100% Orange Juice")
		local menu = AppPicker.build_menu({}, function() end, "search")

		helpers.assert_true(has_title(menu, "Exclude 100% Orange Juice"),
			"the exclude entry must render the app name verbatim, '%' included")
	end)

	-- A name containing "%1" is the nastier variant: Lua reads it as a reference
	-- to capture 1, which does not exist in the "{app}" pattern, so it raises
	-- "invalid capture index" rather than "invalid use of '%'".
	helpers.it("an app name containing a capture-like '%1' is also safe", function()
		local AppPicker = load_picker_with_front_app("Save %1 Now")

		local menu
		local ok, err = pcall(function()
			menu = AppPicker.build_menu({}, function() end, "search")
		end)

		helpers.assert_true(ok,
			"build_menu must not raise on an app name containing '%1': " .. tostring(err))
		helpers.assert_true(has_title(menu, "Exclude Save %1 Now"),
			"a capture-like sequence in the app name must survive as literal text")
	end)

	helpers.it("an ordinary app name is unaffected by the escaping", function()
		local AppPicker = load_picker_with_front_app("Safari")
		local menu = AppPicker.build_menu({}, function() end, "search")

		helpers.assert_true(has_title(menu, "Exclude Safari"),
			"escaping must be a no-op for a name with no '%'")
	end)

end)
