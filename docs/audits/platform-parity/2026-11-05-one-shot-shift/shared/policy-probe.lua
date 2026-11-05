-- Actual shared resolver and actual macOS state owner; no native event adapter.
local root = assert(arg[1], "Pass the repository root")
package.path = root .. "/static/ergopti_plus/_shared/lua/?.lua;"
	.. root .. "/static/ergopti_plus/_shared/lua/?/init.lua;"
	.. root .. "/static/ergopti_plus/macos/?.lua;"
	.. root .. "/static/ergopti_plus/macos/?/init.lua;" .. package.path
local Json = require("json")
local Policy = require("tap_hold.one_shot_shift")
local Unicode = require("unicode_case")
local Owner = require("modules.keymap.one_shot_shift")
local Terminators = require("keymap.terminators")
local file = assert(io.open(root .. "/static/ergopti_plus/_shared/tap_hold/one_shot_shift.json", "rb"))
local data = assert(Json.decode(file:read("*a"))); file:close()
local table_results = {}
for _,entry in ipairs(data.results) do table_results[entry.char] = entry.result end
local checked, observations = 0, {}
local function check(value, label)
	assert(value, label); checked = checked + 1
end
local function resolve(text, magic, can_shift)
	return Policy.resolve(text, function(character)
		if character == magic then return data.magic_key_result end
		return table_results[character]
	end, can_shift or function() return false end)
end
for _, entry in ipairs(data.results) do
	local calls = 0
	local kind, result = resolve(entry.char, "★", function() calls=calls+1;return true end)
	check(kind=="text" and result==entry.result, "shared special: " .. entry.char)
	check(calls==0, "a special result never probes native Shift")
	observations[#observations+1]={input=entry.char,kind=kind,result=result}
end
for _, magic in ipairs({"★", "§", "😀"}) do
	check(Terminators.validate_magic_key(magic), "valid canonical magic")
	local kind, result=resolve(magic,magic)
	check(kind=="text" and result==data.magic_key_result, "live magic result")
end
-- Generalized lookup controls: current canonical magic settings reject these.
for _, entry in ipairs(data.results) do
	check(not Terminators.validate_magic_key(entry.char), "table ASCII is not a current magic setting")
	local kind,result=resolve(entry.char,entry.char)
	check(kind=="text" and result==data.magic_key_result,"abstract overlap gives magic priority")
end
local vectors={{"a","A"},{"é","É"},{"ß","Ss"},{"я","Я"},{"ǆ","ǅ"},{"😀","😀"},{"1","1"},{"a\204\129","A\204\129"},{"abc","Abc"},{"x-y","X-Y"},{"\226\128\175%","\226\128\175%"},{"ΟΣ","Ος"},{"İ","I\204\135"}}
for _,entry in ipairs(vectors) do
	local title=Unicode.title(entry[1]);check(title==entry[2],"actual Unicode title "..entry[1])
	local kind,result=resolve(entry[1],"★")
	if entry[1]==title then check(kind==nil and result==nil,"uncased/unchanged spent without output")
	else
		check(kind=="text" and result==title,"literal fallback")
		kind,result=resolve(entry[1],"★",function(candidate)return candidate==title end)
		check(kind=="shift" and result==title,"same-key Shift result")
	end
end
local spends={backspace=true,enter=true,delete=true,tab=true,escape=true}
for _, control in ipairs({"backspace","enter","delete","tab","escape","left","home","f1","capslock","modifier","shortcut","nontext"}) do
	check(Policy.spends_unshifted(control)==(spends[control]==true),"control classification "..control)
	local owner=Owner.new(data);owner:arm(10,2)
	check(owner:take(1,control,"x",11,"★",function()return true end)==nil,"control does not shift")
	check((owner.deadline==nil)==(spends[control]==true),"deadline spending "..control)
end
for _, now in ipairs({11.999,12,12.001}) do
	local owner=Owner.new(data);owner:arm(10,2)
	local kind,result=owner:take(1,nil,"a",now,"★",function()return true end)
	check((kind=="shift")== (now<=12),"inclusive expiry decision")
	check(owner.deadline==nil,"text attempt clears deadline")
	observations[#observations+1]={clock=now,kind=kind or false,result=result or false}
end
local owner=Owner.new(data);owner:arm(10,2)
local kind=owner:take(1,nil,"a",11,"★",function()return true end)
check(kind=="shift" and not owner:claims(1),"decision is not output ACK")
owner:commit(1,kind);check(owner.shifted[1]==true,"accepted Shift owns press")
check(owner:take(2,nil,"b",11.01,"★",function()return true end)==nil,"next rolled letter unaffected")
check(owner:take(3,nil,"c",11.02,"★",function()return true end)==nil,"third rolled letter unaffected")
check(owner:take(1,nil,"a",11.03,"★",function()return true end)=="shift-held","same press retains Shift")
check(owner:release(1)=="shift" and not owner:active(),"release retires Shift ownership")
owner=Owner.new(data);owner:arm(10,2);kind=owner:take(1,nil,".",11,"★",function()error("special must not probe")end)
check(kind=="text" and not owner:claims(1),"special decision not committed")
owner:commit(1,kind);check(owner:take(1,nil,".",11,"★",function()error("repeat must not resolve")end)=="consume","special repeat consumed")
owner:arm(11,2);check(owner:take(1,nil,".",11,"★",function()return false end)=="consume" and owner.deadline==13,"old press repeat does not spend new arm")
owner:disarm();check(owner.absorbed[1]==true and owner.deadline==nil,"disarm retains release debt")
check(owner:release(1)=="consume" and not owner:active(),"absorbed release retires")
owner:arm(20,2);owner:reset();check(not owner:active(),"reset retires all identities")
check(not pcall(function() Owner.new(data):arm(10,0) end),"zero timeout is invalid in actual state owner")
local duplicate={ results={}, magic_key_result=data.magic_key_result }
for _,entry in ipairs(data.results) do duplicate.results[#duplicate.results+1]={char=entry.char,result=entry.result} end
duplicate.results[#duplicate.results+1]={char=data.results[1].char,result=data.results[1].result}
check(not pcall(Owner.new,duplicate),"actual Mac owner rejects duplicate catalogue chars")
print(Json.encode({assertions=checked,table_rows=#data.results,observations=observations,qualification="Actual shared policy/Unicode and actual macOS state owner. No event adapter, AHK arithmetic, physical modifiers, native key repeat or receiving application. ASCII magic/table collisions are abstract lookup controls rejected by current canonical magic configuration."}))
