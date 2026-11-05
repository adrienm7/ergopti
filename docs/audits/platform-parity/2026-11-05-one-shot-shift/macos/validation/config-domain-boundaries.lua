-- Supplement: original Remap setter over the registered native transaction ports.
-- No original production body is copied; special numbers are described as strings.
local root = assert(arg[1], "Pass repository root")
local driver = root .. "/static/ergopti_plus/macos"
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;" .. driver .. "/tests/stubs/?.lua;"
 .. root .. "/static/ergopti_plus/_shared/lua/?.lua;" .. root .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
local with_fixture = require("tests.support.remap_transaction_fixture")
local function describe(value)
 if type(value) ~= "number" then return {type=type(value),text=tostring(value)} end
 if value ~= value then return {type="number",class="nan"} end
 if value == math.huge then return {type="number",class="positive-infinity"} end
 if value == -math.huge then return {type="number",class="negative-infinity"} end
 return {type="number",class="finite",value=value}
end
local inputs = {
 {"nan", 0/0}, {"positive-infinity", math.huge}, {"negative-infinity", -math.huge},
 {"string-positive-infinity", "inf"}, {"string-nan", "nan"},
 {"string-positive-integer", "2000"}, {"string-positive-fraction", "0.9"},
 {"string-whitespace-positive-integer", " 1 "}, {"string-negative", "-1"},
 {"string-nonnumeric", "invalid"}, {"below-one", 0.9999999999999999},
 {"one", 1}, {"above-one", 1.0000000000000002}, {"one-point-nine", 1.9}
}
local rows = {}
for _,input in ipairs(inputs) do
 with_fixture(function(fixture)
  local remap,calls = fixture.load_enabled_remap({initially_enabled=false})
  local before = remap.get_sticky_timeout()
  local outcome = table.pack(pcall(remap.set_sticky_timeout, input[2]))
  local payload = calls.saved_payloads[#calls.saved_payloads]
  local returns = {}
  for i=2,outcome.n do returns[#returns+1]=describe(outcome[i]) end
  rows[#rows+1] = {
   name=input[1], input=describe(input[2]), before=describe(before),
   called=outcome[1], return_arity=outcome.n-1, returns=returns,
   after=describe(remap.get_sticky_timeout()), save_calls=calls.save,
   saved=describe(payload and payload.sticky_timeout_ms),
   qualification="Original Remap setter/transaction; initially disabled; acknowledged save port only"
  }
 end)
end
assert(#rows==#inputs)
print(assert(require("json").encode(rows)))
