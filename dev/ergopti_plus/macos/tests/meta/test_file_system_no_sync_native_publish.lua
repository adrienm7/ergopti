--- tests/meta/test_file_system_no_sync_native_publish.lua

--- ==============================================================================
--- MODULE: FileSystem Synchronous Native Publication Guard
--- DESCRIPTION:
--- Prevents configuration writers from reintroducing a spawned native helper
--- whose synchronous completion wait blocks the Hammerspoon VM. FileSystem is a
--- widely shared port, so such a wait can freeze unrelated user-action callbacks.
--- The supported contract is the in-process cooperative lock plus adjacent
--- staging and POSIX rename; non-cooperating writers remain outside its bound.
--- ==============================================================================

local helpers = require("tests.helpers")

local function strip_comments(source)
	return source:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\r\n]*", "")
end

helpers.describe("FileSystem publication stays in-process and nonblocking", function()
	helpers.it("contains no synchronous task/helper publication path", function()
		-- This declaration is unique to adapters/file_system.lua. Reading by symbol
		-- keeps the invariant valid if the adapter is moved or renamed.
		local source = helpers.read_driver_source(
			"local function write_atomic(path, content, expected_source)"
		)
		helpers.assert_type(source, "string", "the FileSystem implementation must be locatable")
		local code = strip_comments(source)
		helpers.assert_true(code:find("waitUntilExit", 1, true) == nil,
			"FileSystem writes must never synchronously wait for a child process")
		helpers.assert_true(code:find("TaskLifecycle", 1, true) == nil,
			"FileSystem writes must not launch a native task through TaskLifecycle")
		helpers.assert_true(source:find("file-compare-publish", 1, true) == nil,
			"the retired native compare/publish role must stay absent")
		helpers.assert_true(code:find("hs.task", 1, true) == nil,
			"the filesystem port must not spawn an Hammerspoon task directly")
		helpers.assert_true(code:find("os.rename(tmp_path, resolved_path)", 1, true) ~= nil,
			"atomic replacement must remain the in-process adjacent rename path")
	end)
end)

return true
