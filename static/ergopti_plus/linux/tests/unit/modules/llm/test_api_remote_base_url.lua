--- tests/unit/modules/llm/test_api_remote_base_url.lua

--- ==============================================================================
--- MODULE: Remote Provider Base URL Authorities
--- DESCRIPTION:
--- The public URL boundary keeps bracketed IPv6 hosts separate from their ports.
--- Existing schemes, paths, credentials and malformed-address refusals retain
--- their policies. These pure boundary tests do not simulate native networking.
--- ==============================================================================

local helpers = require("tests.helpers")
local Remote = helpers.load_module("modules.llm.api_remote")

local accepted = {
	{ "http://localhost", "http://localhost" },
	{ "HTTPS://api.example.test/v1///", "https://api.example.test/v1" },
	{ "http://127.0.0.1:19876/v1/", "http://127.0.0.1:19876/v1" },
	{ "https://api.example.test:65535/v1", "https://api.example.test:65535/v1" },
	{ "http://api.example.test:1", "http://api.example.test:1" },
	{ "https://[::1]/v1/", "https://[::1]/v1" },
	{ "http://[2001:db8::1]", "http://[2001:db8::1]" },
	{ "http://[::ffff:127.0.0.1]/v1", "http://[::ffff:127.0.0.1]/v1" },
	{ "http://[::1]:1/v1/", "http://[::1]:1/v1" },
	{ "https://[::1]:65535", "https://[::1]:65535" },
	{ "http://[2001:db8::1]:19876/v1", "http://[2001:db8::1]:19876/v1" },
	{ "HTTPS://[::ffff:127.0.0.1]:443/v1///", "https://[::ffff:127.0.0.1]:443/v1" },
	{ "http://[::1]:00080/v1", "http://[::1]:00080/v1" },
}

local refused = {
	{ "", "base URL is empty" },
	{ false, "base URL is empty" },
	{ "localhost/v1", "base URL must include a scheme and host" },
	{ "file://localhost/v1", "base URL scheme must be http or https" },
	{ "https://owned@localhost/v1", "base URL must not contain userinfo" },
	{ "https://owned@[::1]:19876/v1", "base URL must not contain userinfo" },
	{ "http://localhost/v1?token=owned", "base URL must not contain a query or fragment" },
	{ "http://[::1]:19876/v1?token=owned", "base URL must not contain a query or fragment" },
	{ "http://[::1]:19876/v1#owned", "base URL must not contain a query or fragment" },
	{ "http://localhost:0/v1", "base URL port is outside 1..65535" },
	{ "http://localhost:65536/v1", "base URL port is outside 1..65535" },
	{ "http://[::1]:0/v1", "base URL port is outside 1..65535" },
	{ "http://[::1]:65536/v1", "base URL port is outside 1..65535" },
	{ "http://[::1]:/v1", "base URL host is invalid" },
	{ "http://[::1]:port/v1", "base URL host is invalid" },
	{ "http://[::1]:-1/v1", "base URL host is invalid" },
	{ "http://[::1]:1:2/v1", "base URL host is invalid" },
	{ "http://[::1/v1", "base URL host is invalid" },
	{ "http://::1]:80/v1", "base URL host is invalid" },
	{ "http://[]:80/v1", "base URL host is invalid" },
	{ "http://[::1]tail:80/v1", "base URL host is invalid" },
	{ "http://[gg::1]:80/v1", "base URL host is invalid" },
	{ "http://[fe80::1%eth0]:80/v1", "base URL host is invalid" },
	{ "http://[::1]:80/space here", "base URL contains whitespace, a control character or a backslash" },
	{ "http://[::1]:80/line\nnext", "base URL contains whitespace, a control character or a backslash" },
	{ "http://[::1]:80/nul\0tail", "base URL contains whitespace, a control character or a backslash" },
	{ "http://[::1]:80/back\\slash", "base URL contains whitespace, a control character or a backslash" },
}

helpers.describe("Remote bracketed IPv6 base URL admission", function()
	assert(#accepted == 13 and #refused == 27, "every independent base URL vector executes")
	for _, row in ipairs(accepted) do
		helpers.it("IPv6 URL boundary accepts " .. row[1], function()
			local url, reason = Remote.normalize_base_url(row[1])
			helpers.assert_eq(url, row[2])
			helpers.assert_eq(reason, "ok")
		end)
	end
	for index, row in ipairs(refused) do
		helpers.it("IPv6 URL boundary refuses invalid input " .. index, function()
			local url, reason = Remote.normalize_base_url(row[1])
			helpers.assert_nil(url)
			helpers.assert_eq(reason, row[2])
		end)
	end
end)
