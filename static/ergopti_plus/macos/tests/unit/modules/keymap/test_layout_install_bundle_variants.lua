--- tests/unit/modules/keymap/test_layout_install_bundle_variants.lua

--- ==============================================================================
--- MODULE: Layouts Declared by an Installed Bundle
--- DESCRIPTION:
--- The input-source rows of a keyboard-layout bundle come from the bundle's
--- own Info.plist, not from a table of Ergopti variants written in the driver
--- (layout-bundle-variants). These tests read the real Ergopti bundle the app
--- ships, then a bundle that declares a layout it does not ship, and one with
--- no Info.plist at all.
--- ==============================================================================

local helpers = require("tests.helpers")

local BUNDLE = helpers.driver_root() .. "/../../ergopti/macos/bundles/Ergopti_v2.2.2.bundle"

--- Writes one file, creating nothing but the file.
--- @param path string
--- @param text string
local function write(path, text)
	local handle = assert(io.open(path, "wb"))
	handle:write(text)
	handle:close()
end

--- Creates a scratch bundle holding the given files.
--- @param files table Relative path -> content.
--- @return string bundle_path
local function scratch_bundle(files)
	local root = helpers.temp_dir() .. "/ergopti_bundle_" .. tostring(os.time()) .. "_" .. tostring(math.random(1e6))
		.. ".bundle"
	for _, dir in ipairs({ root, root .. "/Contents", root .. "/Contents/Resources" }) do
		local separator = package.config:sub(1, 1)
		local command = separator == "\\" and ('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
			or ("mkdir -p '" .. dir .. "'")
		os.execute(command)
	end
	for rel, text in pairs(files) do write(root .. "/" .. rel, text) end
	return root
end

helpers.describe("layout install: the layouts an installed bundle declares", function()
	helpers.it("reads each layout and its input-source id from the Info.plist (layout-bundle-variants)", function()
		local install = helpers.load_with_stubs("modules.keymap.layout_install")
		local variants = install.bundle_variants(BUNDLE)
		helpers.assert_eq(#variants, 4, "the Ergopti bundle declares four layouts")
		local ids = {}
		for _, variant in ipairs(variants) do
			ids[variant.name] = variant.tis_id
			helpers.assert_eq(variant.keylayout, BUNDLE .. "/Contents/Resources/" .. variant.name .. ".keylayout")
		end
		helpers.assert_eq(ids.Ergopti_v2_2_2, "com.apple.keyboardlayout.ergopti")
		helpers.assert_eq(ids.Ergopti_v2_2_2_ansi, "com.apple.keyboardlayout.ergopti.ansi")
		helpers.assert_eq(ids.Ergopti_v2_2_2_plus, "com.apple.keyboardlayout.ergopti.plus")
		helpers.assert_eq(ids.Ergopti_v2_2_2_plus_ansi, "com.apple.keyboardlayout.ergopti.plus.ansi")
		helpers.assert_eq(variants[1].name, "Ergopti_v2_2_2", "the Info.plist order is kept")
	end)

	helpers.it("skips a declared layout the bundle does not ship (layout-bundle-variants)", function()
		local install = helpers.load_with_stubs("modules.keymap.layout_install")
		local plist = table.concat({
			"<plist version=\"1.0\"><dict>",
			"<key>KLInfo_Shipped</key><dict><key>TISInputSourceID</key><string>org.example.shipped</string></dict>",
			"<key>KLInfo_Missing</key><dict><key>TISInputSourceID</key><string>org.example.missing</string></dict>",
			"<key>KLInfo_../escape</key><dict><key>TISInputSourceID</key><string>org.example.escape</string></dict>",
			"</dict></plist>",
		}, "\n")
		local bundle = scratch_bundle({
			["Contents/Info.plist"] = plist,
			["Contents/Resources/Shipped.keylayout"] = "<keyboard name=\"Shipped\"/>",
		})
		local variants = install.bundle_variants(bundle)
		helpers.assert_eq(#variants, 1)
		helpers.assert_eq(variants[1].name, "Shipped")
		helpers.assert_eq(variants[1].tis_id, "org.example.shipped")
	end)

	helpers.it("reads nothing from a bundle without an Info.plist (layout-bundle-variants)", function()
		local install = helpers.load_with_stubs("modules.keymap.layout_install")
		helpers.assert_eq(#install.bundle_variants(scratch_bundle({})), 0)
		helpers.assert_eq(#install.bundle_variants(""), 0)
	end)
end)
