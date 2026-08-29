--- tests/unit/lib/test_vscode_bridge_caret_ingest.lua

--- ==============================================================================
--- MODULE: VS Code Bridge Caret Ingest Regression Tests
--- DESCRIPTION:
--- Exercises the real HTTP callback and JSON decoder so scalar JSON payloads
--- cannot escape the server boundary or replace the last valid caret snapshot.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =================================
-- =================================
-- ======= 1/ Test Fixture =========
-- =================================
-- =================================

--- Loads the real bridge and captures its committed HTTP callback.
--- @return table bridge Loaded bridge module.
--- @return function callback Committed server callback.
local function load_fixture()
	local callback = nil
	local listening_port = 0
	local server = nil
	server = {
		setInterface = function(self) return self end,
		setPort = function(self, port)
			listening_port = port
			return self
		end,
		setCallback = function(self, candidate)
			callback = candidate
			return self
		end,
		start = function(self) return self end,
		getPort = function() return listening_port end,
		stop = function(self)
			listening_port = 0
			return self
		end,
	}

	local bridge = helpers.load_with_stubs("infra.vscode_bridge", {
		httpserver = { new = function() return server end },
	})
	helpers.assert_true(bridge.start_server(), "the HTTP fixture must commit")
	helpers.assert_true(type(callback) == "function", "the HTTP callback must be installed")
	return bridge, callback
end





-- =======================================
-- =======================================
-- ======= 2/ Ingest Type Contract =======
-- =======================================
-- =======================================

helpers.describe("vscode_bridge caret ingest", function()
	helpers.it("HS-053 rejects scalar JSON without losing the last valid caret", function()
		local bridge, callback = load_fixture()
		local response_body, status, headers = callback(
			"POST",
			"/caret",
			{},
			'{"active":true,"line":7,"visibleStartLine":2,"character":4}'
		)
		helpers.assert_eq(response_body, "{}")
		helpers.assert_eq(status, 200)
		helpers.assert_eq(headers["Content-Type"], "application/json")

		local seeded = bridge.get_caret(5)
		helpers.assert_true(type(seeded) == "table", "the valid object must seed caret state")
		helpers.assert_eq(seeded.line, 7)

		for _, scalar_body in ipairs({ "5", "true", '"text"' }) do
			local call_ok, body, scalar_status, scalar_headers = xpcall(function()
				return callback("POST", "/caret", {}, scalar_body)
			end, debug.traceback)
			helpers.assert_true(call_ok,
				"scalar JSON must not escape the HTTP callback: " .. scalar_body)
			helpers.assert_eq(body, "{}")
			helpers.assert_eq(scalar_status, 200)
			helpers.assert_eq(scalar_headers["Content-Type"], "application/json")
			helpers.assert_true(bridge.get_caret(5) == seeded,
				"scalar JSON must preserve the exact last valid caret: " .. scalar_body)
		end

		helpers.assert_true(bridge.stop_server(), "the HTTP fixture must settle")
	end)
end)
