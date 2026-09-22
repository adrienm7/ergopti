--- tests/unit/ui/menu/test_menu_keyboard_layout_list_versions.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Active-List Version Regression
--- DESCRIPTION:
--- The "upgrade active list" row printed "v? → v?" on the packaged app. The
--- target came from the latest bundle shipped with the driver, which the app
--- did not package, and the legacy version came only from a `_vX_Y_Z` suffix
--- that an unversioned KeyboardLayout Name lacks. The target is now the
--- installed bundle, the legacy version is traced to the bundle that ships the
--- keylayout and read from its Info.plist, and an unknown version is dropped
--- from the label instead of rendered as a placeholder.
--- ==============================================================================

local helpers = require("tests.helpers")

local LABELS = {
	["menu.layout.update_list"]               = "list v%s -> v%s",
	["menu.layout.update_list_to"]            = "list -> v%s",
	["menu.layout.update_list_install_first"] = "list to v%s (install v%s first)",
	["menu.layout.install_first"]             = "install first",
	["menu.layout.no_bundle"]                 = "no bundle",
	["menu.layout.installed_version"]         = "%s installed v%s",
	["menu.layout.update_version"]            = "%s update v%s to v%s",
	["menu.layout.install_version"]           = "%s install %s v%s",
}





-- ==========================================
-- ==========================================
-- ======= 1/ Menu Label Construction =======
-- ==========================================
-- ==========================================

