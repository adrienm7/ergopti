--- tests/unit/ai/engine/api/test_proxy_relay_receipt.lua

--- ==============================================================================
--- MODULE: Proxy Sign-In Refusal Receipt Tests
--- DESCRIPTION:
--- The receipt run_with_proxy_sign_in_relay writes on a refused sign-in names the
--- relay's message for a pull; its absence lets the pull go ahead. The contract is
--- the real shared one.
--- ==============================================================================

local helpers = require("tests.helpers")
local Receipt = require("ai.engine.api.proxy_relay_receipt")

local function with_receipt(contents, callback)
	local path = os.tmpname()
	os.remove(path)
	if contents then
		local file = assert(io.open(path, "wb"))
		file:write(contents)
		file:close()
	end
	Receipt._set_path(path)
	local ok, err = pcall(callback)
	Receipt._set_path(nil)
	os.remove(path)
	if not ok then error(err, 0) end
end

helpers.describe("proxy sign-in refusal receipt", function()
	helpers.it("no receipt lets the pull go ahead", function()
		with_receipt(nil, function()
			helpers.assert_nil(Receipt.reason())
			helpers.assert_nil((Receipt.pull_refusal()))
		end)
	end)

	helpers.it("a closed reason names the relay's own message", function()
		with_receipt("sign_in_rejected\n", function()
			local key, reason = Receipt.pull_refusal()
			helpers.assert_eq(key, "network.relay.sign_in_rejected")
			helpers.assert_eq(reason, "sign_in_rejected")
		end)
	end)

	helpers.it("a reason outside the closed set is the relay's relay_unavailable", function()
		for _, contents in ipairs({ "not_a_reason\n", "", "Sign In\n" }) do
			with_receipt(contents, function()
				local key, reason = Receipt.pull_refusal()
				helpers.assert_eq(key, "network.relay.failed", contents)
				helpers.assert_eq(reason, "relay_unavailable", contents)
			end)
		end
	end)
end)

return true
