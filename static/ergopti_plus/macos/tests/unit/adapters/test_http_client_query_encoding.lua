--- tests/unit/adapters/test_http_client_query_encoding.lua

--- ==============================================================================
--- MODULE: HttpClient Query-Encoding Regression Tests
--- DESCRIPTION:
--- Exercises the production adapter when Hammerspoon's native query encoder is
--- unavailable or rejects a value. An infrastructure failure must never turn a
--- query component back into raw URL syntax.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"infra.logger",
	"adapters.timer_scheduler",
	"adapters.http_client",
}

--- Loads the production adapter with one native encoder and captured errors.
--- @param native_encoder function|nil Native hs.http encoder implementation.
--- @param callback function Receives HttpClient and captured error strings.
local function with_encoder(native_encoder, callback)
	local saved_hs = _G.hs
	local outcome = table.pack(xpcall(function()
		helpers.with_fresh_modules(OWNED_MODULES, function()
			local errors = {}
			local logger = helpers.make_logger_stub()
			logger.error = function(_module, format_string, ...)
				local ok, formatted = pcall(string.format, format_string, ...)
				errors[#errors + 1] = ok and formatted or tostring(format_string)
			end
			package.loaded["infra.logger"] = logger

			local http_stub = {}
			if native_encoder then http_stub.encodeForQuery = native_encoder end
			local HttpClient = helpers.load_with_stubs("adapters.http_client", {
				http = http_stub,
			})
			callback(HttpClient, errors)
		end)
	end, debug.traceback))
	_G.hs = saved_hs
	if not outcome[1] then error(outcome[2], 0) end
end

helpers.describe("http_client query encoding fails safe", function()
	helpers.it("(HS-061) percent-encodes when the native encoder throws", function()
		with_encoder(function()
			error("simulated native encoder failure")
		end, function(HttpClient, errors)
			local raw = "a&b=c d/é"
			local encoded = HttpClient.encodeForQuery(raw)
			helpers.assert_eq(encoded, "a%26b%3Dc%20d%2F%C3%A9",
				"reserved syntax and every UTF-8 byte must remain inside one query value")
			helpers.assert_true(encoded ~= raw,
				"native failure must never be indistinguishable from encoding success")
			helpers.assert_eq(#errors, 1,
				"the native failure must be surfaced exactly once")
			helpers.assert_true(errors[1]:find("native query encoder", 1, true) ~= nil,
				"the diagnostic must identify the failing boundary without logging the value")
			helpers.assert_true(errors[1]:find(raw, 1, true) == nil,
				"query values may contain credentials and must not enter logs")
		end)
	end)

	helpers.it("preserves a valid native encoding result", function()
		with_encoder(function(value)
			return "native:" .. tostring(value)
		end, function(HttpClient, errors)
			helpers.assert_eq(HttpClient.encodeForQuery("value"), "native:value")
			helpers.assert_eq(errors, {})
		end)
	end)

	helpers.it("encodes path segments without query-specific native substitutions", function()
		with_encoder(function()
			return "native-query-result"
		end, function(HttpClient, errors)
			local raw = "models/family name/" .. string.char(0xC3, 0xA9)
			helpers.assert_eq(HttpClient.encodePathSegment(raw),
				"models%2Ffamily%20name%2F%C3%A9")
			helpers.assert_eq(errors, {},
				"path encoding must not consult or report the native query encoder")
		end)
	end)

	helpers.it("also encodes after missing or non-string native results", function()
		local cases = {
			{ label = "missing", native = nil },
			{ label = "nil", native = function() return nil end },
			{ label = "false", native = function() return false end },
		}
		for _, case in ipairs(cases) do
			with_encoder(case.native, function(HttpClient, errors)
				helpers.assert_eq(HttpClient.encodeForQuery("AZaz09-._~ &"),
					"AZaz09-._~%20%26", case.label .. " native encoder")
				helpers.assert_eq(#errors, 1,
					case.label .. " native encoder must be reported once")
			end)
		end
	end)
end)
