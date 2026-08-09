--- tests/meta/test_native_lease_cli_path_parity.lua

--- ==============================================================================
--- MODULE: Native Lease CLI Path Parity Guard
--- DESCRIPTION:
--- Keeps Lua's supported Karabiner CLI endpoint and the signed Swift guardian's
--- strict executable allowlist identical. A drift would leave every generated
--- rule inert or, if broadened, could admit a shared Karabiner process family.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ==========================================
-- ==========================================
-- ======= 1/ Cross-Language Contract =======
-- ==========================================
-- ==========================================

helpers.describe("native Karabiner lease uses the canonical CLI only", function()
	helpers.it("matches the Lua endpoint byte-for-byte", function()
		package.loaded["platform.remap.ke_paths"] = nil
		local paths = require("platform.remap.ke_paths")
		local worker_path = helpers.driver_root()
			.. "/launcher/Sources/ErgoptiPlus/KarabinerLeaseWorker.swift"
		local file, open_err = io.open(worker_path, "r")
		helpers.assert_not_nil(file,
			"the native lease worker must be readable: " .. tostring(open_err))
		local source = file:read("*a")
		file:close()

		helpers.assert_eq(
			paths.CLI,
			"/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli",
			"Lua must retain the stable PKG endpoint"
		)
		helpers.assert_true(
			source:find('"' .. paths.CLI .. '"', 1, true) ~= nil,
			"Swift must reject every executable except the exact Lua CLI endpoint"
		)
	end)

	helpers.it("does not confuse the CLI with any shared process family", function()
		local cli = require("platform.remap.ke_paths").CLI:lower()
		local basename = cli:match("([^/]+)$")
		helpers.assert_eq(basename, "karabiner_cli",
			"the only child executable must be karabiner_cli")
		for _, forbidden in ipairs({
			"karabiner-elements",
			"core-service",
			"console_user_server",
			"karabiner_grabber",
			"session_monitor",
			"observer",
			"virtualhid",
		}) do
			helpers.assert_true(basename:find(forbidden, 1, true) == nil,
				"the CLI endpoint must not name shared family " .. forbidden)
		end
	end)
end)
