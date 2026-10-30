--- tests/unit/infra/test_posix_backslash_source_paths.lua

--- ==============================================================================
--- MODULE: A Backslash Is A Filename Byte On macOS (posix-backslash-paths)
--- DESCRIPTION:
--- Three macOS modules located their own install from their source path and
--- first rewrote every backslash as a slash, a Windows habit: on macOS a
--- backslash is an ordinary filename byte, so a checkout under "a\b" was read
--- as "a/b". network_env then could not find the shared network policy and
--- every managed download refused to start; the MLX download named a missing
--- Python import directory; the webview locale base URL named another folder.
---
--- The 28 October Linux pass proved it for network_env. The fix splits on the
--- host's separators (native_path), and the URL base is percent-encoded.
--- ==============================================================================

local helpers = require("tests.helpers")
local describe, it = helpers.describe, helpers.it
local assert_true, assert_eq = helpers.assert_true, helpers.assert_eq

local FIXTURE_ROOT = "/fixture\\with backslash"

--- Loads the real network_env source as if it lived under a fixture root.
--- @return table module, table probed paths
local function network_env_under(root)
	local path = assert(package.searchpath("modules.llm.network_env", package.path))
	local file = assert(io.open(path, "rb"))
	local source = file:read("*a")
	file:close()
	local probed = {}
	local real_fs = require("adapters.file_system")
	local fs = setmetatable({ exists = function(candidate)
		probed[#probed + 1] = candidate
		return true
	end }, { __index = real_fs })
	return helpers.with_fresh_modules({ "adapters.file_system" }, function()
		package.loaded["adapters.file_system"] = fs
		-- Same relative layout as the real file, under the fixture root.
		local real_root = assert(path:match("^(.*)/modules/llm/[^/]+$"))
		local chunk = assert(load(source, "@" .. root .. path:sub(#real_root + 1)))
		return chunk(), probed
	end)
end

describe("macOS source-located paths keep their backslashes (posix-backslash-paths)", function()
	it("network_env finds the shared policy under a root holding a backslash", function()
		local network_env, probed = network_env_under(FIXTURE_ROOT)
		assert_eq(network_env.policy_path(), FIXTURE_ROOT .. "/modules/llm/network-retry.sh",
			"the policy is located under the real root, not under a rewritten one")
		assert_eq(probed[1], FIXTURE_ROOT .. "/modules/llm/network-retry.sh", "the probe asked about the real path")
	end)

	it("the webview locale base percent-encodes a backslash and a quote", function()
		local dir = helpers.temp_dir() .. "/backslash-page/"
		os.execute("mkdir -p '" .. dir .. "'")
		local page = assert(io.open(dir .. "index.html", "wb"))
		page:write("<html><head></head><body></body></html>")
		page:close()
		local html = helpers.with_fresh_modules({ "ui.ui_builder", "infra.paths", "infra.locale", "infra.i18n" }, function()
			package.loaded["infra.paths"] = setmetatable({
				shared = function(rel) return '/x\\y "z"/_shared/' .. rel end,
			}, { __index = require("infra.paths") })
			package.loaded["infra.locale"] = { catalogue = function() return { probe = "P" } end }
			package.loaded["infra.i18n"] = { get_locale = function() return "fr" end }
			return require("ui.ui_builder").build_injected_html(dir, "index.html")
		end)
		os.execute("rm -rf '" .. dir .. "'")
		local base = html:match('window.__i18n_base="([^"]*)"')
		assert_eq(base, "file:///x%5Cy%20%22z%22/_shared/data/locales/",
			"the backslash stays one filename byte and the quote cannot end the boot string")
	end)

	it("no macOS production file rewrites every backslash into a slash", function()
		local offenders = {}
		local root = helpers.driver_root()
		local pipe = assert(io.popen("cd '" .. root .. "' && find modules adapters infra ui platform init.lua"
			.. " -name '*.lua' -type f 2>/dev/null"))
		local scanned = 0
		for relative in pipe:lines() do
			local file = assert(io.open(root .. relative, "rb"))
			local source = file:read("*a")
			file:close()
			scanned = scanned + 1
			for line in source:gmatch("[^\n]+") do
				-- A rewrite guarded by the host separator check models a Windows host.
				if not line:match("^%s*%-%-") and not line:find("NativePath.separators()", 1, true) and (line:find('gsub("\\\\", "/")', 1, true)
					or line:find("gsub('\\\\', '/')", 1, true)) then
					offenders[#offenders + 1] = relative .. ": " .. line
				end
			end
		end
		pipe:close()
		assert_true(scanned > 100, "the scan must reach the driver tree, saw " .. scanned)
		assert_eq(#offenders, 0, "split on native_path separators instead:\n" .. table.concat(offenders, "\n"))
	end)
end)
