local root,out=assert(arg[1]),assert(arg[2])
package.path=root..'/static/ergopti_plus/_shared/lua/?.lua;'..root..'/static/ergopti_plus/_shared/lua/?/init.lua;'..root..'/static/ergopti_plus/linux/?.lua;'..root..'/static/ergopti_plus/linux/?/init.lua;'..package.path
require('compat.utf8').install()
local fixture=dofile(out..'/probes/fixture.lua')
local Codec,Mask,Source=require('toml_codec'),require('personal_info.mask'),require('menu.frames.personal_info_source')
local function read(rel)local h=assert(io.open(root..'/static/ergopti_plus/_shared/'..rel));local x=h:read('*a');h:close();return Codec.decode(x)end
local decl=read('modules/personal_info/fields.toml');local previews=read('modules/personal_info/preview_vectors.toml');local count=0
local function eq(label,a,b)count=count+1;assert(a==b,label..': mismatch '..tostring(a)..' ~= '..tostring(b));print('CONTROL '..label)end
eq('policy-valid',Mask.validate_policy(decl.policy),true)
for i,v in ipairs(previews.vectors)do eq('TOML-preview/'..i,Mask.mask_field(v.input,v.field,decl),v.preview)end
for _,v in ipairs(fixture.mask.vectors)do eq('JSON-preview/'..v.id,Mask.mask_field(v.value,v.field,decl),v.expected)end
for _,v in ipairs(fixture.mask.invalid_policies)do eq('invalid-policy/'..v.id,Mask.mask(v.value,v.policy),v.expected)end
for field,v in pairs(decl.fields)do
 local raw='AB12345678901234';eq('field/'..field,Mask.mask_field(raw,field,decl),v.masked and 'AB••••••••••1234' or raw)
 eq('log-never-screen-reveal/'..field,Mask.redact_for_log(raw,decl.policy),string.rep('•',16))
end
local raw='🙂É1234567890';eq('supplementary-unicode-preview',Mask.mask_field(raw,'iban',decl),'🙂É••••••7890');eq('supplementary-unicode-log-length',Mask.redact_for_log(raw,decl.policy),string.rep('•',12))
eq('separator-hyphen','AB••-••••-7890',Mask.mask_field('AB12-3456-7890','iban',decl))
eq('separator-NBSP',Mask.mask_field('AB12 3456 7890','iban',decl),'AB•• •••• 7890')
eq('unknown-field-closed',Mask.mask_field('SECRET','missing',decl),'••••••')
eq('no-declaration-closed',Mask.mask_field('SECRET',nil,nil),'••••••')
eq('missing-public-flag-closed',Mask.mask_field('SECRET','phone_number',{policy=decl.policy,fields={phone_number={}}}),'••••••')
eq('empty-unchanged',Mask.mask_field('','iban',decl),'')
eq('nonstring-unchanged',Mask.mask_field(12,'iban',decl),12)
for _,key in ipairs{'mask_char','reveal_head','reveal_tail','min_length_to_reveal','preserve_separators'}do local p={};for k,v in pairs(decl.policy)do p[k]=v end;p[key]=nil;eq('missing-policy/'..key,Mask.validate_policy(p),false);eq('missing-policy-mask/'..key,Mask.mask('SECRET',p),'••••••')end
local renderer,root_table,frame,declaration
local function fresh()
 declaration={type='command',id='personal_info_editor_open',i18n='menu.shortcuts.edit_personal_info',platforms={'hs','linux'},unavailable='hide'}
 frame={declaration};root_table={personal_info_editor_frame=frame};renderer={template_rows=function()return{}end,get_root=function()return root_table end,get_array=function(name)return root_table[name]end};package.loaded['infra.manifest_menu']=renderer
end
local prior=package.loaded['infra.manifest_menu'];fresh();local current,template=Source.read(renderer)
eq('editor-source-healthy',current(),true);eq('template-same-owner',template,renderer.template_rows)
declaration.i18n='withdrawn';eq('source-mutated-refused',current(),false)
fresh();current=assert(Source.read(renderer));root_table.personal_info_editor_frame={};eq('source-replaced-refused',current(),false)
fresh();current=assert(Source.read(renderer));renderer.template_rows=function()return{}end;eq('facade-mutated-refused',current(),false)
fresh();current=assert(Source.read(renderer));package.loaded['infra.manifest_menu']={};eq('facade-replaced-refused',current(),false)
fresh();declaration.extra=true;eq('unknown-declaration-field-refused',Source.read(renderer),nil)
fresh();setmetatable(declaration,{__index=function()error('must not call metamethod')end});eq('metatable-refused',Source.read(renderer),nil)
package.loaded['infra.manifest_menu']=prior
-- Actual count owner and actual pure runtime prefix producer, with no fake business model.
local Engine,Prefix=require('dynamic_hotstrings'),require('modules.dynamic_hotstrings.prefix_rules')
local info={phone_number='',phone_number_clean='',social_security_number='199990000000000',iban='ZZ0000000000000000'}
local maps=Prefix.build(info);local expected={phoneprefixes=0,ssnprefixes=0,ibanprefixes=0};for _,m in ipairs(maps)do expected[m.section]=expected[m.section]+1;eq('prefix-private/'..m.section,m.is_private,true);eq('prefix-provenance/'..m.section,type(m.field),'string')end
local counts=Prefix.counts(info)
eq('unspaced-runtime-SSN-mappings',expected.ssnprefixes,1);eq('unspaced-runtime-IBAN-mappings',expected.ibanprefixes,1)
eq('PIS-001-observed-SSN-count',counts.ssnprefixes,2);eq('PIS-001-observed-IBAN-count',counts.ibanprefixes,2)
print('CONTRACT_MISMATCH PIS-001 actual runtime prefix producer:SSN=1,IBAN=1; shared advertised counts:SSN=2,IBAN=2')
local spaced={phone_number='',phone_number_clean='',social_security_number='1 99 99 000 000 000',iban='ZZ00 0000 0000 0000 00'}
local healthy=Prefix.build(spaced);local hc=Prefix.counts(spaced);eq('spaced-runtime-mappings',#healthy,4);eq('spaced-advertised-count',hc.ssnprefixes+hc.ibanprefixes,4)
eq('empty-prefixes',#Prefix.build({}),0);local ec=Prefix.counts({});eq('empty-prefix-counts',ec.ssnprefixes+ec.ibanprefixes+ec.phoneprefixes,0)
eq('disabled-prefixes',#Prefix.build(spaced,function()return false end),0)
print('TOTAL assertions='..count..'; actual shared owners and actual pure Linux prefix producer; native GUI/output receiving unrun; one count-contract mismatch observed')
