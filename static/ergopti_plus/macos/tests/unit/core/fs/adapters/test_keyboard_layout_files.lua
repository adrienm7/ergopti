--- tests/unit/core/fs/adapters/test_keyboard_layout_files.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Build Files
--- DESCRIPTION:
--- A number-row build is written as a new file with no lock file beside it, an
--- existing path is never overwritten, and only a regular file is removed
--- (layout-build-files).
--- ==============================================================================

local helpers = require("tests.helpers")
local Files = require("layouts.adapters.keyboard_layout_files")

--- The names in a folder.
local function listing(dir)
	local pipe = assert(io.popen("ls -A '" .. dir .. "'"))
	local names = {}
	for name in pipe:read("*a"):gmatch("[^\n]+") do names[#names + 1] = name end
	pipe:close()
	return names
end

helpers.describe("keyboard layout build files (layout-build-files)", function()
	helpers.it("refuses to remove a symlink to an existing file", function()
		local dir = os.tmpname()
		os.remove(dir)
		assert(os.execute("mkdir -p '" .. dir .. "'"))
		local path, target = dir .. "/Rows.keylayout", dir .. "/foreign"
		local file = assert(io.open(target, "wb")); assert(file:write("foreign")); assert(file:close())
		assert(os.execute("ln -s '" .. target .. "' '" .. path .. "'"))
		local removed = Files.remove(path)
		local link = io.open(path, "rb")
		if link then link:close() end
		os.remove(path); os.remove(target); os.remove(dir)
		helpers.assert_eq(removed, false)
		helpers.assert_true(link ~= nil, "the foreign link must remain present")
	end)

	helpers.it("refuses a dangling symlink without creating its target", function()
		local dir = os.tmpname()
		os.remove(dir)
		assert(os.execute("mkdir -p '" .. dir .. "'"))
		local path, target = dir .. "/Rows.keylayout", dir .. "/foreign"
		assert(os.execute("ln -s '" .. target .. "' '" .. path .. "'"))
		local written = Files.write_new(path, "<keyboard/>")
		local file = io.open(target, "rb")
		if file then file:close() end
		os.remove(path); os.remove(target); os.remove(dir)
		helpers.assert_eq(written, false)
		helpers.assert_eq(file, nil)
	end)

	helpers.it("writes a new build alone, refuses an existing one and removes it", function()
		local dir = os.tmpname()
		os.remove(dir)
		assert(os.execute("mkdir -p '" .. dir .. "'"))
		local path = dir .. "/ErgoptiRows-1.keylayout"
		helpers.assert_eq((Files.write_new(path, "<keyboard/>")), true)
		helpers.assert_eq(#listing(dir), 1, "a lock file was left beside the build")
		local again, reason = Files.write_new(path, "other")
		helpers.assert_eq(again, false)
		helpers.assert_contains(reason, "already exists")
		local handle = assert(io.open(path, "rb"))
		helpers.assert_eq(handle:read("*a"), "<keyboard/>")
		handle:close()
		helpers.assert_eq((Files.remove(path)), true)
		helpers.assert_eq(#listing(dir), 0)
		helpers.assert_eq((Files.remove(path)), true, "an absent build is already removed")
		helpers.assert_eq((Files.write_new(dir .. "/not-a-layout.txt", "x")), false)
		os.remove(dir)
	end)
end)
