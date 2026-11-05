local root=assert(arg[1]);local dir=assert(debug.getinfo(1,'S').source:match('^@(.*)/[^/]+$'));local file=assert(io.open(dir..'/engine.lua'));local src=file:read('*a');file:close()
local prefix=assert(src:match('^(.-)local consumed,preview,emitted=type_combo'))
local scenario=[[
local Fields=require('infra.personal_info_fields');local metadata={}
package.loaded['modules.keystats'].notify_synthetic=function(text,source,deletes,variant,physical,private)
 effects.emitted[#effects.emitted+1]=text;metadata[#metadata+1]={source=source,private=private,variant=variant}
end
local aliases={a='street_address',b='bic',c='credit_card',d='date_of_birth',e='email_address',f='phone_number_clean',i='iban',m='email_address',n='last_name',p='first_name',s='social_security_number',t='phone_number',w='work_email_address'}
for alias,field in pairs(aliases)do
 local consumed,row,emitted=type_combo(alias);assert(consumed and emitted==info[field]);assert(metadata[#metadata].private==true);print('default alias '..alias..' -> '..field..' full-value/private=true')
end
Personal.stop();assert(Rules.stop())
local keys={};for k in pairs(info)do keys[#keys+1]=k end;table.sort(keys)
local secret=0;local existing_preview_delta=0
for _,field in ipairs(keys)do
 local fcfg=assert(io.open(path,'wb'));assert(fcfg:write(Codec.encode({info=info,letters={p=field}})));assert(fcfg:close())
 assert(Personal.start('',Keymap,path,Rules.refresh_personal_data));assert(Rules.inject_data(Personal.get_info(),'★'));assert(Rules.start(Keymap))
 local consumed,row,emitted=type_combo('p');assert(consumed and emitted==info[field]);assert(metadata[#metadata].private==true)
 local expected=Fields.for_preview(info[field],field)
 if field=='first_name'then assert(row~=expected);existing_preview_delta=existing_preview_delta+1
 elseif field=='street_address'then assert(type(row)=='string' and row:find('Line1',1,true) and row:find('Line2',1,true));print('newline preview normalization='..string.format('%q',row))
 else assert(row==expected,'masked/clear preview mismatch '..field)end
 if Fields.is_masked(field)then assert(row~=info[field] and row:find('•',1,true));secret=secret+1 end
 print('field '..field..' remap p: full-value/private=true preview='..(Fields.is_masked(field)and'masked' or'unmasked'))
 Personal.stop();assert(Rules.stop())
end
assert(secret==4 and existing_preview_delta==1)
print('MATRIX PASS: 13 default aliases;15 known fields;4 masked fields;known MH001 literal-provider preview delta retained once')
-- Read failure affects only preview; actual masking owner fails closed.
local original_open=io.open;Fields._reset();io.open=function(p,...)if p:match('/personal_info/fields%.toml$')then return nil,'controlled declaration refusal'end;return original_open(p,...)end
local shown=Fields.for_preview(info.first_name,'first_name');io.open=original_open;Fields._reset();assert(not shown:find('Synthetic',1,true));assert(Fields.is_masked('unclassified_future_field'))
print('classification-unavailable and unknown-field controls: fail closed; no raw value shown')
assert(Keymap.stop(true))
]]
assert(load(prefix..scenario,'@'..dir..'/matrix.lua'))()
