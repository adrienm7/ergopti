--- tests/unit/ui/test_wpm_darken_hex_malformed_input.lua

--- ==============================================================================
--- MODULE: Regression — _wpm_darken_hex guards malformed hex input (F-MED-25)
--- DESCRIPTION:
--- _wpm_darken_hex(hex, factor) did unguarded hex-to-number arithmetic on `hex`,
--- which ultimately traces back to a hotstring group's TOML _meta.color — a
--- value the user can freely edit (ui/wpm/shared.lua resolve_source_hex merges
--- the TOML default with any user override, with no format validation). A
--- shorthand "#fff", a bare color name, or plain garbage reaches
--- tonumber(h:sub(1, 2), 16) and friends: a too-short string yields nil
--- sub-strings, and `nil * factor` raises inside the widget's redraw path.
---
--- Its sibling _wpm_normalise_hex (a few lines above in the same file) already
--- guards this exact case with a `#h ~= 6` length check before doing any
--- arithmetic. Fix: apply the same guard to _wpm_darken_hex and give it a
--- fallback_hex parameter so a malformed color degrades to a sane default
--- strip color instead of crashing the 0.2 s widget redraw timer.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("wpm_widget: _wpm_darken_hex survives malformed hex input (F-MED-25)", function()
	-- _wpm_darken_hex is a module-local, not part of the public M table. Read
	-- the source and eval just that function in isolation so the test exercises
	-- the exact production implementation without needing to expose it.
	local function extract_darken_hex_fn()
		-- Selected by a declaration unique to ui/wpm/wpm_widget.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function resolve_shared_constants_path")
		helpers.assert_true(src ~= nil, "ui/wpm/wpm_widget.lua source must be locatable")

		local body = src:match("(local function _wpm_darken_hex.-\nend)")
		helpers.assert_true(body ~= nil, "could not locate _wpm_darken_hex body in wpm_widget.lua")

		local chunk = load(body .. "\nreturn _wpm_darken_hex")
		helpers.assert_true(chunk ~= nil, "_wpm_darken_hex body failed to compile in isolation")
		return chunk()
	end

	helpers.it("_wpm_darken_hex is source-guarded against non-6-char hex bodies", function()
		local darken = extract_darken_hex_fn()

		local ok1, result1 = pcall(darken, "#fff", 0.5, "#112233")
		helpers.assert_true(ok1, "_wpm_darken_hex must not raise on a shorthand #fff input")
		helpers.assert_eq(result1, "#112233", "shorthand #fff must fall back to fallback_hex")

		local ok2, result2 = pcall(darken, "red", 0.5, "#112233")
		helpers.assert_true(ok2, "_wpm_darken_hex must not raise on a bare color-name input")
		helpers.assert_eq(result2, "#112233", "a bare color name must fall back to fallback_hex")

		local ok3, result3 = pcall(darken, nil, 0.5, "#112233")
		helpers.assert_true(ok3, "_wpm_darken_hex must not raise on a nil hex input")
		helpers.assert_eq(result3, "#112233", "a nil hex must fall back to fallback_hex")
	end)

	helpers.it("_wpm_darken_hex still darkens a well-formed hex input", function()
		local darken = extract_darken_hex_fn()

		local ok, result = pcall(darken, "#8040c0", 0.5, "#000000")
		helpers.assert_true(ok, "_wpm_darken_hex must not raise on well-formed input")
		helpers.assert_eq(result, "#402060", "a well-formed hex must be darkened, not routed to the fallback")
	end)
end)

helpers.describe("wpm_widget: _wpm_darken_hex source mirrors the _wpm_normalise_hex guard (F-MED-25)", function()
	local function read_src()
		-- Selected by a declaration unique to ui/wpm/wpm_widget.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function resolve_shared_constants_path")
		helpers.assert_true(src ~= nil, "ui/wpm/wpm_widget.lua source must be locatable")
		return src
	end

	helpers.it("_wpm_darken_hex checks #h ~= 6 before doing hex arithmetic", function()
		local src = read_src()
		local darken_body = src:match("(local function _wpm_darken_hex.-\nend)")
		helpers.assert_true(darken_body ~= nil, "could not locate _wpm_darken_hex in wpm_widget.lua")
		helpers.assert_true(darken_body:find("#h ~= 6", 1, true) ~= nil,
			"_wpm_darken_hex must guard non-6-char hex bodies, mirroring _wpm_normalise_hex")
	end)

	helpers.it("the call site passes a fallback_hex argument", function()
		local src = read_src()
		helpers.assert_true(src:find("_wpm_darken_hex(bg_hex, CONFIG.compact_unit_darken, CONFIG.color_bg_manual)", 1, true) ~= nil,
			"the compact-mode call site must pass a fallback_hex so a malformed TOML color degrades safely")
	end)
end)
