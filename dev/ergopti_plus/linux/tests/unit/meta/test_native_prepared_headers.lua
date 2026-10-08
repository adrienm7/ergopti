--- tests/unit/meta/test_native_prepared_headers.lua

--- ==============================================================================
--- MODULE: Native Curl Prepared Header Capability Controls
--- DESCRIPTION:
--- Exercises the actual native preflight/composition ports and fixed wire bytes.
--- The independently retained process fixture supplies exact physical receipts.
--- ==============================================================================

local helpers = require("tests.helpers")
local Ports = require("tests.support.prepared_native_ports")
local url = "http://127.0.0.1:9000/fixed"
local function options(token) return { owner = "native-prepared", timeout_ms = 1000, method = "GET", buffered = true, prepared_headers = token } end
local function finish(state) state.complete_request(1, "fixed\nERGOPTI_HTTP_STATUS:200\n") end

helpers.describe("native private immutable header capabilities", function()
	helpers.it("preflight evaluates a caller value exactly once and allocates nothing", function()
		local core, state = Ports.fresh_client()
		local conversions = 0
		local value = setmetatable({}, { __tostring = function() conversions = conversions + 1; return "fixed literal" end })
		local allowed, _, token, view = core.preflight(url, { ["X-Fixed"] = value }, nil, options())
		helpers.assert_true(allowed)
		helpers.assert_eq(conversions, 1)
		helpers.assert_eq(#state.handles + #state.requests, 0)
		local result
		local operation = core.dispatch_owned(url, view, nil, options(token), nil, function(r) result = r end)
		helpers.assert_true(operation.started)
		helpers.assert_eq(conversions, 1)
		helpers.assert_true(state.config:find('header = "X-Fixed: fixed literal"', 1, true) ~= nil)
		finish(state)
		helpers.assert_true(operation:is_settled())
		helpers.assert_true(result.ok)
	end)
	helpers.it("a published map mutation cannot mutate the retained native snapshot", function()
		local core, state = Ports.fresh_client()
		local allowed, _, token, view = core.preflight(url, { ["X-Fixed"] = "original" }, nil, options())
		helpers.assert_true(allowed)
		view["X-Fixed"] = "changed"
		local operation = core.dispatch_owned(url, view, nil, options(token), nil, function() end)
		helpers.assert_eq(operation.started, false)
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(#state.handles + #state.requests, 0)
	end)
	helpers.it("a caller-made token never bypasses canonical header validation", function()
		local core, state = Ports.fresh_client()
		local operation = core.dispatch_owned(url, { ["X-Fixed"] = "safe" }, nil, options({}), nil, function() end)
		helpers.assert_eq(operation.started, false)
		helpers.assert_true(operation:is_settled())
		helpers.assert_eq(#state.handles + #state.requests, 0)
	end)
	helpers.it("redirect rebinding strips sensitive bytes without re-conversion", function()
		local core, state = Ports.fresh_client()
		local allowed, _, token = core.preflight(url, { Authorization = "dummy-secret", ["X-Fixed"] = "literal" }, nil, options())
		helpers.assert_true(allowed)
		local subset = { ["X-Fixed"] = "literal" }
		local rebound = core.rebind_prepared_headers(token, subset)
		helpers.assert_eq(type(rebound), "table")
		local operation = core.dispatch_owned(url, subset, nil, options(rebound), nil, function() end)
		helpers.assert_true(operation.started)
		helpers.assert_eq(state.config:find("dummy-secret", 1, true), nil)
		helpers.assert_true(state.config:find('header = "X-Fixed: literal"', 1, true) ~= nil)
		finish(state)
	end)
	helpers.it("rebinding cannot add or rewrite any admitted header value", function()
		local core = Ports.fresh_client()
		local allowed, _, token = core.preflight(url, { ["X-Fixed"] = "literal" }, nil, options())
		helpers.assert_true(allowed)
		helpers.assert_eq(core.rebind_prepared_headers(token, { ["X-Fixed"] = "changed" }), nil)
		helpers.assert_eq(core.rebind_prepared_headers(token, { ["X-Added"] = "literal" }), nil)
		helpers.assert_eq(core.rebind_prepared_headers({}, {}), nil)
	end)
	helpers.it("prepared empty fields retain curl's exact empty-semicolon config", function()
		local core, state = Ports.fresh_client()
		local allowed, _, token, view = core.preflight(url, { ["X-Empty"] = " \t" }, nil, options())
		helpers.assert_true(allowed)
		local operation = core.dispatch_owned(url, view, nil, options(token), nil, function() end)
		helpers.assert_true(operation.started)
		helpers.assert_true(state.config:find('header = "X-Empty;"', 1, true) ~= nil)
		finish(state)
	end)
	helpers.it("a header token does not cache an old URL or timeout", function()
		local core, state = Ports.fresh_client()
		local allowed, _, token, view = core.preflight(url, { ["X-Fixed"] = "literal" }, nil, options())
		helpers.assert_true(allowed)
		local request = options(token); request.timeout_ms = 321
		local operation = core.dispatch_owned("http://127.0.0.1:9000/new", view, nil, request, nil, function() end)
		helpers.assert_true(operation.started)
		helpers.assert_true(state.config:find('url = "http://127.0.0.1:9000/new"', 1, true) ~= nil)
		helpers.assert_eq(state.timer.timeout_ms, 321)
		finish(state)
	end)
end)
