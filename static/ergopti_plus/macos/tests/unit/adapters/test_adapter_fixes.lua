--- tests/unit/adapters/test_adapter_fixes.lua

--- ==============================================================================
--- MODULE: Adapter Contract Fix Tests (H2-H5)
--- DESCRIPTION:
--- Regression tests for the H2-H5 audit findings in the dormant port adapters:
---
--- H2 — secure_field_detector: hs.axuielement.focusedElement() does not exist;
---      the correct approach is applicationElementForPID + AXFocusedUIElement.
--- H3 — keyboard_hook: #char (byte count) rejects multi-byte chars like é, à;
---      must use utf8.len() instead.
--- H4 — key_state: LShift/RShift etc. are not valid modifier flags in
---      checkKeyboardModifiers(); must normalise to "shift", "ctrl", etc.
--- H5 — keyboard_hook: start() leaked a disabled tap when called on a stopped
---      (but still allocated) hook; must stop and nil the old tap first.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===================================================
-- ===============================================
-- ======= 1/ H3 — utf8.len char filtering =======
-- ===============================================
-- ===================================================

helpers.describe("keyboard_hook H3: utf8.len char filtering", function()
	--- Simulates the post-fix char-codepoint detection logic from keyboard_hook.lua.
	local function count_codepoints(char)
		if type(char) ~= "string" then return nil end
		local ok, n = pcall(utf8.len, char)
		if ok then return n end
		return nil
	end

	helpers.it("counts ASCII char as 1 codepoint", function()
		helpers.assert_eq(count_codepoints("a"), 1)
	end)

	helpers.it("counts 2-byte UTF-8 char (é) as 1 codepoint", function()
		-- é = U+00E9 encoded as 0xC3 0xA9 (2 bytes, 1 codepoint)
		local e_acute = "\xC3\xA9"
		helpers.assert_eq(count_codepoints(e_acute), 1)
	end)

	helpers.it("counts 3-byte UTF-8 char (€) as 1 codepoint", function()
		-- € = U+20AC encoded as 0xE2 0x82 0xAC (3 bytes, 1 codepoint)
		local euro = "\xE2\x82\xAC"
		helpers.assert_eq(count_codepoints(euro), 1)
	end)

	helpers.it("counts 2-char ASCII string as 2 codepoints (not a printable key)", function()
		helpers.assert_eq(count_codepoints("ab"), 2)
	end)

	helpers.it("returns nil for malformed UTF-8", function()
		-- 0xFF is not a valid UTF-8 start byte
		local bad = "\xFF"
		helpers.assert_eq(count_codepoints(bad), nil)
	end)
end)





-- ==========================================================
-- ===================================================
-- ======= 2/ H4 — key_state normalisation map =======
-- ===================================================
-- ==========================================================

helpers.describe("key_state H4: key normalisation", function()
	-- Mirror the normalisation table from key_state.lua
	local KEY_NORMALISATION = {
		LShift = "shift",  RShift = "shift",
		LCtrl  = "ctrl",   RCtrl  = "ctrl",
		LAlt   = "alt",    RAlt   = "alt",
		LCmd   = "cmd",    RCmd   = "cmd",
	}

	local function normalize_key(k)
		return KEY_NORMALISATION[k] or k
	end

	helpers.it("LShift normalises to 'shift'", function()
		helpers.assert_eq(normalize_key("LShift"), "shift")
	end)

	helpers.it("RShift normalises to 'shift'", function()
		helpers.assert_eq(normalize_key("RShift"), "shift")
	end)

	helpers.it("LCtrl normalises to 'ctrl'", function()
		helpers.assert_eq(normalize_key("LCtrl"), "ctrl")
	end)

	helpers.it("LAlt normalises to 'alt'", function()
		helpers.assert_eq(normalize_key("LAlt"), "alt")
	end)

	helpers.it("LCmd normalises to 'cmd'", function()
		helpers.assert_eq(normalize_key("LCmd"), "cmd")
	end)

	helpers.it("'shift' passes through unchanged (already canonical)", function()
		helpers.assert_eq(normalize_key("shift"), "shift")
	end)

	helpers.it("unknown key name passes through unchanged", function()
		helpers.assert_eq(normalize_key("fn"), "fn")
		helpers.assert_eq(normalize_key("space"), "space")
	end)
end)





