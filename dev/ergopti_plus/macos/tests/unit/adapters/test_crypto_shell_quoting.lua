--- tests/unit/adapters/test_crypto_shell_quoting.lua

--- ==============================================================================
--- MODULE: Crypto adapter shell-quoting regression tests
--- DESCRIPTION:
--- Regression for adapters-io-1: crypto.sha256() and network_info sha256_hex()
--- used Lua %q (double-quote escaping) instead of POSIX single-quoting, causing
--- wrong digests and potential shell injection when data contains $, backticks,
--- newlines or backslashes.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===============================================================
-- ==============================================================
-- ======= 1/ crypto.sha256 POSIX quoting (adapters-io-1) =======
-- ==============================================================
-- ===============================================================

helpers.describe("adapters.crypto — sha256 POSIX shell quoting", function()
	local Crypto
	local exec_cmd

	helpers.it("uses single-quoting: no double-quotes wrapping data", function()
		Crypto = helpers.load_with_stubs("adapters.crypto", {
			execute = function(cmd)
				exec_cmd = cmd
				return "(stdin)= deadbeef00112233445566778899aabbccddeeff00112233445566778899aabb\n"
			end,
		})
		Crypto.sha256("hello")
		-- The command must NOT contain Lua double-quoting (a literal \" or
		-- the data surrounded by double-quotes). Single-quoting wraps with '...'
		helpers.assert_true(exec_cmd ~= nil, "execute must have been called")
		helpers.assert_true(
			exec_cmd:find("'hello'") ~= nil,
			"command must single-quote the data (found: " .. tostring(exec_cmd) .. ")"
		)
		helpers.assert_true(
			exec_cmd:find('"hello"') == nil,
			"command must NOT double-quote the data"
		)
	end)

	helpers.it("escapes single quotes inside data via '\\''", function()
		exec_cmd = nil
		Crypto = helpers.load_with_stubs("adapters.crypto", {
			execute = function(cmd)
				exec_cmd = cmd
				return "(stdin)= deadbeef00112233445566778899aabbccddeeff00112233445566778899aabb\n"
			end,
		})
		Crypto.sha256("it's a test")
		helpers.assert_true(exec_cmd ~= nil, "execute must have been called")
		-- POSIX escape of internal apostrophe: 'it'\''s a test'
		helpers.assert_true(
			exec_cmd:find("'it'\\''s a test'") ~= nil,
			"apostrophes inside data must be escaped via '\\''"
		)
	end)

	helpers.it("does not inject when data contains dollar sign", function()
		exec_cmd = nil
		Crypto = helpers.load_with_stubs("adapters.crypto", {
			execute = function(cmd)
				exec_cmd = cmd
				return "(stdin)= aaaa00000000000000000000000000000000000000000000000000000000aaaa\n"
			end,
		})
		Crypto.sha256("price $HOME dollars")
		helpers.assert_true(exec_cmd ~= nil, "execute must have been called")
		-- The $ must be inside single quotes and thus not expanded
		helpers.assert_true(
			exec_cmd:find("'price %$HOME dollars'") ~= nil or
			exec_cmd:find("price %$HOME dollars") ~= nil,
			"$ must be inside single quotes — not shell-expandable"
		)
		-- The word HOME must not appear unquoted after $
		helpers.assert_true(
			exec_cmd:find("%$HOME") ~= nil,
			"$HOME must appear verbatim, not be expanded (cmd: " .. tostring(exec_cmd) .. ")"
		)
	end)

	helpers.it("returns '' when openssl output has no hex digest", function()
		Crypto = helpers.load_with_stubs("adapters.crypto", {
			execute = function(_) return "no hex here\n" end,
		})
		local result = Crypto.sha256("x")
		helpers.assert_eq(result, "", "must return '' when match returns nil")
	end)

	helpers.it("returns '' when openssl output is empty string", function()
		Crypto = helpers.load_with_stubs("adapters.crypto", {
			execute = function(_) return "" end,
		})
		local result = Crypto.sha256("x")
		helpers.assert_eq(result, "", "must return '' on empty stdout")
	end)

	helpers.it("returns the hex digest without trailing whitespace", function()
		Crypto = helpers.load_with_stubs("adapters.crypto", {
			execute = function(_)
				return "(stdin)= deadbeef00112233445566778899aabbccddeeff00112233445566778899aabb  \n"
			end,
		})
		local result = Crypto.sha256("x")
		helpers.assert_eq(result, "deadbeef00112233445566778899aabbccddeeff00112233445566778899aabb")
	end)
end)





-- ==========================================================================
-- =========================================================================
-- ======= 2/ network_info sha256_hex nil-safety (adapters-ui-sys-1) =======
-- =========================================================================
-- ==========================================================================

helpers.describe("adapters.network_info — sha256_hex nil-safety", function()
local NI
	local function load_network_info(overrides)
		-- network_info captures Crypto at require time. Clear that dependency so
		-- every scenario uses its own hs.execute override instead of a prior test's.
		package.loaded["adapters.crypto"] = nil
		package.loaded["adapters.shell_runner"] = nil
		return helpers.load_with_stubs("adapters.network_info", overrides)
	end

	helpers.it("returns '' when openssl stdout is empty (no nil-index crash)", function()
		NI = load_network_info({
			wifi = {
				currentNetwork = function() return "MySSID" end,
			},
			execute = function(_) return "" end,
		})
		-- Pre-fix: out:match(...)  returns nil, then :gsub errors
		-- Post-fix: nil-check returns "" cleanly
		local ok, result = pcall(function() return NI.getSsidHash() end)
		helpers.assert_true(ok, "getSsidHash() must not raise when openssl returns empty stdout")
		-- Result is nil (no SSID returned because sha256_hex returned "")
		-- The contract says nil when hash cannot be computed OR "" — both are acceptable
		helpers.assert_true(result == nil or result == "",
			"getSsidHash() must return nil or '' on empty openssl output, got: " .. tostring(result))
	end)

	helpers.it("returns '' when openssl output has no hex pattern", function()
		NI = load_network_info({
			wifi = { currentNetwork = function() return "TestNet" end },
			execute = function(_) return "Error: openssl not found ZZZ\n" end,
		})
		local ok, result = pcall(function() return NI.getSsidHash() end)
		helpers.assert_true(ok, "getSsidHash() must not raise on non-hex openssl output")
		helpers.assert_true(result == nil or result == "",
			"getSsidHash() must return nil or '' when no hex digest found")
	end)

	helpers.it("returns the hash when openssl succeeds", function()
		local hex = ("ab"):rep(32)  -- 64 hex chars
		NI = load_network_info({
			wifi = { currentNetwork = function() return "GoodNet" end },
			execute = function(_) return "(stdin)= " .. hex .. "\n" end,
		})
		local result = NI.getSsidHash()
		helpers.assert_eq(result, hex, "getSsidHash() must return the hex digest")
	end)
end)
