--- tests/unit/meta/test_install_budget.lua

--- Independent fixed clock/cap/brand cases; no native or physical-ACK claim.
local Budget = require("updater.install_budget")
local tests = {}
local function test(name, body) tests[#tests + 1] = { name, body } end
local function defaults(cap)
 if cap == nil then cap = 100 end
 return { release_install = { install_timeout_ms = cap } }
end
test("fractional original observation retains exact deadline", function()
 local token = assert(Budget.capture(defaults(), 0.25)); assert(Budget.deadline(token) == 100.25)
 assert(Budget.admit(token, 99.75)); assert(not Budget.admit(token, 100.25))
end)
test("mutated defaults cannot extend captured cap", function()
 local d = defaults(); local token = assert(Budget.capture(d, 0.25))
 d.release_install.install_timeout_ms = 100000
 assert(Budget.deadline(token) == 100.25 and not Budget.admit(token, 100.25))
end)
test("later phase observations never restart local install cap", function()
 local token = assert(Budget.capture(defaults(), 0.25))
 assert(Budget.admit(token, 50.25) and Budget.admit(token, 99.25))
 assert(Budget.deadline(token) == 100.25 and not Budget.admit(token, 100.25))
end)
test("zero fractional and invalid caps refuse before reservation", function()
 for _, cap in ipairs({ 0, -1, 0.5, math.huge, "100", false }) do assert(Budget.capture(defaults(cap), 0.25) == nil) end
 local d = { release_install = {} }; assert(Budget.capture(d, 0.25) == nil)
end)
test("bad native observation refuses admission", function()
 local token = assert(Budget.capture(defaults(), 0.25))
 assert(not Budget.admit(token, 0/0) and not Budget.admit(token, math.huge) and not Budget.admit(token, -1))
end)
test("regressive native observation cannot authorize a new phase", function()
 local token = assert(Budget.capture(defaults(), 0.25))
 assert(Budget.admit(token, 50.25)); assert(not Budget.admit(token, 49.25))
end)
test("safe integer overflow refuses original deadline", function()
 assert(Budget.capture(defaults(100), 9007199254740950) == nil)
end)
test("retirement is logical and cannot grant new clock consent", function()
 local token = assert(Budget.capture(defaults(), 0.25)); assert(Budget.retire(token))
 assert(Budget.deadline(token) == nil and not Budget.admit(token, 1))
end)
test("forged equality token cannot borrow installation deadline", function()
 local token = assert(Budget.capture(defaults(), 0.25))
 local calls = 0; local mt = { __eq = function() calls = calls + 1; return true end }
 setmetatable(token, mt); local forged = setmetatable({}, mt)
 local ok, err = xpcall(function()
  assert(Budget.deadline(forged) == nil and not Budget.admit(forged, 1) and not Budget.retire(forged))
  assert(calls == 0 and Budget.admit(token, 1))
 end, debug.traceback)
 setmetatable(token, nil); if not ok then error(err, 0) end
end)
test("canonical install data declares literal three minute local cap", function()
 local path = assert(require("infra.paths").shared("modules/updater/defaults.json"))
 local file = assert(io.open(path, "rb")); local raw = file:read("*a"); assert(file:close())
 local d = assert(require("json").decode(raw))
 assert(d.release_install.install_timeout_ms == 180000)
 local token = assert(Budget.capture(d, 12.25)); assert(Budget.deadline(token) == 180012.25)
end)
assert(#tests == 10, "local install budget independent control floor")

-- Genuine normal registration retains every independent body and oracle.
local helpers = require("tests.helpers")
helpers.describe("Canonical Local Install Budget", function()
	assert(#tests == 10, "Independent case floor changed")
	for _, case in ipairs(tests) do
		assert(type(case[1]) == "string" and type(case[2]) == "function", "Independent registration refused")
		helpers.it(case[1], case[2])
	end
end)

-- Additive listing-policy controls retain all original deadline assertions.
local listing_tests = {
 { "canonical listing ceiling covers the independently measured release", function()
  local path = assert(require("infra.paths").shared("modules/updater/defaults.json"))
  local file = assert(io.open(path, "rb")); local raw = file:read("*a"); assert(file:close())
  local d = assert(require("json").decode(raw))
  local cap = assert(Budget.capture_listing(d))
  assert(cap == 8388608 and cap > 117004 and cap > 229756)
 end },
 { "missing listing policy refuses without a guessed process limit", function()
  assert(Budget.capture_listing(nil) == nil and Budget.capture_listing({}) == nil)
  assert(Budget.capture_listing({ release_install = {} }) == nil)
 end },
 { "non numeric listing limits refuse", function()
  for _, value in ipairs({ false, "8388608", {}, function() end }) do
   assert(Budget.capture_listing({ release_install = { listing_max_output_bytes = value } }) == nil)
  end
 end },
 { "zero negative fractional and nonfinite limits refuse", function()
  for _, value in ipairs({ 0, -1, 0.5, math.huge, 0/0, 9007199254740992 }) do
   assert(Budget.capture_listing({ release_install = { listing_max_output_bytes = value } }) == nil)
  end
 end },
 { "positive integer boundary is literal and bounded", function()
  assert(Budget.capture_listing({ release_install = { listing_max_output_bytes = 1 } }) == 1)
  assert(Budget.capture_listing({ release_install = { listing_max_output_bytes = 9007199254740991 } }) == 9007199254740991)
 end },
 { "listing capture ignores inherited descriptor getters", function()
  local reads = 0
  local mt = { __index = function() reads = reads + 1; return 8388608 end }
  assert(Budget.capture_listing(setmetatable({}, mt)) == nil)
  assert(Budget.capture_listing({ release_install = setmetatable({}, mt) }) == nil)
  assert(reads == 0)
 end },
 { "defaults mutation cannot enlarge a captured listing ceiling", function()
  local d = { release_install = { listing_max_output_bytes = 8388608 } }
  local cap = assert(Budget.capture_listing(d))
  d.release_install.listing_max_output_bytes = 9007199254740991
  d.release_install = {}; assert(cap == 8388608)
 end },
}
helpers.describe("Canonical Archive Listing Ceiling", function()
 assert(#listing_tests == 7, "Independent listing policy floor changed")
 for _, case in ipairs(listing_tests) do helpers.it(case[1], case[2]) end
end)

return tests
