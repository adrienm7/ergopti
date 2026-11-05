-- Supplement: reuse the frozen public fixture ports, loading original owners.
local directory = assert(arg[0]:match("^(.*)/[^/]+$"), "Invoke with a path")
local file = assert(io.open(directory .. "/../public-probe.lua", "rb"))
local source = file:read("*a");file:close()
local boundary = assert(source:find("\nfor _,raw in ipairs", 1, true))
local scenario = assert(load(source:sub(1,boundary-1).."\nreturn scenario", "@frozen-public-native-fixture", "t"))()
local rows = {}
for _,input in ipairs({{"nan",0/0},{"positive-infinity",math.huge},{"negative-infinity",-math.huge},{"zero",0},{"one",1}}) do
 scenario("public-arm-"..input[1],function(h)
  h.set_timeout(input[2])
  local result = table.pack(pcall(h.keymap.arm_one_shot_shift))
  local row = {name=input[1],called=result[1],return_arity=result.n-1}
  if result[1] then
   row.accepted=result[2]
   h.calls.clock=1000000000000
   local event=h.event(0);h.down(event)
   row.first_character_at_clock_1e12=event:getCharacters(false)
  else row.error=tostring(result[2]) end
  rows[#rows+1]=row
 end)
end
assert(#rows==5)
print(assert(require("json").encode(rows)))
