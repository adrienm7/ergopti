-- Original menu provider/callback linked to original Remap setter over declared ports.
local root=assert(arg[1],"Pass repository root")
local driver=root.."/static/ergopti_plus/macos"
package.path=driver.."/?.lua;"..driver.."/?/init.lua;"..driver.."/tests/stubs/?.lua;"..root.."/static/ergopti_plus/_shared/lua/?.lua;"..root.."/static/ergopti_plus/_shared/lua/?/init.lua;"..package.path
_G.hs=require("hs")
local fixture_file=assert(io.open(driver.."/tests/unit/ui/menu/keyboard_layout/test_karabiner_timeout_regenerates.lua","rb"))
local fixture_source=fixture_file:read("*a");fixture_file:close()
local boundary=assert(fixture_source:find('\nhelpers.describe("karabiner delay',1,true))
local make_facade=assert(load(fixture_source:sub(1,boundary-1).."\nreturn make_karabiner", "@registered-menu-native-fixture", "t"))()
local helpers=require("tests.helpers")
local with_fixture=require("tests.support.remap_transaction_fixture")
local function describe(value)
 if type(value)=="number" then
  if value~=value then return {type="number",class="nan"} end
  if value==math.huge then return {type="number",class="positive-infinity"} end
  if value==-math.huge then return {type="number",class="negative-infinity"} end
  return {type="number",class="finite",value=value}
 end
 return {type=type(value),text=tostring(value)}
end
local function find_sticky(item)
 for _,row in ipairs(item.submenu or item.menu or item.items or {}) do
  local label=row.title or row.label
  if label=="menu.tapholds.sticky_title" or (type(label)=="string" and label:find("Sticky modifier delay:",1,true)==1) then return row end
 end
 error("Public menu is missing sticky timeout item")
end
local locale_file=assert(io.open(root.."/static/ergopti_plus/_shared/data/locales/en.json","rb"))
local english=assert(require("json").decode(locale_file:read("*a")));locale_file:close()
local rows={}
for _,enabled in ipairs({false,true}) do
for _,text in ipairs({"2000","0.9","1e309","1e20","invalid"}) do
 with_fixture(function(fixture)
  local remap,calls=fixture.load_enabled_remap({initially_enabled=enabled})
  local facade=make_facade()
  local observations={setter_inputs={},setter_returns={},dialogs={},dialog_replies={},refreshes=0,regenerations=0}
  facade.get_enabled=remap.get_enabled
  facade.get_sticky_timeout=remap.get_sticky_timeout
  facade.set_sticky_timeout=function(value)
   observations.setter_inputs[#observations.setter_inputs+1]=describe(value)
   local returned=table.pack(remap.set_sticky_timeout(value))
   observations.setter_returns[#observations.setter_returns+1]={arity=returned.n,first=describe(returned[1])}
   return table.unpack(returned,1,returned.n)
  end
  facade.regenerate=function() observations.regenerations=observations.regenerations+1;return true end
  local menu=helpers.load_with_stubs("ui.menu.menu_tap_holds", {
   osascript={applescript=function(script)
    observations.dialogs[#observations.dialogs+1]=script
    observations.dialog_replies[#observations.dialog_replies+1]={ok=true,text_returned_type=type(text),text_returned=text}
    return true,{["text returned"]=text}
   end}
  })
  local i18n=package.loaded["infra.i18n"];local original_get=i18n.get
  i18n.get=function(key) if key=="menu.tapholds.sticky_title" then return assert(english[key]) end;return original_get(key) end
  local initial=describe(remap.get_sticky_timeout())
  local item=menu.build({karabiner=facade,updateMenu=function() observations.refreshes=observations.refreshes+1 end})
  local sticky=find_sticky(item)
  local outcome=table.pack(pcall(sticky.action or sticky.fn))
  local row={text=text,before=initial,initially_enabled=enabled,actual_enabled=remap.get_enabled(),parsed=describe(tonumber(text)),action_called=outcome[1],action_return_arity=outcome.n-1,
   after=describe(remap.get_sticky_timeout()),save_calls=calls.save,observations=observations}
  if not outcome[1] then row.action_error=tostring(outcome[2]) end
  local payload=calls.saved_payloads[#calls.saved_payloads]
  row.saved=describe(payload and payload.sticky_timeout_ms)
  local rebuilt,rebuild_result=pcall(menu.build,{karabiner=facade,updateMenu=function() observations.refreshes=observations.refreshes+1 end})
  row.rebuild_called=rebuilt
  if rebuilt then
   local next_sticky=find_sticky(rebuild_result)
   row.rebuilt_label=next_sticky.label or next_sticky.title
   local reopened=table.pack(pcall(next_sticky.action or next_sticky.fn))
   row.reopen_called=reopened[1];row.reopen_return_arity=reopened.n-1
   if not reopened[1] then row.reopen_error=tostring(reopened[2]) end
  else row.rebuild_error=tostring(rebuild_result) end
  row.after_reopen=describe(remap.get_sticky_timeout())
  row.save_calls_after_reopen=calls.save;row.generator_build_calls=calls.build;row.generator_deploy_calls=calls.deploy
  rows[#rows+1]=row
 end)
end
end
assert(#rows==10)
print(assert(require("json").encode(rows)))
