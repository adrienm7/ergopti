local root,out=assert(arg[1]),assert(arg[2])
package.path=root..'/static/ergopti_plus/_shared/lua/?.lua;'..root..'/static/ergopti_plus/_shared/lua/?/init.lua;'..package.path
require('compat.utf8').install()
local fixture=dofile(out..'/probes/catalogue-fixture.lua')
local Pair,Prefs,Mutation,Leaf,Codec=require('wrap_pair'),require('menu.wrap_preferences'),require('menu.wrap_mutation'),require('toml_codec.leaf_rows'),require('toml_codec')
local count=0
local function eq(label,a,b) count=count+1;assert(a==b,label..': '..tostring(a)..' ~= '..tostring(b)); print('CONTROL '..label..' actual='..tostring(a)) end
for _,v in ipairs(fixture.vectors) do local l,r=Pair.parse(v.value,fixture.pairs);eq('vector/'..v.id..'/left',l,v.left);eq('vector/'..v.id..'/right',r,v.right) end
for i,p in ipairs(fixture.pairs) do
 for _,field in ipairs{'left','right'} do
  local value=p[field]; local l,r=Pair.parse(value,fixture.pairs)
  -- Explicit rule gives every opening symbol precedence over all closing symbols.
  local expected
  for _,f in ipairs{'left','right'} do for _,q in ipairs(fixture.pairs) do if not expected and q[f]:match('^%s*(.-)%s*$')==value:match('^%s*(.-)%s*$') then expected=q end end end
  eq('catalogue/'..i..'/'..field..'/left',l,expected.left);eq('catalogue/'..i..'/'..field..'/right',r,expected.right)
 end
end
eq('catalogue-description-present',#Pair.describe(fixture.pairs)>0,true)
eq('invalid-type',Pair.parse(123,fixture.pairs),nil)
eq('no-catalogue',Pair.parse('(',nil),nil)
local l,r=Pair.parse('🙂|é',fixture.pairs);eq('Unicode-parameter-left',l,'🙂');eq('Unicode-parameter-right',r,'é')
l,r=Pair.parse('**|**',fixture.pairs);eq('multichar-action-allowed',l,'**');eq('multichar-action-right',r,'**')
local function project(source)
 local doc,shapes=Leaf.decode_source(source);local rejected={};local taken=0
 local flat=Prefs.project(doc,shapes,function() taken=taken+1 end,function(path,why) rejected[#rejected+1]=why end)
 return flat,rejected,taken
end
local source='[shortcuts.wrap_symbols]\ncustom=[{left="🙂",right="é",future={note="retain"}}]\nfuture="keep"\n[shortcuts.wrap_symbols.states]\n"("=false\n"« "=false\nobsolete="retain"\n'
local flat,rejected,taken=project(source)
eq('states-disabled-retained',flat.wrap_symbol_states['('],false)
eq('spaced-left-state-retained',flat.wrap_symbol_states['« '],false)
eq('custom-Unicode-scalar',flat.custom_wrap_symbols[1].left,'🙂')
eq('custom-future-metadata',flat.custom_wrap_symbols[1].future.note,'retain')
eq('invalid-fields-reported',#rejected,2)
for _,case in ipairs{{text='[shortcuts.wrap_symbols]\ncustom={}\n',key='custom_wrap_symbols'},{text='[shortcuts.wrap_symbols]\nstates=[]\n',key='wrap_symbol_states'},{text='[shortcuts.wrap_symbols]\ncustom=[{left="ab",right="c"}]\n',key='custom_wrap_symbols'}} do
 local f,bad=project(case.text);eq('malformed-projection-refused/'..case.key,f[case.key],nil);eq('malformed-projection-reported/'..case.key,#bad,1)
end
local rows=Prefs.prepare(source,{wrap_symbol_states={['(']=true,['« ']=false},custom_wrap_symbols=flat.custom_wrap_symbols})
eq('complete-state-projection-prepared',#rows,2)
local true_rows=0;for _,row in ipairs(rows) do if row.value==true then true_rows=true_rows+1 end end
eq('state-change-row-boolean',true_rows,1)
local cleared=Prefs.prepare(source,{wrap_symbol_states={},custom_wrap_symbols={}})
eq('clear-owned-leaves-only',#cleared,3)
local ok,err=pcall(Prefs.prepare,'[shortcuts]\nwrap_symbols="old"\n',{wrap_symbol_states={['(']=false}})
eq('obsolete-container-save-refused',ok,false);eq('obsolete-refusal-reason',tostring(err):find('explicit cleanup',1,true)~=nil,true)
local nochange=Prefs.prepare('[shortcuts]\nwrap_symbols="old"\n',{wrap_symbol_states={},custom_wrap_symbols={}})
eq('empty-default-keeps-obsolete-source',#nochange,0)
ok=pcall(Prefs.prepare,'',{custom_wrap_symbols={{left='ab',right='c'}}});eq('multichar-management-custom-refused',ok,false)
for _,scalar in ipairs{'a','é','🙂'} do local prepared=Prefs.prepare('',{custom_wrap_symbols={{left=scalar,right=scalar}}});eq('single-scalar-custom-admitted/'..scalar,#prepared>0,true) end
for _,mode in ipairs{'false','nil','truthy','throw','true'} do
 local state={wrap_symbol_states={['(']=false},custom_wrap_symbols={{left='a',right='b'}},private='keep'}
 local old=state.custom_wrap_symbols;local saves=0
 local committed=Mutation.commit(state,function(candidate) candidate.custom_wrap_symbols={{left='x',right='y'}};return true end,function()
  saves=saves+1;eq('input-prior-during-save/'..mode,Mutation.view(state).custom_wrap_symbols[1].left,'a');eq('claim-during-save/'..mode,Mutation.pending(state),true)
  if mode=='throw' then error('synthetic refusal') elseif mode=='false' then return false elseif mode=='truthy' then return 'yes' elseif mode=='true' then return true end
 end)
 eq('save-reached-once/'..mode,saves,1);eq('strict-ack/'..mode,committed,mode=='true');eq('claim-released/'..mode,Mutation.pending(state),false)
 eq('state-after-receipt/'..mode,state.custom_wrap_symbols[1].left,mode=='true' and 'x' or 'a');eq('predecessor-not-mutated/'..mode,old[1].left,'a');eq('foreign-field-kept/'..mode,state.private,'keep')
end
local state={wrap_symbol_states={},custom_wrap_symbols={}};local nested,ns
local accepted=Mutation.commit(state,function(candidate) nested=Mutation.commit(state,function()error('nested mutation must not run')end,function()ns=true;return true end);candidate.custom_wrap_symbols={{left='a',right='b'}};return true end,function()return true end)
eq('outer-committed',accepted,true);eq('reentrant-refused',nested,false);eq('nested-writer-not-called',ns,nil)
local successor={{left='z',right='z'}}
accepted=Mutation.commit(state,function(c)c.custom_wrap_symbols={};return true end,function()state.custom_wrap_symbols=successor;return false end)
eq('foreign-successor-refusal',accepted,false);eq('foreign-successor-preserved',state.custom_wrap_symbols,successor)
print('TOTAL assertions='..count..'; actual shared parser/preferences/mutation executed; native GUI and desktop receiving unrun')
