-- Original public Keymap callback with registered native fixture ports.
local root=assert(arg[1]);local driver=root.."/static/ergopti_plus/macos"
package.path=driver.."/?.lua;"..driver.."/?/init.lua;"..driver.."/tests/stubs/?.lua;"..root.."/static/ergopti_plus/_shared/lua/?.lua;"..root.."/static/ergopti_plus/_shared/lua/?/init.lua;"..package.path
local file=assert(io.open(driver.."/tests/unit/modules/keymap/terminators/test_nav_invalidates_hotstring_buffer.lua","rb"));local source=file:read("*a");file:close()
local boundary=assert(source:find('\nhelpers.describe("navigation invalidates',1,true))
local load_fixture,physical_key,find_tap,drain=assert(load(source:sub(1,boundary-1).."\nreturn load_fixture,physical_key,find_tap,drain_immediate_timers", "@registered-public-keymap-fixture", "t"))()
local rows={}
local function scenario(name,events,register)
 local keymap,hs,state,effects,cleanup=load_fixture()
 local tail_calls={}
 local Registry=package.loaded["modules.keymap.registry"]
 local original_tail=Registry.mappings_for_tail
 local owners={keymap_add=keymap.add,registry_tail=original_tail,expander=package.loaded["modules.keymap.expander"].try_auto_expand,serializer=package.loaded["adapters.synthetic_input"].leave_callback}
 local owner_sources={};for role,fn in pairs(owners) do local source=debug.getinfo(assert(fn),"S").source;assert(source:find("/static/ergopti_plus/macos/",1,true),role.." is not original driver source: "..source);owner_sources[role]=source end
 Registry.mappings_for_tail=function(tail) tail_calls[#tail_calls+1]=tail;return original_tail(tail) end
 local ok,err=xpcall(function()
  if register then keymap.add(register.trigger,"EXPANDED",{auto_expand=true,is_case_sensitive=true,is_case_sensitive_strict=true,final_result=register.final ~= false});keymap.sort_mappings() end
  local tap=assert(find_tap(hs,hs.eventtap.event.types.keyDown))
  local observations={}
  if register then table.insert(events,1,{"",14}) end
  for _,input in ipairs(events) do
   local event=physical_key(input[1],input[2]);if input[3] then event.getFlags=function() return input[3] end end
   local consumed,returned=tap.fn(event);drain(hs)
   local returned_text={};for _,native in ipairs(returned or {}) do if native.isDown and type(native.getUnicodeString)=="function" then returned_text[#returned_text+1]=native:getUnicodeString() end end
   observations[#observations+1]={input=input[1],code=input[2] or 0,buffer=state.buffer,consumed=consumed,returned_count=returned and #returned or 0,returned_text=table.concat(returned_text)}
  end
  rows[#rows+1]={name=name,observations=observations,buffer=state.buffer,emitted=effects.emitted,emitted_count=#effects.emitted,tail_calls=tail_calls,owner_sources=owner_sources}
 end,debug.traceback)
 Registry.mappings_for_tail=original_tail;cleanup();assert(ok,err)
end
scenario("composed-single",{{"a"},{"",14},{"é",14}})
scenario("empty-pending-backspace",{{"a"},{"",14},{"",51}})
scenario("spacing-accent-backspace-control",{{"a"},{"´",14},{"",51}})
scenario("empty-pending-escape",{{"a"},{"",14},{"",53}})
scenario("empty-pending-arrow",{{"a"},{"",14},{"",123}})
scenario("two-ascii-event",{{"^0",29}},{trigger="^0"})
scenario("two-ascii-separate-control",{{"^",24},{"0",29}},{trigger="^0"})
scenario("unicode-ascii-event-control",{{"€0",29}},{trigger="€0"})
scenario("two-latin-event-control",{{"éà",14}},{trigger="éà"})
scenario("three-ascii-event-control",{{"^00",29}},{trigger="^00"})
scenario("suffix-only-unicode-prefix",{{"´0",29}},{trigger="0",final=false})
scenario("suffix-only-spaced-punctuation",{{" ?",44}},{trigger="?",final=false})
scenario("suffix-only-separated-control",{{"´",14},{"0",29}},{trigger="0",final=false})
print(assert(require("json").encode({qualification="Actual original Keymap/Registry/Expander/SyntheticInput over registered native fixtures; Unicode payloads are explicit event-port inputs. No native macOS dead-state grouping or receiving application measured.",rows=rows})))
