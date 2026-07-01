--- tests/unit/lib/test_vscode_bridge_ax_cache.lua

--- ==============================================================================
--- MODULE: vscode_bridge AX Frame Cache Regression Tests
--- DESCRIPTION:
--- Source-level guard for the "vscode-bridge-blocking-ax-call" bug in
--- lib/vscode_bridge.lua.
---
--- ROOT CAUSE ENCODED:
--- get_editor_ax_frame() called hs.axuielement synchronously on every invocation
--- of estimate_position(). hs.axuielement is an IPC call into the macOS
--- Accessibility subsystem that can block the Hammerspoon main thread for up to
--- 100 ms when VSCode is busy or respawn AX permissions. Called once per
--- streaming LLM token (dozens per second), this produced observable stuttering
--- and could violate the 50 ms HID latency budget on slower machines.
---
--- The fix: cache the AX frame in _ax_frame_cache for FRAME_CACHE_TTL_S (200 ms).
--- Subsequent calls within the TTL return the cached result without touching AX.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =============================================================================================================
-- ============================================================================================================
-- ======= 1/ AX frame is cached with a TTL to avoid per-call blocking (vscode-bridge-blocking-ax-call) =======
-- ============================================================================================================
-- =============================================================================================================

helpers.describe("vscode_bridge — AX frame cache (vscode-bridge-blocking-ax-call)", function()

	local function read_source()
		local src_path = helpers.driver_root() .. "lib/vscode_bridge.lua"
		local fh = io.open(src_path, "r")
		helpers.assert_true(fh ~= nil, "vscode_bridge.lua must be readable")
		local src = fh:read("*a"); fh:close()
		return src
	end

	helpers.it("source declares _ax_frame_cache variable", function()
		local src = read_source()
		helpers.assert_true(
			src:find("_ax_frame_cache", 1, true) ~= nil,
			"vscode_bridge.lua must declare _ax_frame_cache for the AX result (vscode-bridge-blocking-ax-call)"
		)
	end)

	helpers.it("source declares FRAME_CACHE_TTL_S constant", function()
		local src = read_source()
		helpers.assert_true(
			src:find("FRAME_CACHE_TTL_S", 1, true) ~= nil,
			"vscode_bridge.lua must declare FRAME_CACHE_TTL_S (vscode-bridge-blocking-ax-call)"
		)
	end)

	helpers.it("get_editor_ax_frame returns cached result before making an AX call", function()
		local src = read_source()
		-- The guard must check the cache before the pcall that calls axuielement
		local cache_check = src:find("_ax_frame_cache ~= nil", 1, true)
		local ax_call     = src:find("axuielement", 1, true)
		helpers.assert_true(cache_check ~= nil, "cache check must exist in get_editor_ax_frame")
		helpers.assert_true(ax_call ~= nil, "axuielement call must still be present for the live path")
		helpers.assert_true(
			cache_check < ax_call,
			"cache check must appear before the axuielement call so hits bypass the blocking IPC (vscode-bridge-blocking-ax-call)"
		)
	end)

	helpers.it("result is stored back into _ax_frame_cache after each live AX call", function()
		local src = read_source()
		helpers.assert_true(
			src:find("_ax_frame_cache = result", 1, true) ~= nil,
			"get_editor_ax_frame must store the result back into _ax_frame_cache (vscode-bridge-blocking-ax-call)"
		)
	end)

end)
