local root='/workspace/worktrees/parity-sequential-2026-11-05/linux/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('compat.utf8').install()
require('test.runner_home').isolate()
local S=require('modules.shortcuts.manager')
S.init({enabled=true,persist=false});assert(S.set_wrap_on_type_enabled(true))
local W=require('modules.shortcuts.wrap_on_type')
local results={}
local function scenario(char, options)
 options=options or {}
 local primary='baseline'
 local typed,reads={},0
 local active=true
 local w=W.new({context_epoch=S.wrap_selection_epoch,is_active=function() return active and S.is_enabled() and S.is_wrap_on_type_enabled() and S.configuration_admitted() end,
 get_pair=S.get_wrap_pair,read_primary=function() reads=reads+1;return true,primary end,
 type_text=function(text,owner) assert(owner.current());typed[#typed+1]=text;return true end})
 w.on_pointer_down();primary=options.unchanged and 'baseline' or 'lève\n二😀'
 if options.inactive then active=false end
 if options.aba then assert(S.set_wrap_on_type_enabled(false));assert(S.set_wrap_on_type_enabled(true)) end
 local consumed=w.on_key({char=char,code=10,mods=options.mods or {altgr=true}})
 print(string.format('char=%q consumed=%s writes=%d reads=%d output=%q',char,tostring(consumed),#typed,reads,typed[1] or ''))
 return consumed,typed,reads
end
for _,char in ipairs({'«','»'}) do
 assert(S.get_wrap_pair(char)==nil)
 local l,r=S.resolve_wrap_pair(char);assert(l=='« ' and r==' »')
 assert(S.get_wrap_pairs()['« '].left=='« ')
 local consumed,writes,reads=scenario(char)
 assert(not consumed and #writes==0 and reads==1)
 print('EXPLICIT_PARAMETER '..char..' left='..string.format('%q',l)..' right='..string.format('%q',r))
end
local consumed,writes=scenario('(');assert(consumed and writes[1]=='(lève\n二😀)')
consumed,writes=scenario(')',{mods={shift=true}});assert(consumed and writes[1]=='(lève\n二😀)')
consumed,writes=scenario('(', {unchanged=true});assert(not consumed and #writes==0)
consumed,writes=scenario('(', {inactive=true});assert(not consumed and #writes==0)
consumed,writes=scenario('(', {aba=true});assert(not consumed and #writes==0)
local left,right=S.resolve_wrap_pair('«|»');assert(left=='«' and right=='»')
left,right=S.resolve_wrap_pair('LEFT|RIGHT');assert(left=='LEFT' and right=='RIGHT')
local trigger=S.get_wrap_pair('“');local parsedleft,parsedright=S.resolve_wrap_pair('“')
print('AMBIGUOUS_QUOTE typed='..trigger.left..'…'..trigger.right..' parameter='..parsedleft..'…'..parsedright)
print('PASS production manager catalogue and production wrap controller; recording output port only; no native input/clipboard')
