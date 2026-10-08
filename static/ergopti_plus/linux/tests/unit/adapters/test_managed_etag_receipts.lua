--- tests/unit/adapters/test_managed_etag_receipts.lua

--- ==============================================================================
--- MODULE: Independent Final ETag Header Controls
--- DESCRIPTION:
--- Fixed native header frames distinguish final validators from proxy/interim
--- fields. The native receiving fixture separately exercises real updater/cache,
--- wire headers, anonymous pipes and physical settlement.
--- ==============================================================================

local helpers = require("tests.helpers")
local Receipt = require("infra.http_redirect_receipt")
local ExactIdentity = require("infra.curl_identity")
local function validate(_, value) return not value:find("[%z\r\n]") end

helpers.describe("final response ETag observation", function()
	helpers.it("keeps only the final complete frame after CONNECT and interim status", function()
		local observed = Receipt.response_etag('HTTP/1.1 200 Connection established\r\nETag: "PROXY"\r\n\r\n'
			.. 'HTTP/1.1 100 Continue\r\nETag: "INTERIM"\r\n\r\n'
			.. 'HTTP/2 200\r\nETag: "FINAL"\r\nContent-Length: 2\r\n\r\n', 200, validate)
		helpers.assert_true(observed.present)
		helpers.assert_eq(observed.value, '"FINAL"')
	end)
	helpers.it("does not associate an earlier frame's validator with a final untagged body", function()
		local observed = Receipt.response_etag('HTTP/1.1 200 Connection established\r\nETag: "HOP"\r\n\r\n'
			.. 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n', 200, validate)
		helpers.assert_eq(observed.present, false)
		helpers.assert_nil(observed.value)
	end)
	helpers.it("distinguishes an untagged complete 304 from a missing frame", function()
		local observed = Receipt.response_etag("HTTP/1.1 304 Not Modified\r\n\r\n", 304, validate)
		helpers.assert_eq(observed.present, false)
		helpers.assert_eq(observed.status, 304)
	end)
	for _, bytes in ipairs({
		'HTTP/1.1 200 OK\r\nETag: "E1"\r\nETag: "E2"\r\n\r\n',
		'HTTP/1.1 200 OK\r\nETag: "E1"\r\n',
		'HTTP/1.1 200 OK\r\nETag: "E1"\r\n\r\ntrailing foreign bytes',
		'HTTP/1.1 503 Unavailable\r\nETag: "E1"\r\n\r\n',
		'HTTP/1.1 200 OK\r\nETag: \r\n\r\n',
	}) do
		local fixed = bytes
		helpers.it("refuses an independently ambiguous, incomplete or inconsistent final frame", function()
			helpers.assert_nil(Receipt.response_etag(fixed, 200, validate))
		end)
	end
end)

local function native_file(bytes, ambiguous_close)
	local live, closes = {}, {}
	local next_descriptor = 11
	local native = { constants = { O_RDONLY = 0, O_NONBLOCK = 2048 } }
	function native.fs_open(path)
		next_descriptor = next_descriptor + 1
		live[next_descriptor] = path
		return next_descriptor
	end
	function native.fs_fstat(descriptor)
		assert(live[descriptor])
		return { type = "file", dev = 1, size = #bytes, mtime = { sec = 1, nsec = 0 }, ctime = { sec = 1, nsec = 0 } }
	end
	function native.fs_read(descriptor, size, offset)
		local path = assert(live[descriptor])
		local data = path == "/literal-etag" and bytes or "pos:\t0\nflags:\t00\nino:\t55\n"
		return data:sub(offset + 1, offset + size)
	end
	function native.fs_close(descriptor)
		closes[descriptor] = (closes[descriptor] or 0) + 1
		live[descriptor] = nil
		if ambiguous_close and descriptor == 12 then return nil, "EIO", "EIO" end
		return true
	end
	return native, live, closes
end
helpers.describe("conditional bytes reuse the exact descriptor ledger", function()
	helpers.it("returns exact bounded regular-file bytes only after native descriptor closure", function()
		local native, live = native_file('"E0"\r\n')
		local owner = ExactIdentity.new(native)
		helpers.assert_eq(owner:read_regular("/literal-etag", 65536, false), '"E0"\r\n')
		helpers.assert_true(owner:is_settled())
		helpers.assert_nil(next(live))
	end)
	helpers.it("retains ambiguous close debt without reopening or retrying a descriptor number", function()
		local native, _, closes = native_file('"E0"\n', true)
		local owner = ExactIdentity.new(native)
		helpers.assert_nil(owner:read_regular("/literal-etag", 65536, false))
		helpers.assert_eq(owner:is_settled(), false)
		owner:cancel(); owner:cancel()
		helpers.assert_eq(closes[12], 1)
	end)
end)

-- Metadata controls use actual preflight/public wrappers without starting a child.
local Prepared = require("tests.support.prepared_native_ports")
local Public = require("tests.support.managed_http_native_ports")
local initial = "https://etag-fixture.invalid/start"

helpers.describe("explicit cold ETag affinity admission", function()
	helpers.it("admits a cold save-only GET without inventing a compare file", function()
		local curl, state = Prepared.fresh_client()
		local options = { method = "GET", buffered = true, follow_redirects = true,
			etag_affinity = true, etag_save = "/fixed/cold-etag" }
		local allowed, err, token = curl.preflight(initial, {}, nil, options)
		helpers.assert_true(allowed, err)
		helpers.assert_true(type(token) == "table")
		helpers.assert_nil(options.etag_compare)
		helpers.assert_eq(#state.requests + #state.handles, 0)
	end)
	helpers.it("refuses affinity mutation across an admitted prepared capability", function()
		local curl, state = Prepared.fresh_client()
		local options = { method = "GET", buffered = true, follow_redirects = true,
			etag_affinity = true, etag_save = "/fixed/cold-etag" }
		local allowed, _, token = curl.preflight(initial, {}, nil, options)
		helpers.assert_true(allowed)
		options.prepared_headers, options.etag_affinity = token, false
		local admitted, err = curl.preflight(initial, {}, nil, options)
		helpers.assert_eq(admitted, false)
		helpers.assert_eq(err, "HTTP prepared conditional validator refused")
		helpers.assert_eq(#state.requests + #state.handles, 0)
	end)
	for _, invalid in ipairs({ { etag_affinity = "true" }, { etag_affinity = 1 },
		{ etag_affinity = {} }, { follow_redirects = false }, { output_path = "/fixed/output" },
		{ etag_save = false }, { managed_redirects = true } }) do
		local fixed = invalid
		helpers.it("refuses invalid or excluded cold affinity before native allocation", function()
			local client, state = Public.fresh_client()
			local options = { owner = "cold-affinity", timeout_ms = 1000,
				follow_redirects = true, etag_affinity = true, etag_save = "/fixed/cold-etag" }
			for key, value in pairs(fixed) do options[key] = value end
			local result
			local operation = client.get_owned(initial, {}, options, function(value) result = value end)
			helpers.assert_eq(operation.started, false)
			helpers.assert_true(operation:is_settled())
			helpers.assert_eq(result.ok, false)
			helpers.assert_eq(#state.requests + #state.handles, 0)
		end)
	end
	helpers.it("refuses cold affinity on a POST before native allocation", function()
		local client, state = Public.fresh_client()
		local result
		local operation = client.post_stream_owned(initial, {}, "fixed body",
			{ owner = "cold-affinity-post", timeout_ms = 1000, follow_redirects = true,
				etag_affinity = true, etag_save = "/fixed/cold-etag" }, function() end, function(value) result = value end)
		helpers.assert_eq(operation.started, false)
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(#state.requests + #state.handles, 0)
	end)
end)
