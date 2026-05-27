--- tests/unit/lib/test_config_overrides.lua

--- ==============================================================================
--- MODULE: Config Overrides Unit Tests
--- DESCRIPTION:
--- Validates the user-config TOML overrides loader: type coercion, [script]
--- and [features] sections routing to hs.settings, and graceful no-op on
--- missing file.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Stub hs.settings with an in-memory store the tests can inspect. Captured
-- the canonical settings table first so we can restore it at the end of
-- this file — without that restore, the override leaks into every test
-- that runs afterwards (e.g. the backend_detector tests use hs.settings
-- via the canonical stub and would observe values written by these tests).
local stored = {}
_G.hs = _G.hs or {}
local _ORIGINAL_SETTINGS = _G.hs.settings
_G.hs.settings = {
	set = function(key, value) stored[key] = value end,
	get = function(key) return stored[key] end,
}

local Overrides = helpers.load_with_stubs("lib.config_overrides")
-- helpers.load_with_stubs may have re-pointed _G.hs to a fresh stub via
-- __reset; re-apply the override so the describes below still observe it.
_G.hs.settings = {
	set = function(key, value) stored[key] = value end,
	get = function(key) return stored[key] end,
}

helpers.describe("config_overrides.coerce", function()
	helpers.it("coerces true/false to booleans", function()
		helpers.assert_eq(Overrides.coerce("true"),  true)
		helpers.assert_eq(Overrides.coerce("false"), false)
		helpers.assert_eq(Overrides.coerce("  TRUE "), true)
	end)

	helpers.it("coerces integers and floats to numbers", function()
		helpers.assert_eq(Overrides.coerce("42"),    42)
		helpers.assert_eq(Overrides.coerce("-7"),    -7)
		helpers.assert_eq(Overrides.coerce("3.14"),  3.14)
	end)

	helpers.it("unquotes and unescapes string literals", function()
		helpers.assert_eq(Overrides.coerce('"hello"'),  "hello")
		helpers.assert_eq(Overrides.coerce('"a\\nb"'),  "a\nb")
		helpers.assert_eq(Overrides.coerce('"a\\"b"'),  'a"b')
	end)

	helpers.it("returns the trimmed raw value when nothing matches", function()
		helpers.assert_eq(Overrides.coerce("  bare  "), "bare")
	end)
end)

helpers.describe("config_overrides.apply", function()
	-- Helper: write content to a tmp file, run apply, return tmp path
	local function with_tmp(content, fn)
		local path = os.tmpname()
		-- On macOS os.tmpname yields paths under /var/folders that are fine for io.open;
		-- on some Lua builds it returns a leading slash already, so use as-is.
		local fh = io.open(path, "w")
		fh:write(content); fh:close()
		fn(path)
		os.remove(path)
	end

	helpers.it("returns 0 on missing file without throwing", function()
		local applied = Overrides.apply("/tmp/definitely_not_a_real_file_xyz.toml")
		helpers.assert_eq(applied, 0)
	end)

	helpers.it("applies [script] section to hs.settings", function()
		stored = {}
		_G.hs.settings.set = function(k, v) stored[k] = v end
		with_tmp([[
[script]
LogLevel = "DEBUG"
]], function(path)
			local applied = Overrides.apply(path)
			helpers.assert_true(applied >= 1)
			helpers.assert_eq(stored["LogLevel"], "DEBUG")
		end)
	end)

	helpers.it("applies [features] section with dotted keys", function()
		stored = {}
		_G.hs.settings.set = function(k, v) stored[k] = v end
		with_tmp([[
[features]
"MagicKey.Repeat.Enabled" = false
"Personal.Code.Enabled" = true
]], function(path)
			local applied = Overrides.apply(path)
			helpers.assert_eq(applied, 2)
			helpers.assert_eq(stored["MagicKey.Repeat.Enabled"], false)
			helpers.assert_eq(stored["Personal.Code.Enabled"],  true)
		end)
	end)

	helpers.it("ignores unknown sections silently", function()
		stored = {}
		_G.hs.settings.set = function(k, v) stored[k] = v end
		with_tmp([[
[unknown]
foo = "bar"

[script]
KeptKey = 1
]], function(path)
			local applied = Overrides.apply(path)
			helpers.assert_eq(applied, 1)
			helpers.assert_eq(stored["KeptKey"], 1)
			helpers.assert_eq(stored["foo"], nil)
		end)
	end)
end)


-- Restore the canonical hs.settings so subsequent tests do not see the
-- override above (it would leak the per-test `stored` table and mask
-- __reset() in tests like backend_detector that rely on the canonical
-- SETTINGS_STORE).
if _ORIGINAL_SETTINGS then
	_G.hs.settings = _ORIGINAL_SETTINGS
end
