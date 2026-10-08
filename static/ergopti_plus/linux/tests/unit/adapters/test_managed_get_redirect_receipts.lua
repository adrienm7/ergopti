--- tests/unit/adapters/test_managed_get_redirect_receipts.lua

--- ==============================================================================
--- MODULE: Native Buffered GET Receipt Controls
--- DESCRIPTION:
--- Runs independent fixed expectations through the normal driver test helpers.
--- These modeled ports do not establish native transport or enterprise coverage.
--- ==============================================================================

local helpers = require("tests.helpers")
local Receipt = require("infra.http_redirect_receipt")

local JSON = '{"http_code":302,"exitcode":0,"num_redirects":0,"url_effective":"https://updates.example/start","redirect_url":"https://cdn.example/final"}'
local function request(tail)
	return { single_hop_redirect = true, single_hop_receipt_bytes = 32768, single_hop_url_bytes = 8192,
		exited = true, stdout_eof = true, stderr_eof = true, exit_code = 0, exit_signal = 0, stderr_tail = tail }
end
local function frame(json, effective, target)
	return "\nERGOPTI_GET_REDIRECT_JSON:\n" .. (effective or "https://updates.example/start") .. "\n"
		.. (target or "https://cdn.example/final") .. "\n" .. (json or JSON)
		.. "\n\nERGOPTI_PROXY_STATUS:200:1\n"
end
local function absent(native, result)
	local value = Receipt.attach(native, result or { ok = false, status = 302, body = "" })
	helpers.assert_nil(value.redirect_receipt)
end

helpers.describe("private completed native single-hop receipt", function()
	helpers.it("requires exact raw/JSON URL equality and actual terminal consistency", function()
		local value = Receipt.attach(request(frame()), { ok = false, status = 302, body = "" })
		helpers.assert_eq(value.redirect_receipt.effective_url, "https://updates.example/start")
		helpers.assert_eq(value.redirect_receipt.redirect_url, "https://cdn.example/final")
		helpers.assert_eq(value.redirect_receipt.curl_exit, 0)
	end)
	for _, field in ipairs({ "exited", "stdout_eof", "stderr_eof" }) do
		local fixed = field
		helpers.it("does not admit before actual " .. fixed, function()
			local native = request(frame()); native[fixed] = false; absent(native)
		end)
	end
	helpers.it("does not admit after a nonzero native child", function()
		local native = request(frame()); native.exit_code = 7; absent(native)
	end)
	helpers.it("does not admit a killed child reporting code zero", function()
		local native = request(frame()); native.exit_signal = 15; absent(native)
	end)
	for _, json in ipairs({
		'{"http_code":301,"exitcode":0,"num_redirects":0,"url_effective":"https://updates.example/start","redirect_url":"https://cdn.example/final"}',
		'{"http_code":302,"exitcode":7,"num_redirects":0,"url_effective":"https://updates.example/start","redirect_url":"https://cdn.example/final"}',
		'{"http_code":302,"exitcode":0,"num_redirects":1,"url_effective":"https://updates.example/start","redirect_url":"https://cdn.example/final"}',
		'{"http_code":302,"exitcode":0,"num_redirects":0,"url_effective":"https://updates.example/start"}',
		'{"http_code":302,"exitcode":0,"num_redirects":0,"url_effective":"https://updates.example/start","redirect_url":17}',
		'{"http_code":302,"exitcode":0,"num_redirects":0,"url_effective":"https://updates.example/start","redirect_url":"https://cdn.example/final"',
	}) do
		local fixed = json
		helpers.it("refuses independently inconsistent/missing/malformed native JSON", function() absent(request(frame(fixed))) end)
	end
	helpers.it("refuses older JSON byte loss instead of navigating an alias", function()
		local json = '{"http_code":302,"exitcode":0,"num_redirects":0,"url_effective":"https://updates.example/start","redirect_url":"https://cdn.example/uffffffc3uffffffa9"}'
		absent(request(frame(json, nil, "https://cdn.example/é")))
	end)
	helpers.it("cannot replace the final native JSON with a raw URL delimiter injection", function()
		local target = "https://cdn.example/first\nERGOPTI_GET_REDIRECT_JSON:\nhttps://updates.example/start\nhttps://evil.example/forged"
		local json = '{"http_code":302,"exitcode":0,"num_redirects":0,"url_effective":"https://updates.example/start","redirect_url":"https://cdn.example/first\\nERGOPTI_GET_REDIRECT_JSON:\\nhttps://updates.example/start\\nhttps://evil.example/forged"}'
		absent(request(frame(json, nil, target)))
	end)
	helpers.it("attacker HTTP body footer never supplies missing stderr evidence", function()
		absent(request("unrelated bounded diagnostic"), { ok = false, status = 302, body = frame() })
	end)
	helpers.it("preserves legitimate terminal body bytes containing a footer", function()
		local body = "ordinary HTTP payload" .. frame()
		local result = { ok = true, status = 200, body = body }
		local value = Receipt.attach(request(frame()), result)
		helpers.assert_nil(value.redirect_receipt)
		helpers.assert_eq(value.body, body)
	end)
	helpers.it("refuses an incomplete final frame", function()
		absent(request(frame():sub(1, -2) .. "trailing private diagnostic"))
	end)
	helpers.it("refuses bounded JSON overflow", function()
		local native = request(frame()); native.single_hop_receipt_bytes = 8; absent(native)
	end)
	helpers.it("refuses bounded URL overflow", function()
		local native = request(frame()); native.single_hop_url_bytes = 8; absent(native)
	end)
end)