--- Builds the bundle rows around one active legacy entry.
--- @param opts table { legacy = string, legacy_version = table|nil, latest = string|nil, installed = table|nil }
--- @return table labels Every rendered bundle-row label.
local function bundle_labels(opts)
	local labels = {}
	helpers.with_fresh_modules({
		"modules.keymap.input_sources",
		"modules.keymap.layout_install",
		"ui.menu.menu_keyboard_layout",
		"infra.manifest_menu",
		"infra.notifications",
		"infra.i18n",
	}, function()
		local input_sources = helpers.load_with_stubs("modules.keymap.input_sources")
		local install = require("modules.keymap.layout_install")
		package.loaded["infra.i18n"] = { get = function(key) return LABELS[key] or key end }
		package.loaded["infra.notifications"] = { notify = function() end }
		input_sources.ERGOPTI_VARIANTS = {
			{ id = "com.apple.keyboardlayout.ergopti.plus", label = "Ergopti+", suffix = "_plus" },
		}
		input_sources.list_active_keyboard_layouts = function()
			return { { id = opts.legacy, name = "g★", selected = true } }
		end
		input_sources.build_kl_name_to_tis_id = function() return {} end
		input_sources.resolve_installed_ergopti_version = function() return nil end
		install.pick_latest_bundle = function() return opts.latest end
		install.highest_installed = function(dir)
			if dir == install.SYSTEM_LAYOUTS_DIR then return opts.installed end
			return nil
		end
		install.layout_version = function(kl_name)
			helpers.assert_eq(kl_name, opts.legacy)
			return opts.legacy_version
		end
		package.loaded["infra.manifest_menu"] = {
			build = function(_menu_id, _label, _a, _b, _ctx, providers)
				return providers.layout_bundle()
			end,
		}
		package.loaded["ui.menu.menu_keyboard_layout"] = nil
		local built = require("ui.menu.menu_keyboard_layout").build({
			base_dir = "/tmp/ergopti/",
			updateMenu = function() end,
		})
		for _, row in ipairs(built.submenu) do labels[#labels + 1] = tostring(row.label) end
	end)
	for _, label in ipairs(labels) do
		helpers.assert_true(not label:find("v?", 1, true),
			"a version placeholder reached the menu: " .. label)
	end
	return labels
end

--- Asserts that `label` is one of `labels`.
--- @param labels table Rendered labels.
--- @param label string Expected label.
local function assert_has(labels, label)
	for _, seen in ipairs(labels) do
		if seen == label then return end
	end
	error("missing row '" .. label .. "' in: " .. table.concat(labels, " | "), 2)
end

local INSTALLED = { name = "Ergopti_v2.2.2.bundle", version = { 2, 2, 2 } }

helpers.describe("menu_keyboard_layout: active-list upgrade label versions", function()
	helpers.it("drops an unknown legacy version instead of printing v?", function()
		local labels = bundle_labels({
			legacy = "Ergopti_plus", legacy_version = nil,
			latest = "Ergopti_v2.2.2.bundle", installed = INSTALLED,
		})
		assert_has(labels, "list -> v2.2.2")
	end)

	helpers.it("shows the legacy version its bundle declares", function()
		local labels = bundle_labels({
			legacy = "Ergopti_plus", legacy_version = { 2, 1, 0 },
			latest = "Ergopti_v2.2.2.bundle", installed = INSTALLED,
		})
		assert_has(labels, "list v2.1.0 -> v2.2.2")
	end)

	helpers.it("targets the installed bundle when no bundle ships with the driver", function()
		local labels = bundle_labels({
			legacy = "Ergopti_plus", legacy_version = nil,
			latest = nil, installed = INSTALLED,
		})
		assert_has(labels, "no bundle")
		assert_has(labels, "list -> v2.2.2")
	end)

	helpers.it("offers no swap when neither a shipped nor an installed bundle exists", function()
		local labels = bundle_labels({
			legacy = "Ergopti_plus", legacy_version = nil,
			latest = nil, installed = nil,
		})
		assert_has(labels, "install first")
	end)

	helpers.it("asks to install the latest bundle, not the legacy version", function()
		local labels = bundle_labels({
			legacy = "Ergopti_plus", legacy_version = nil,
			latest = "Ergopti_v2.2.3.bundle", installed = INSTALLED,
		})
		assert_has(labels, "list to v2.2.3 (install v2.2.3 first)")
	end)
end)





-- ===============================================
-- ===============================================
-- ======= 2/ Legacy Layout Version Lookup =======
-- ===============================================
-- ===============================================

--- Loads layout_install with a fake keylayout listing and Info.plist store.
--- @param listing table Lines the `find` scan prints, per directory.
--- @param plists table Map { [Info.plist path] = content }.
--- @param callback function fn(install, reads) run with the fakes installed.
local function with_layout_fixture(listing, plists, callback)
	local saved_popen = io.popen
	local ok, err = xpcall(function()
		helpers.with_fresh_modules({
			"modules.keymap.layout_install",
			"adapters.file_system",
		}, function()
			local reads = {}
			package.loaded["adapters.file_system"] = {
				read_with_status = function(path)
					reads[#reads + 1] = path
					if plists[path] then return plists[path], "ok" end
					return nil, "absent", "no such file"
				end,
			}
			io.popen = function(command)
				local rows = {}
				for dir, lines in pairs(listing) do
					if command:find(dir, 1, true) then rows = lines end
				end
				local index = 0
				return {
					lines = function()
						return function()
							index = index + 1
							return rows[index]
						end
					end,
					close = function() return true end,
				}
			end
			local install = helpers.load_with_stubs("modules.keymap.layout_install")
			callback(install, reads)
		end)
	end, debug.traceback)
	io.popen = saved_popen
	if not ok then error(err, 0) end
end

local PLIST_210 = [[
<plist version="1.0"><dict>
	<key>CFBundleShortVersionString</key>
	<string>2.1.0</string>
</dict></plist>]]

helpers.describe("layout_install.layout_version", function()
	helpers.it("reads a versioned KeyboardLayout Name without touching the disk", function()
		with_layout_fixture({}, {}, function(install, reads)
			helpers.assert_eq(install.layout_version("Ergopti_v2_1_0_plus"), { 2, 1, 0 })
			helpers.assert_eq(#reads, 0)
		end)
	end)

	helpers.it("reads an unversioned layout's version from its bundle Info.plist", function()
		with_layout_fixture({
			["/Library/Keyboard Layouts"] = {
				"/Library/Keyboard Layouts/Ergopti.bundle/Contents/Resources/Ergopti_plus.keylayout",
			},
		}, {
			["/Library/Keyboard Layouts/Ergopti.bundle/Contents/Info.plist"] = PLIST_210,
		}, function(install)
			helpers.assert_eq(install.layout_version("Ergopti_plus"), { 2, 1, 0 })
		end)
	end)

	helpers.it("reports an unknown version when no installed bundle ships the layout", function()
		with_layout_fixture({}, {}, function(install)
			helpers.assert_nil(install.layout_version("Ergopti_plus"))
		end)
	end)

	helpers.it("reports an unknown version when the Info.plist declares none", function()
		with_layout_fixture({
			["/Library/Keyboard Layouts"] = {
				"/Library/Keyboard Layouts/Ergopti.bundle/Contents/Resources/Ergopti_plus.keylayout",
			},
		}, {
			["/Library/Keyboard Layouts/Ergopti.bundle/Contents/Info.plist"] = "<plist><dict></dict></plist>",
		}, function(install)
			helpers.assert_nil(install.layout_version("Ergopti_plus"))
		end)
	end)
end)
