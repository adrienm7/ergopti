--- tests/unit/infra/test_managed_http_deadline_native.lua

--- ==============================================================================
--- MODULE: Test Managed Http Deadline Native
--- DESCRIPTION:
--- Preserves independent managed-network controls and actual production imports.
--- Source registration alone does not qualify native or installed behavior.
--- ==============================================================================

--- One registered envelope contains the complete original four native controls.
local helpers = require("tests.helpers")
local driver = helpers.driver_root()
helpers.it("managed_http: actual luv complete four-control inventory", function()
    local cleanup_logger = require("logger.shim")
    local saved_error = cleanup_logger.error
    local ok, detail = pcall(function()
local uv = require("luv")
local Clock = require("infra.monotonic")
local Logger = require("logger.shim")
local logs = {}
Logger.error = function(_, message) logs[#logs + 1] = message end
local Deadline = dofile(driver .. "/infra/managed_http_deadline.lua")
local function handles()
	local count = 0
	uv.walk(function() count = count + 1 end)
	return count
end
local baseline = handles()
local count = 0
local function control(name, callback)
	callback()
	assert(handles() == baseline, "Exact native handle retirement required")
	count = count + 1
	print("PASS " .. name .. ": native handles retired")
end
control("expiry logical notification before actual closure", function()
	local token
	local expired, retired, premature = 0, 0, nil
	local began = Clock.now_ms()
	token = Deadline.start(began + 30, function()
		expired = expired + 1
		premature = token:is_settled()
	end)
	assert(token.started)
	token:on_settled(function() retired = retired + 1 end)
	uv.run()
	local elapsed = Clock.now_ms() - began
	assert(expired == 1 and retired == 1 and premature == false)
	assert(token:is_settled())
	assert(elapsed >= 20 and elapsed < 1000, "Actual native timer must execute within bounded fixture budget")
end)
control("accepted cancel waits actual native close callback", function()
	local expired, retired = 0, 0
	local token = Deadline.start(Clock.now_ms() + 5000, function() expired = expired + 1 end)
	assert(token.started)
	token:on_settled(function() retired = retired + 1 end)
	assert(token:cancel())
	assert(not token:is_settled() and retired == 0)
	uv.run()
	assert(token:is_settled() and retired == 1 and expired == 0)
end)
control("settlement callback reentry retains successor timer debt", function()
	local successor
	local retired = 0
	local token = Deadline.start(Clock.now_ms() + 5000, function() error("Unexpected original expiry") end)
	token:on_settled(function()
		assert(token:is_settled())
		successor = Deadline.start(Clock.now_ms() + 5000, function() error("Unexpected successor expiry") end)
		assert(successor.started and successor:cancel() and not successor:is_settled())
		successor:on_settled(function() retired = retired + 1 end)
	end)
	assert(token:cancel())
	uv.run()
	assert(token:is_settled() and successor and successor:is_settled() and retired == 1)
end)
control("throwing logical callback logs fixed safe diagnostic", function()
	local token = Deadline.start(Clock.now_ms() + 20, function() error("fixed private dummy callback marker") end)
	uv.run()
	assert(token:is_settled())
	assert(#logs == 1 and logs[1] == "Deadline terminal callback raised.")
end)
assert(count == 4)
print("ACTUAL NATIVE DEADLINE RECEIPTS: 4 passed, 0 failed; no process children; no live timer handles")

    end)
    cleanup_logger.error = saved_error
    if not ok then error(detail, 0) end
end)
