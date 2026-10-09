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

--- The old assertions intentionally retain key-echo captions for unformatted rows.
--- Supply only genuine Layout format strings that the complete caption API now reads.
--- This is fixture input, never an expectation regenerated from the native producer.
local function install_legacy_layout_formats(translator)
	translator = translator or require("infra.i18n")
	local file = assert(io.open(helpers.shared("data/locales/en.json"), "rb"))
	local catalogue = assert(require("json").decode(file:read("*a")))
	assert(file:close())
	local original_get = translator.get
	translator.get = function(key)
		local format = catalogue[key]
		if type(key) == "string" and key:sub(1, #"menu.layout.") == "menu.layout."
			and type(format) == "string" and format:find("%s", 1, true) then return format end
		return original_get(key)
	end
end

local LABELS = {
	["menu.layout.pause_picker_caption"] = "  ↳ pause : %s",
	["menu.layout.resume_picker_caption"] = "  ↳ resume : %s",
	["menu.layout.native_variant_caption"] = "%s v%s",
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
		package.loaded["infra.i18n"].section = function(key) return LABELS[key] or key end
		package.loaded["infra.notifications"] = { notify = function() end }
		install.bundle_variants = function()
			return { { name = "Ergopti_v2_2_2_plus", tis_id = "com.apple.keyboardlayout.ergopti.plus",
				keylayout = "/b/Ergopti_v2_2_2_plus.keylayout" } }
		end
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
		-- Status captions stay owned by the actual canonical declaration/renderer.
		package.loaded["infra.manifest_menu"] = nil
		local actual_manifest = require("infra.manifest_menu")
		package.loaded["infra.manifest_menu"] = {
			status_rows = actual_manifest.status_rows,
			template_rows = actual_manifest.template_rows,
			group_row = actual_manifest.group_row,
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


--- Exercises the real list provider, declaration and native row renderer.
--- Filesystem/TIS mutation ports remain controlled and must not run during builds.
local function with_no_bundle_status(body, labels)
	helpers.with_stub_scope({"modules.keymap.input_sources", "modules.keymap.layout_install",
		"ui.menu.menu_keyboard_layout", "infra.manifest_menu", "infra.i18n", "infra.notifications"}, function()
		local sources = helpers.load_with_stubs("modules.keymap.input_sources")
		local installer = require("modules.keymap.layout_install")
		local session = {latest = nil, effects = 0}
		installer.pick_latest_bundle = function() return session.latest end
		installer.highest_installed = function() return nil end
		installer.bundle_variants = function() return {} end
		sources.list_active_keyboard_layouts = function() return {} end
		sources.build_kl_name_to_tis_id = function() return {} end
		sources.resolve_installed_ergopti_version = function() return nil end
		local function forbid_effect() session.effects = session.effects + 1; error("Status presentation must not mutate native layouts") end
		installer.install_user = forbid_effect
		installer.install_system = forbid_effect
		sources.upgrade_active_list_async = forbid_effect
		sources.set_input_source_async = forbid_effect
		package.loaded["infra.notifications"] = {notify = forbid_effect}
		local translator = require("infra.i18n")
		if labels then translator.get = function(key) return labels[key] or key end
		else install_legacy_layout_formats(translator) end
		package.loaded["infra.manifest_menu"] = nil
		local renderer = require("infra.manifest_menu")
		session.root = renderer.get_root()
		for _, row in ipairs(session.root.layout_menu) do
			if row.id == "layout_bundle" then session.owner = row end
		end
		helpers.assert_not_nil(session.owner, "the actual bundle list owner must exist")
		package.loaded["ui.menu.menu_keyboard_layout"] = nil
		local owner = require("ui.menu.menu_keyboard_layout")
		session.build = function()
			local item = owner.build({base_dir = "/no/shipped/bundle/", updateMenu = forbid_effect})
			return renderer.render_rows({item}, "top_level")[1].menu
		end
		session.translate = translator.get
		body(session)
		helpers.assert_eq(session.effects, 0, "inert status must never deliver native mutations")
	end)
end

local function find_bundle_status(rows, title)
	for index, row in ipairs(rows) do if row.title == title then return row, index end end
end

helpers.describe("canonical no-bundle status reaches the actual native layout menu", function()
	helpers.it("keeps the independent inert declaration and its native status position", function()
		with_no_bundle_status(function(session)
			helpers.assert_eq(session.owner.status_rows.no_bundle, {{type = "label", i18n = "menu.layout.no_bundle"}})
			helpers.assert_eq(session.owner.platforms, {"hs"})
			helpers.assert_eq(session.owner.reason_key, "platform_reason.layout_bundle_and_menubar_are_macos")
			local rows = session.build()
			local status, position = find_bundle_status(rows, "menu.layout.no_bundle")
			local unchanged, neighbor = find_bundle_status(rows, "menu.layout.install_first")
			helpers.assert_not_nil(status)
			helpers.assert_eq(status.disabled, true)
			helpers.assert_nil(status.fn)
			helpers.assert_nil(status.menu)
			helpers.assert_not_nil(unchanged)
			helpers.assert_eq(neighbor, position + 1, "the unchanged native bundle status follows the shared missing-bundle label")
		end)
	end)
	helpers.it("consumes a caption mutation through the real provider and renderer", function()
		with_no_bundle_status(function(session)
			local status = session.owner.status_rows.no_bundle[1]
			local previous = status.i18n
			status.i18n = "menu.about.check_for_updates"
			local ok, err = xpcall(function()
				local rows = session.build()
				helpers.assert_nil(find_bundle_status(rows, "menu.layout.no_bundle"))
				local row = find_bundle_status(rows, "menu.about.check_for_updates")
				helpers.assert_not_nil(row)
				helpers.assert_eq(row.disabled, true)
				helpers.assert_nil(row.fn)
			end, debug.traceback)
			status.i18n = previous
			if not ok then error(err, 0) end
		end)
	end)
	for _, refusal in ipairs({"missing", "obsolete", "effect"}) do
		helpers.it("refuses " .. refusal .. " status metadata while preserving native neighbors", function()
			with_no_bundle_status(function(session)
				local old = session.owner.status_rows
				local stale = {{type = "label", i18n = "menu.layout.no_bundle"}}
				if refusal == "missing" then session.owner.status_rows = nil
				elseif refusal == "obsolete" then session.owner.status_rows = {removed_no_bundle = stale}
				else stale[1].action = function() error("Metadata must never acquire a native action") end; session.owner.status_rows = {no_bundle = stale} end
				local ok, err = xpcall(function()
					local rows = session.build()
					helpers.assert_nil(find_bundle_status(rows, "menu.layout.no_bundle"))
					helpers.assert_not_nil(find_bundle_status(rows, "menu.layout.install_first"))
					helpers.assert_not_nil(find_bundle_status(rows, "menu.layout.manage"))
				end, debug.traceback)
				session.owner.status_rows = old
				if not ok then error(err, 0) end
			end)
		end)
	end
	helpers.it("honors the actual list owner's platform visibility", function()
		with_no_bundle_status(function(session)
			local previous = session.owner.platforms
			session.owner.platforms = {"linux"}
			local ok, err = xpcall(function()
				local rows = session.build()
				helpers.assert_nil(find_bundle_status(rows, "menu.layout.no_bundle"))
				helpers.assert_not_nil(find_bundle_status(rows, "menu.layout.manage"))
			end, debug.traceback)
			session.owner.platforms = previous
			if not ok then error(err, 0) end
		end)
	end)
	helpers.it("reads current bundle discovery on every actual provider build", function()
		with_no_bundle_status(function(session)
			local held = find_bundle_status(session.build(), "menu.layout.no_bundle")
			helpers.assert_not_nil(held)
			session.latest = "Ergopti_v2.2.2.bundle"
			helpers.assert_nil(find_bundle_status(session.build(), "menu.layout.no_bundle"))
			helpers.assert_nil(held.fn, "a held inert status never becomes an install action")
			session.latest = nil
			local fresh = find_bundle_status(session.build(), "menu.layout.no_bundle")
			helpers.assert_not_nil(fresh)
			helpers.assert_true(fresh ~= held)
		end)
	end)
	helpers.it("uses each of the 21 existing real catalogue captions", function()
		local codec = require("adapters.json_codec")
		local file = assert(io.open(helpers.shared("data/locale_order.json"), "rb"))
		local locales = assert(codec.decode(file:read("*a"))).order; assert(file:close())
		helpers.assert_eq(#locales, 21)
		for _, locale in ipairs(locales) do
			file = assert(io.open(helpers.shared("data/locales/" .. locale .. ".json"), "rb"))
			local labels = assert(codec.decode(file:read("*a"))); assert(file:close())
			helpers.assert_true(type(labels["menu.layout.no_bundle"]) == "string" and labels["menu.layout.no_bundle"] ~= "")
			with_no_bundle_status(function(session)
				local row = find_bundle_status(session.build(), labels["menu.layout.no_bundle"])
				helpers.assert_not_nil(row, "actual native provider caption: " .. locale)
				helpers.assert_eq(row.disabled, true)
				helpers.assert_nil(row.fn)
			end, labels)
		end
	end)
end)