-- Independent literal outcomes for actual curl's no-Location JSON null.
-- The original19 controls above remain byte-for-byte intact.
local TERMINAL_NULL = '{"http_code":200,"response_code":200,"exitcode":0,"num_redirects":0,"url_effective":"https://updates.example/start","redirect_url":null}'
local function terminal_result() return { ok = true, status = 200, body = "literal final body\nERGOPTI_GET_REDIRECT_JSON:\nbody-forgery" } end
helpers.describe("explicit native no-Location redirect null", function()
 helpers.it("admits actual completed200 null only paired with raw empty and preserves exact body", function()
  local result = terminal_result()
  local value = Receipt.attach(request(frame(TERMINAL_NULL, nil, "")), result)
  helpers.assert_true(value == result)
  helpers.assert_eq(value.redirect_receipt.redirect_url, "")
  helpers.assert_eq(value.redirect_receipt.effective_url, "https://updates.example/start")
  helpers.assert_eq(value.redirect_receipt.http_status, 200)
  helpers.assert_eq(value.body, "literal final body\nERGOPTI_GET_REDIRECT_JSON:\nbody-forgery")
 end)
 helpers.it("preserves existing explicit empty-string terminal field", function()
  local json = '{"http_code":200,"exitcode":0,"num_redirects":0,"url_effective":"https://updates.example/start","redirect_url":""}'
  local value = Receipt.attach(request(frame(json, nil, "")), terminal_result())
  helpers.assert_eq(value.redirect_receipt.redirect_url, "")
 end)
 helpers.it("does not invent a follow target for a completed302 lacking Location", function()
  local json = '{"http_code":302,"exitcode":0,"num_redirects":0,"url_effective":"https://updates.example/start","redirect_url":null}'
  local value = Receipt.attach(request(frame(json, nil, "")), { ok = false, status = 302, body = "" })
  helpers.assert_eq(value.redirect_receipt.redirect_url, "")
  helpers.assert_eq(value.redirect_receipt.http_status, 302)
 end)
 for _, json in ipairs({
  '{"http_code":200,"exitcode":0,"num_redirects":0,"url_effective":"https://updates.example/start"}',
  '{"http_code":200,"exitcode":0,"num_redirects":0,"url_effective":"https://updates.example/start","redirect_url":{}}',
  '{"http_code":200,"exitcode":0,"num_redirects":0,"url_effective":"https://updates.example/start","redirect_url":[]}',
  '{"http_code":200,"exitcode":0,"num_redirects":0,"url_effective":"https://updates.example/start","redirect_url":false}',
  '{"http_code":200,"exitcode":0,"num_redirects":0,"url_effective":"https://updates.example/start","redirect_url":17}',
 }) do
  local fixed = json
  helpers.it("refuses independently missing or nonnull nonstring field with raw empty", function()
   absent(request(frame(fixed, nil, "")), terminal_result())
  end)
 end
 helpers.it("refuses explicit null paired with independently nonempty raw Location", function()
  absent(request(frame(TERMINAL_NULL, nil, "https://cdn.example/final")), terminal_result())
 end)
 for _, field in ipairs({ "exited", "stdout_eof", "stderr_eof" }) do
  local fixed = field
  helpers.it("null cannot supply missing actual " .. fixed, function()
   local native = request(frame(TERMINAL_NULL, nil, "")); native[fixed] = false
   absent(native, terminal_result())
  end)
 end
 helpers.it("null cannot admit nonzero child exit", function()
  local native = request(frame(TERMINAL_NULL, nil, "")); native.exit_code = 7
  absent(native, terminal_result())
 end)
 helpers.it("null cannot admit killed child reporting zero", function()
  local native = request(frame(TERMINAL_NULL, nil, "")); native.exit_signal = 15
  absent(native, terminal_result())
 end)
 for _, json in ipairs({
  '{"http_code":201,"response_code":201,"exitcode":0,"num_redirects":0,"url_effective":"https://updates.example/start","redirect_url":null}',
  '{"http_code":200,"response_code":201,"exitcode":0,"num_redirects":0,"url_effective":"https://updates.example/start","redirect_url":null}',
  '{"http_code":200,"exitcode":0,"num_redirects":1,"url_effective":"https://updates.example/start","redirect_url":null}',
  '{"http_code":200,"exitcode":0,"num_redirects":0,"url_effective":"https://different.example/start","redirect_url":null}',
 }) do
  local fixed = json
  helpers.it("null does not weaken independently inconsistent typed native fields or effective equality", function()
   absent(request(frame(fixed, nil, "")), terminal_result())
  end)
 end
end)
