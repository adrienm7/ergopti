--- tests/unit/ai/engine/backends/test_token_and_install_quoting.lua

--- ==============================================================================
--- MODULE: Regression — token references remain immutable and shell quoting
---         (token-and-install-quoting)
--- DESCRIPTION:
--- Two findings that both turn a transient failure into a permanent one.
---
---   M8  A DENIED KEYCHAIN DESTROYED THE TOKEN. Cleartext was cached by
---       replacing the persisted reference on the live entry. The resolver now
---       keeps cleartext in a private cache and metadata entries stay immutable.
---
---   M3  THE PRIVILEGED INSTALL WAS NOT QUOTED. The shell-quoting campaign
---       routed 41 sites through text_utils.shell_quote, but install_system
---       kept raw %s inside hand-written single quotes and path_exists kept
---       Lua's %q. %q escapes for a LUA literal: it leaves $, backticks and !
---       untouched, every one of which /bin/sh expands. An apostrophe in a
---       relocated bundle path — or a user directory like /Users/O'Brien —
---       closed the quoted run early and broke a command run WITH ADMINISTRATOR
---       PRIVILEGES.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =========================================================================
-- =========================================================================
-- ======= 1/ A failed decrypt never replaces the stored reference =========
-- =========================================================================
-- =========================================================================

helpers.describe("api_remote: persisted token references are immutable", function()
	helpers.it("keeps cleartext in a private cache rather than the entry table", function()
		local src = helpers.read_driver_source("function M.resolve_active_entry")
		helpers.assert_true(src ~= nil and src ~= "",
			"api_remote must be locatable by its resolver")
		local uncommented = src:gsub("%-%-[^\n]*", "")
		helpers.assert_true(uncommented:find("local _token_cache", 1, true) ~= nil,
			"resolved cleartext must live outside persisted entry objects")
		helpers.assert_true(uncommented:find("entry%.token%s*=%s*[^=]") == nil,
			"no resolver or prewarm path may replace an entry's Keychain reference")
		helpers.assert_true(uncommented:find("TokenCrypto.decrypt(", 1, true) == nil,
			"the removed synchronous failure-sentinel path must stay absent")
	end)
end)




-- =========================================================================
-- =========================================================================
-- ======= 2/ Every shell interpolation is POSIX-quoted ====================
-- =========================================================================
-- =========================================================================

helpers.describe("layout_install: user installation is POSIX-quoted", function()
	helpers.it("install_user quotes every interpolated path", function()
		local saved_helper, saved_dir, saved_fs = package.loaded["platform.remap.lease_helper"],
			package.loaded["core.fs.engine.dir"], package.loaded["core.fs.adapters.file_system"]
		package.loaded["platform.remap.lease_helper"] = { resolve = function() return "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus" end }
		package.loaded["core.fs.engine.dir"] = { try_entries = function() return {}, true end }
		package.loaded["core.fs.adapters.file_system"] = { classify_no_follow = function() return { mode = "directory" }, "ok" end }
		local ok, err = xpcall(function()
			local dispatched
			local install = helpers.load_with_stubs("modules.keymap.layout_install", {
				execute = function(command) dispatched = command; return "", false end,
			})
			local text_utils = require("core.text.engine.utils")
			local source_dir, bundle_name = "/tmp/O'Brien/$cache/`layout`/", "Ergopti_v2.0.0.bundle"
			install.install_user(source_dir, bundle_name)
			helpers.assert_type(dispatched, "string")
			helpers.assert_true(dispatched:find("source=" .. text_utils.shell_quote(source_dir .. bundle_name) .. ";", 1, true) ~= nil)
			helpers.assert_true(dispatched:find("target=" .. text_utils.shell_quote(install.USER_LAYOUTS_DIR:gsub("/+$", "")) .. ";", 1, true) ~= nil)
		end, debug.traceback)
		package.loaded["platform.remap.lease_helper"], package.loaded["core.fs.engine.dir"], package.loaded["core.fs.adapters.file_system"] = saved_helper, saved_dir, saved_fs
		if not ok then error(err, 0) end
	end)

	helpers.it("path_exists does not shell out with %q", function()
		-- Resolve the translation unit by its unique install helper. A whole-tree
		-- search for `path_exists` also matches filesystem adapter helpers such as
		-- path_exists_no_follow, making this test inspect an unrelated function.
		local src = helpers.read_driver_unit("local function install_system")
		helpers.assert_true(src ~= nil and src ~= "",
			"layout_install must be locatable by its path_exists symbol")

		local at = src:find("local function path_exists", 1, true)
		helpers.assert_true(at ~= nil, "path_exists must exist")
		local body = src:sub(at, at + 900):gsub("%-%-[^\n]*", "")

		helpers.assert_true(body:find("%%q", 1, false) == nil,
			"path_exists must not quote a shell argument with Lua's %q. It escapes for a LUA "
				.. "literal and leaves $, backticks and ! untouched — all of which /bin/sh expands "
				.. "— so on a user-influenced path it is both wrong and an injection hazard")
		helpers.assert_true(body:find("shell_quote", 1, true) ~= nil,
			"it must use the POSIX quoter instead")
	end)
end)
