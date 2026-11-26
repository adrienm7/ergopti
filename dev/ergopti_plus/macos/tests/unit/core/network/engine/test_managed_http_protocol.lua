--- tests/unit/core/network/engine/test_managed_http_protocol.lua

--- ==============================================================================
--- MODULE: Managed HTTP Worker Protocol
--- DESCRIPTION:
--- The update check reads the launcher worker's frames (UPD-13): one optional
--- head, its body chunks and one terminal frame, as ManagedHTTPFrame writes
--- them. A stream that is not exactly that is refused whole, never read as an
--- empty successful answer, and a failed transfer carries the receipt its
--- closed reason proves.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")

package.loaded["core.network.engine.managed_http_protocol"] = nil
local Protocol = require("core.network.engine.managed_http_protocol")

--- One frame as ManagedHTTPFrame.encode writes it.
local function frame(tag, payload)
	return string.pack(">I4", #payload + 1) .. string.char(tag) .. payload
end

local function head(status, headers)
	return frame(Protocol.TAG_HEAD, Json.encode({ version = 1, status = status, headers = Json.array(headers or {}) }))
end

local function terminal(reason, stage)
	return frame(Protocol.TAG_TERMINAL, Json.encode({ version = 1, success = reason == "complete", reason = reason,
		native_refusal_stage = stage }))
end

helpers.describe("managed_http_protocol: the request the worker reads", function()
	helpers.it("encodes the exact request fields with sorted headers", function()
		local request = assert(Protocol.encode_request("https://api.github.com/repos/o/r/releases",
			{ ["User-Agent"] = "UA", Accept = "application/json" }, 15))
		local decoded = Json.decode(request)
		helpers.assert_eq(decoded, { version = 1, url = "https://api.github.com/repos/o/r/releases", method = "GET",
			headers = { { "Accept", "application/json" }, { "User-Agent", "UA" } }, timeout = 15, idle_timeout = 15,
			direct = false })
	end)
	helpers.it("refuses a non-https URL, fractional seconds and duplicate headers", function()
		helpers.assert_nil((Protocol.encode_request("http://example.test/", {}, 15)))
		helpers.assert_nil((Protocol.encode_request("https://example.test/", {}, 1.5)))
		helpers.assert_nil((Protocol.encode_request("https://example.test/", { accept = "a", Accept = "b" }, 15)))
	end)
	helpers.it("keeps an empty header list a JSON array", function()
		local request = assert(Protocol.encode_request("https://example.test/", nil, 5))
		helpers.assert_contains(request, '"headers":[]')
	end)
end)

helpers.describe("managed_http_protocol: the frames the worker writes", function()
	helpers.it("reads a complete answer with its headers and its chunked body", function()
		local result = Protocol.result(0, head(200, { { "Etag", '"v1"' } })
			.. frame(Protocol.TAG_BODY, "[{") .. frame(Protocol.TAG_BODY, "}]") .. terminal("complete"))
		helpers.assert_eq(result, { ok = true, status = 200, body = "[{}]", headers = { Etag = '"v1"' } })
	end)
	helpers.it("hands a 304 and a 403 back as answers, not as failures", function()
		helpers.assert_eq(Protocol.result(0, head(304) .. terminal("complete")).status, 304)
		local limited = Protocol.result(0, head(403, { { "X-RateLimit-Remaining", "0" } }) .. terminal("complete"))
		helpers.assert_eq(limited.ok, false)
		helpers.assert_eq(limited.headers["X-RateLimit-Remaining"], "0")
		helpers.assert_nil(limited.failure_receipt)
	end)
	helpers.it("a failed transfer carries status 0 and the receipt of its reason", function()
		local result = Protocol.result(74, terminal("offline", "native_session_terminal"))
		helpers.assert_eq(result.status, 0)
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(result.failure_receipt, Protocol.failure_receipt("offline"))
		helpers.assert_contains(result.error, "native offline at native_session_terminal")
	end)
	helpers.it("a transfer that failed after its head is still a failure", function()
		local result = Protocol.result(74, head(200) .. frame(Protocol.TAG_BODY, "[") .. terminal("deadline"))
		helpers.assert_eq(result.status, 0)
		helpers.assert_eq(result.failure_receipt, {})
	end)
	for _, case in ipairs({
		{ "an empty output", "" },
		{ "a truncated prefix", "\0\0" },
		{ "a truncated frame", string.pack(">I4", 10) .. string.char(Protocol.TAG_BODY) },
		{ "no terminal frame", head(200) .. frame(Protocol.TAG_BODY, "[]") },
		{ "a body before the head", frame(Protocol.TAG_BODY, "[]") .. terminal("complete") },
		{ "a frame after the terminal", head(200) .. terminal("complete") .. frame(Protocol.TAG_BODY, "x") },
		{ "a second head", head(200) .. head(200) .. terminal("complete") },
		{ "a success without a head", terminal("complete") },
		{ "an unknown tag", frame(1, "x") .. terminal("complete") },
		{ "a success naming a failure", head(200) .. frame(Protocol.TAG_TERMINAL,
			'{"version":1,"success":true,"reason":"offline"}') },
	}) do
		helpers.it("refuses " .. case[1] .. " whole, with no receipt", function()
			local result = Protocol.result(0, case[2])
			helpers.assert_eq(result.ok, false)
			helpers.assert_eq(result.status, 0)
			helpers.assert_nil(result.failure_receipt)
			helpers.assert_nil(result.body)
		end)
	end
	helpers.it("refuses a complete answer whose worker did not exit 0", function()
		local result = Protocol.result(74, head(200) .. terminal("complete"))
		helpers.assert_eq(result.ok, false)
		helpers.assert_nil(result.body)
	end)
end)

helpers.describe("managed_http_protocol: what each closed reason proves", function()
	helpers.it("names only offline, certificate and proxy, and copies each receipt", function()
		local Paths = require("core.fs.engine.paths")
		local handle = assert(io.open(Paths.shared("core/network/data/managed_network.json"), "rb"))
		local contract = require("core.network.engine.failure").new(Json.decode(handle:read("*a")))
		handle:close()
		for reason, cause in pairs({ offline = "offline", certificate = "certificate", proxy = "proxy",
			connect = "unknown", http = "unknown", deadline = "unknown", file_write = "unknown", forged = "unknown" }) do
			local report = contract.classify(Protocol.failure_receipt(reason), {})
			helpers.assert_eq(report.cause, cause, reason)
			helpers.assert_true(report.evidence ~= "invalid_receipt", reason)
		end
		local first = Protocol.failure_receipt("offline")
		first.stage = "tls"
		helpers.assert_eq(Protocol.failure_receipt("offline").stage, "connect", "a caller cannot edit the table")
	end)
end)
