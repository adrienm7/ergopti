-- Audit fixture: actual submenu/settings/watchers after public terminator rename.
-- The parent's menu context is supplied its documented trigger-label formatter;
-- this does not claim full Keymap startup or a physical magic-key event.
local repository=assert(arg[1],"repository root required")
local driver=repository.."/static/ergopti_plus/macos"
package.path=driver.."/?.lua;"..driver.."/?/init.lua;"..driver.."/tests/stubs/?.lua;"..repository.."/static/ergopti_plus/_shared/lua/?.lua;"..repository.."/static/ergopti_plus/_shared/lua/?/init.lua;"..package.path
_G.hs=require("hs")
local native_json=hs.json
local file=assert(io.open(driver.."/tests/unit/platform/remap/watchers/test_watchers_capsword_auto_off.lua","rb"));local source=file:read("*a");file:close()
local stop=assert(source:find('\nhelpers.describe("CapsWord watcher:',1,true))
local fresh,activate,key=assert(load(source:sub(1,stop-1).."\nreturn fresh_harness,activate,key","@capsword-magic-native-fixture","t"))()
local h=fresh({caps_word_idle_timeout_seconds=0,caps_word_pointer_pointer_motion=false,caps_word_pointer_left_click=false})
local term=require("keymap.terminators")
assert(term.update_magic_key("§"))
local star
for _,definition in ipairs(term.TERMINATOR_DEFS) do if definition.key=="star" then star=definition end end
assert(star and star.chars[1]=="§")
file=assert(io.open(repository.."/static/ergopti_plus/_shared/data/locales/en.json","rb"));local translations=assert(native_json.decode(file:read("*a")));file:close()
package.loaded["infra.i18n"].get=function(label) return translations[label] or label end
local state=h.settings.current_values()
local rows=assert(require("ui.menu.menu_caps_word").build({state=state,state_getters={},save_prefs=function() return true end,updateMenu=function() end,applyTriggerChar=function(text) return (text:gsub("★","§")) end}))
local selected
local function visit(items)
 for _,row in ipairs(items) do
  if row.title=="§ : Magic key" then selected=row end
  if type(row.menu)=="table" then visit(row.menu) end
 end
end
visit(rows)
assert(selected and type(selected.fn)=="function" and not selected.checked)
selected.fn()
assert(h.settings.policy().chars["★"]==true and h.settings.policy().chars["§"]~=true)
activate(h);key(h,"§")
assert(h.active and #h.writers==0)
key(h,"★")
assert(not h.active and #h.writers==1)
print("menu="..selected.title,"catalogue="..star.chars[1],"policy_old_star="..tostring(h.settings.policy().chars["★"]),"policy_current_magic="..tostring(h.settings.policy().chars["§"]),"new_magic_keeps_active=true","old_star_clears=true")
assert(h.watchers.stop_gesture_watcher(h.watcher))
