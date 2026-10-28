--- tests/meta/architecture/test_native_lease_cli_path_parity.lua

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
			.. "/launcher/Sources/ErgoptiPlus/RemapLeaseWorker.swift"
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

	helpers.it("admits the owned runtime's tool byte-for-byte and nothing else of that runtime", function()
		package.loaded["platform.remap.ke_paths"] = nil
		local paths = require("platform.remap.ke_paths")
		local file = assert(io.open(helpers.driver_root()
			.. "/launcher/Sources/ErgoptiPlus/RemapLeaseWorker.swift", "r"))
		local source = file:read("*a")
		file:close()

		helpers.assert_eq(paths.cli_for("owned"), paths.OWNED.CLI)
		helpers.assert_true(source:find('"' .. paths.OWNED.CLI .. '"', 1, true) ~= nil,
			"Swift must accept the exact owned CLI the Lua owner selects")
		-- The lease's only child executable is a command line tool: the runtime's
		-- Core and Console must never be named by the Swift allowlist.
		helpers.assert_true(source:find(paths.OWNED.CORE_SERVICE, 1, true) == nil)
		helpers.assert_true(source:find(paths.OWNED.CONSOLE, 1, true) == nil)
		local endpoints = 0
		for literal in source:gmatch('kOwnedKarabinerCLIPath%s*=%s*"([^"]+)"') do
			endpoints = endpoints + 1
			helpers.assert_eq(literal, paths.OWNED.CLI)
		end
		helpers.assert_eq(endpoints, 1, "the owned endpoint is declared exactly once in Swift")
	end)

	helpers.it("selects the endpoint through the one launcher argument both runtimes share", function()
		package.loaded["platform.remap.ke_paths"] = nil
		local paths = require("platform.remap.ke_paths")
		paths.select_runtime("owned")
		local file = assert(io.open(helpers.driver_root() .. "/platform/remap/lease_controller.lua", "r"))
		local controller = file:read("*a")
		file:close()
		-- Both spawn sites pass the runtime-selected tool and add no endpoint of
		-- their own, so the Swift allowlist is the only second spelling.
		local _, spawns = controller:gsub("KePaths%.CLI", "")
		helpers.assert_eq(spawns, 2, "the worker and the revoker are the only lease CLI consumers")
		helpers.assert_true(controller:find("ergoptiplus_remap_cli", 1, true) == nil)
		helpers.assert_eq(paths.CLI, paths.OWNED.CLI)
		package.loaded["platform.remap.ke_paths"] = nil
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
