--- tests/unit/modules/keymap/layout/test_layout_install_source_paths.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Source Path Regression
--- DESCRIPTION:
--- Layout installation starts by discovering the latest bundled version. The
--- real directory scan must preserve literal source paths, including apostrophes
--- in a user's app or checkout folder, rather than treating them as shell source.
--- These cases use real files and the host shell so a permissive popen stub
--- cannot hide a broken command (layout-source-literal-paths).
--- ==============================================================================

local helpers = require("tests.helpers")
local text_utils = require("infra.text_utils")

--- Quotes one owned fixture path for the host shell.
--- @param path string
--- @return string
local function quote_path(path)
	if package.config:sub(1, 1) == "\\" then
		return '"' .. path:gsub("/", "\\") .. '"'
	end
	return text_utils.shell_quote(path)
end

--- Creates and always removes a real bundle source tree.
--- @param folder_name string Literal source folder basename.
--- @param callback function Receives the source folder.
local function with_bundle_source(folder_name, callback)
	local reserved = os.tmpname()
	os.remove(reserved)
	local root = reserved .. "-layout-source"
	local source = root .. "/" .. folder_name
	local windows = package.config:sub(1, 1) == "\\"
	local function mkdir(path)
		local command = (windows and "cmd /c mkdir " or "mkdir -p ") .. quote_path(path)
		local created = os.execute(command)
		helpers.assert_eq(created, true, "the real source fixture directory must be created")
	end
	local ok, err = xpcall(function()
		for _, name in ipairs({ "Ergopti_v2.2.1.bundle", "Ergopti_v2.2.2.bundle" }) do
			mkdir(source .. "/" .. name .. "/Contents")
			local file = assert(io.open(source .. "/" .. name .. "/Contents/Info.plist", "wb"))
			assert(file:write("<plist><dict/></plist>"))
			assert(file:close())
		end
		callback(source)
	end, debug.traceback)
	local removed = os.execute((windows and "cmd /c rmdir /s /q " or "rm -rf ") .. quote_path(root))
	if not ok then error(err, 0) end
	helpers.assert_eq(removed, true, "the owned bundle source tree must be removed")
end

helpers.describe("layout install: literal source directory", function()
	for _, folder_name in ipairs({
		"Ergopti plus é",
		"Adrien's Érgopti",
		"literal ' $HOME `echo unexpected`",
	}) do
		helpers.it("discovers versions in " .. folder_name .. " (layout-source-literal-paths)", function()
			with_bundle_source(folder_name, function(source)
				local install = helpers.load_with_stubs("modules.keymap.layout_install")
				helpers.assert_eq(install.pick_latest_bundle(source), "Ergopti_v2.2.2.bundle",
					"a literal source path must retain the latest bundle offered for installation")
				local installed = install.highest_installed(source)
				helpers.assert_true(installed ~= nil, "the same real bundles must remain discoverable as installed")
				helpers.assert_eq(installed.name, "Ergopti_v2.2.2.bundle")
			end)
		end)
	end
end)
