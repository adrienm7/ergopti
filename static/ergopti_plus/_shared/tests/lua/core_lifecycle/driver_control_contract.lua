--- _shared/tests/lua/core_lifecycle/driver_control_contract.lua

--- ==============================================================================
--- MODULE: Local Driver Control Policy Contract
--- DESCRIPTION:
--- Replays the shared driver-control vectors against the shared Lua policy, so
--- the macOS and Linux suites hold the same admission, result texts and
--- completion rule as the AutoHotkey port, and checks the real declaration.
--- ==============================================================================

local M = {}
local Policy = require("diagnostics.engine.control_driver_control")
local Json = require("core.text.engine.json")

local function read(path)
	local file = assert(io.open(path, "rb"))
	local content = assert(file:read("*a"))
	assert(file:close())
	return content
end

--- Registers the declaration, request, result and completion vectors.
--- @param helpers table Driver assertions and case registration.
--- @param shared_root string Path of static/ergopti_plus/_shared.
function M.run(helpers, shared_root)
	local spec = Policy.validate(Json.decode(read(shared_root .. "/diagnostics/data/control/driver_control.json")))
	local corpus = Json.decode(read(shared_root .. "/tests/corpus/control/driver_control.json"))

	helpers.describe("Shared local driver control policy", function()
		helpers.it("admits only a request that carries the session token", function()
			helpers.assert_eq(#corpus.requests, 13, "complete request vectors")
			for _, row in ipairs(corpus.requests) do
				local id, reason, echoed = Policy.parse_request(spec, row.text, corpus.token, Json.decode)
				helpers.assert_eq(id, row.request_id, row.name)
				helpers.assert_eq(reason, row.reason, row.name .. " reason")
				helpers.assert_eq(echoed, row.echoed, row.name .. " echoed identifier")
			end
		end)

		helpers.it("writes each result byte for byte and refuses an inconsistent one", function()
			helpers.assert_eq(#corpus.results, 16, "complete result vectors")
			for _, row in ipairs(corpus.results) do
				local ok, text = pcall(Policy.result_text, spec, row.fields)
				if row.invalid then
					helpers.assert_true(not ok, row.name .. " is refused")
				else
					helpers.assert_true(ok, row.name .. ": " .. tostring(text))
					helpers.assert_eq(text, row.text, row.name)
				end
			end
		end)

		helpers.it("completes a pending request only in the successor it names", function()
			helpers.assert_eq(#corpus.completions, 7, "complete completion vectors")
			for _, row in ipairs(corpus.completions) do
				helpers.assert_eq(Policy.completion(spec, row.text, row.pid, Json.decode), row.completed, row.name)
			end
		end)

		helpers.it("resolves a pending record: claim, completion, double claim and timeout", function()
			helpers.assert_eq(#corpus.resolutions, 12, "complete resolution vectors")
			for _, row in ipairs(corpus.resolutions) do
				local kind, text = Policy.resolve(spec, row.text, row.pid, row.now, Json.decode)
				helpers.assert_eq(kind, row.kind, row.name .. " kind")
				helpers.assert_eq(text, row.result, row.name .. " result")
			end
		end)

		helpers.it("declares the pending lifetime and the timeout reason", function()
			helpers.assert_eq(spec.pending_ttl_seconds, 120)
			helpers.assert_eq(spec.timeout_reason, "deadline")
			helpers.assert_true(spec.state_set.claimed and spec.state_set.timeout, "both new states are declared")
		end)

		helpers.it("resolves each platform folder from its declared base", function()
			local env = { LOCALAPPDATA = "C:\\Users\\u\\AppData\\Local", HOME = "/Users/u", XDG_RUNTIME_DIR = "/run/user/1000/" }
			local getenv = function(name) return env[name] end
			helpers.assert_eq(Policy.folder(spec, "windows", getenv, "Ergopti", "\\"),
				"C:\\Users\\u\\AppData\\Local\\Ergopti\\control")
			helpers.assert_eq(Policy.folder(spec, "macos", getenv, "Ergopti", "/"),
				"/Users/u/Library/Application Support/Ergopti/control")
			helpers.assert_eq(Policy.folder(spec, "linux", getenv, "ergopti", "/"),
				"/run/user/1000/ergopti/control")
			local folder, reason = Policy.folder(spec, "linux", function() return nil end, "ergopti", "/")
			helpers.assert_nil(folder, "no runtime folder, no control")
			helpers.assert_eq(reason, "XDG_RUNTIME_DIR is not set")
		end)

		helpers.it("publishes a session the tools can read and refuses a malformed one", function()
			helpers.assert_eq(Policy.session_text(spec, "linux", 77, corpus.token),
				'{"schema":1,"driver":"linux","pid":77,"token":"' .. corpus.token .. '"}\n')
			helpers.assert_true(not pcall(Policy.session_text, spec, "linux", 77, "short"), "a short token")
			helpers.assert_true(not pcall(Policy.session_text, spec, "beos", 77, corpus.token), "an unknown driver")
			helpers.assert_true(not pcall(Policy.parse_request, spec, "{}", "short", Json.decode),
				"a malformed session token stops the caller")
		end)
	end)
end

return M
