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
		-- The guard must check the cache before the pcall that calls axuielement.
		-- It is keyed on the VALIDITY flag rather than on the cached value: nil is a
		-- legitimate outcome, so `_ax_frame_cache ~= nil` never cached a negative
		-- lookup and re-ran the blocking round trip on every call.
		local cache_check = src:find("_ax_frame_valid and", 1, true)
		local ax_call     = src:find("systemWideElement", 1, true)
		helpers.assert_true(cache_check ~= nil,
			"the freshness guard must be keyed on _ax_frame_valid, not on the cached value")
		helpers.assert_true(ax_call ~= nil, "the live accessibility lookup must still be present")
		helpers.assert_true(
			cache_check < ax_call,
			"cache check must appear before the accessibility call so hits bypass the blocking IPC (vscode-bridge-blocking-ax-call)"
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




-- ==================================================================================
-- ==================================================================================
-- ======= 2/ Behaviour: a NEGATIVE lookup is cached for the TTL too ================
-- ==================================================================================
-- ==================================================================================

--- The source assertions above cannot catch this: the cache used to store `nil`
--- on failure AND use `nil` as its "no entry" sentinel, so a negative result was
--- never cached. The TTL check was bypassed and the expensive accessibility round
--- trip re-ran on EVERY call — precisely the load the cache exists to absorb, and
--- the hot path is the tooltip anchor resolved once per streaming LLM token.
--- Only a call counter can prove the round trip is actually skipped.
helpers.describe("vscode_bridge — a negative AX lookup is cached (behaviour)", function()

	--- Loads lib.vscode_bridge with VSCode frontmost, a captured HTTP callback to
	--- seed the caret, and a counting accessibility stub whose frame is too small
	--- to be usable — so the lookup completes with a NEGATIVE (nil) result.
	--- @return table,function The module and a getter for the accessibility call count.
	local function load_bridge_with_counting_ax()
		local ax_calls = 0
		local captured_callback

		local Bridge = helpers.load_with_stubs("lib.vscode_bridge", {
			application = {
				frontmostApplication = function()
					return { bundleID = function() return "com.microsoft.VSCode" end }
				end,
			},
			httpserver = {
				new = function()
					return {
						setPort     = function() end,
						setCallback = function(_, cb) captured_callback = cb end,
						start       = function() end,
						stop        = function() end,
					}
				end,
			},
		})

		-- get_editor_ax_frame reaches the accessibility layer through require, so the
		-- stub must be installed under that module key, not just on the hs table.
		package.loaded["hs.axuielement"] = {
			systemWideElement = function()
				ax_calls = ax_calls + 1
				return {
					attributeValue = function(_, attr)
						if attr == "AXFocusedUIElement" then
							return {
								-- Under the 100x50 usability floor, so the lookup
								-- legitimately resolves to nil.
								attributeValue = function() return { x = 0, y = 0, w = 10, h = 10 } end,
							}
						end
						return nil
					end,
				}
			end,
		}

		-- Seed a live caret through the real server callback so estimate_position()
		-- gets past its own guards and reaches the accessibility lookup.
		Bridge.start_server()
		helpers.assert_true(type(captured_callback) == "function",
			"start_server must register an HTTP callback")
		captured_callback("POST", "/caret", {},
			'{"active":true,"line":5,"visibleStartLine":0,"character":3}')

		return Bridge, function() return ax_calls end
	end

	helpers.it("three calls inside one TTL window make exactly ONE accessibility call", function()
		local Bridge, ax_calls = load_bridge_with_counting_ax()

		Bridge.estimate_position()
		helpers.assert_eq(1, ax_calls(),
			"the first call must perform the live accessibility lookup")

		Bridge.estimate_position()
		Bridge.estimate_position()

		helpers.assert_eq(1, ax_calls(),
			"a negative AX result must be cached for the TTL — repeated calls must NOT re-run the blocking lookup")
	end)

end)
