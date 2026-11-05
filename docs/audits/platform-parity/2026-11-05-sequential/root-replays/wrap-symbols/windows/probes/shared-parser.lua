local root=assert(arg[1])
local shared=root..'/static/ergopti_plus/_shared'
package.path=shared..'/lua/?.lua;'..shared..'/lua/?/init.lua;'..package.path
local Json=require('json')
local Pair=require('wrap_pair')
local function decode(path)
 local f=assert(io.open(path,'r'));local raw=f:read('*a');f:close();return assert(Json.decode(raw))
end
local cat=decode(shared..'/modules/wrap_symbols/wrap_symbols.json')
local pairs_list={}
for _,g in ipairs(cat.groups) do for _,p in ipairs(g.pairs) do pairs_list[#pairs_list+1]=p end end
assert(#pairs_list>=30)
local corpus=decode(shared..'/tests/corpus/action_parameters/wrap_pair_vectors.json')
local checked=0
for _,v in ipairs(corpus.vectors) do
 local left,right=Pair.parse(v.value,pairs_list)
 if v.valid==false then assert(left==nil and right==nil,v.id) else assert(left==v.left and right==v.right,v.id) end
 checked=checked+1
end
assert(checked>=15)
local l,r=Pair.parse('😀|🚀',pairs_list);assert(l=='😀' and r=='🚀')
local nl,nr=Pair.parse('**\n|**',pairs_list);assert(nl==nil and nr==nil)
print('PASS actual shared Lua wrap_pair parser: '..checked..' corpus vectors plus supplementary-Unicode and line-break controls. Runtime='.._VERSION..' '..(jit and jit.version or 'PUC'))
print('LIMIT: pure Lua parameter owner execution only; not AutoHotkey or desktop selection/clipboard/output receiving.')