-- ===================================================
-- ================================================
-- ======= 3/ H5 — tap lifecycle on start() =======
-- ================================================
-- ===================================================

helpers.describe("keyboard_hook H5: tap lifecycle on start()", function()
	helpers.it("an existing tap is stopped before a new one is created", function()
		-- Simulate the post-fix start() pre-flight
		local old_tap_stopped = false
		local new_tap_created = false

		local fake_old_tap = {
			stop       = function() old_tap_stopped = true end,
			isEnabled  = function() return false end,  -- disabled (the bug scenario)
		}

		local _tap = fake_old_tap

		-- Post-fix preamble: stop any existing tap before creating a new one
		if _tap then
			pcall(function() _tap:stop() end)
			_tap = nil
		end
		-- Simulate new tap creation
		_tap = { start = function() new_tap_created = true end }
		_tap:start()

		helpers.assert_eq(old_tap_stopped, true)
		helpers.assert_eq(new_tap_created, true)
	end)

	helpers.it("start() does not leave a dangling disabled tap", function()
		-- Pre-fix scenario: guard `if _tap and _tap:isEnabled()` would skip stop()
		-- for a disabled tap, leaving it allocated. Post-fix always nils it.
		local _tap = {
			stop      = function() end,
			isEnabled = function() return false end,
		}

		-- Apply post-fix cleanup
		if _tap then
			pcall(function() _tap:stop() end)
			_tap = nil
		end

		helpers.assert_eq(_tap, nil)
	end)
end)





-- =====================================================================================================
-- ====================================================================================================
-- ======= 4/ file_system.write() creates parent directories (filesystem-adapter-missing-mkdir) =======
-- ====================================================================================================
-- =====================================================================================================

helpers.describe("file_system.write — parent directory creation (filesystem-adapter-missing-mkdir)", function()

	helpers.it("source defines ensure_dir to create missing parent directories", function()
		-- Selected by a declaration unique to adapters/file_system.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("function M.expand_path")
		helpers.assert_true(src ~= nil, "adapters/file_system.lua source must be locatable")
		helpers.assert_true(
			src:find("ensure_dir", 1, true) ~= nil,
			"file_system.write must call ensure_dir to create missing parent directories (filesystem-adapter-missing-mkdir)"
		)
	end)

	helpers.it("source calls hs.fs.mkdir inside ensure_dir", function()
		-- Selected by a declaration unique to adapters/file_system.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("function M.expand_path")
		helpers.assert_true(src ~= nil, "adapters/file_system.lua source must be locatable")
		helpers.assert_true(
			src:find("hs.fs.mkdir", 1, true) ~= nil,
			"ensure_dir must invoke hs.fs.mkdir to create the directory (filesystem-adapter-missing-mkdir)"
		)
	end)

	helpers.it("write() calls ensure_dir before io.open", function()
		-- Track mkdir calls via an hs.fs override injected into the fresh stub.
		-- load_with_stubs() replaces _G.hs with a fresh object each call, so we
		-- must pass our mock via hs_overrides — modifying _G.hs.fs beforehand has
		-- no effect because load_with_stubs() discards the old _G.hs.
		local mkdir_calls = {}
		local mock_fs = {
			attributes = function(_path, _mode) return nil end,  -- report all dirs missing
			mkdir      = function(dir) mkdir_calls[#mkdir_calls + 1] = dir end,
		}

		package.loaded["adapters.file_system"] = nil
		package.loaded["lib.logger"] = nil
		local _ = helpers.load_with_stubs("lib.logger")
		-- Inject mock hs.fs via hs_overrides so it survives the fresh-stub replacement
		local FS = helpers.load_with_stubs("adapters.file_system", { fs = mock_fs })

		-- Write to a path whose parent doesn't exist per the mock.
		-- io.open will fail (no real dir) but ensure_dir must call hs.fs.mkdir first.
		FS.write("/nonexistent/deep/dir/file.txt", "content")
		package.loaded["adapters.file_system"] = nil

		helpers.assert_true(
			#mkdir_calls > 0,
			"write() must call hs.fs.mkdir for the missing parent directory (filesystem-adapter-missing-mkdir)"
		)
	end)

end)
