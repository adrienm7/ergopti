local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('compat.utf8').install()
require('tests.helpers')
local Native=require('infra.openssl_cipher');assert(Native.available)
local Logger=require('logger.shim');local Core=require('keystats.text_cipher')
local calls=0
local cipher=Core.new({logger=Logger,log='audit.synthetic',sha256=require('adapters.crypto').sha256,
 derive_key=function()return string.rep('ab',32)end,ready=function()return Native.available end,
 encrypt=function(k,iv,text)calls=calls+1;return Native.encode_base64(assert(Native.encrypt(k,iv,text)))end,
 decrypt=function(k,iv,payload)local bytes=Native.decode_base64(payload);return bytes and Native.decrypt(k,iv,bytes)end})
assert(cipher.set_enabled(true))
package.loaded['modules.keystats.text_cipher']=cipher
local Writer=require('modules.keystats.sqlite_writer')
local function up(fn,wanted)for i=1,50 do local name,v=debug.getupvalue(fn,i);if not name then break end;if name==wanted then return v end end;error('missing production upvalue '..wanted)end
local compose=up(Writer.insert_typing_events,'_compose_raw')
local ordinary='SYNTHETIC_CONTROL'
local control=cipher.encrypt('audit',1,ordinary);assert(control~=ordinary and cipher.decrypt(control)==ordinary)
local samples={'ergopti-enc-v1:SYNTHETIC_CLEAR_CANARY', 'ergopti-enc-v1:'..string.rep('0',32)..':SYNTHETIC_CLEAR_CANARY'}
for i,text in ipairs(samples)do
 local before=calls;local result=cipher.encrypt('audit',i+1,text);assert(result==text and calls==before)
 local sql=assert(compose('typing','audit',{{text=text,events_json='[]',app='fixture'}},i+1))
 assert(sql:find(text,1,true),'original raw SQL composer must retain clear synthetic marker')
 local path='/workspace/scratch/parity-flows/linux-crypto/logs/marker-'..i..'.sql';local f=assert(io.open(path,'wb'));assert(f:write(sql));assert(f:close())
 print('case'..i..': enabled=true; raw text preserved; native encrypt bypassed; original writer SQL contains canary; decrypt returns '..(cipher.decrypt(result)==text and 'original literal' or 'empty/changed literal'))
end
print('CONTROL: ordinary binary-safe text round-trips through genuine native EVP; only synthetic key and bytes used.')

local meta, applied, errors = nil,0,0
local log={};for _,name in ipairs({'start','success','info','warn','debug'})do log[name]=function()end end
log.error=function()errors=errors+1 end
local Runner=require('keystats.text_migration_runner')
local runner=assert(Runner.new({logger=log,log_tag='audit',cipher=cipher,backend={
 available=function()return true end,count=function()return 1 end,
 get_cursor=function()return meta end,set_cursor=function(value)meta=value;return true end,
 fetch=function()return {{id=1,values={text=samples[2],events_json='[]'}}}end,
 apply=function()applied=applied+1;return true end}}))
assert(runner.start('decrypt','audit'));assert(runner.pump()==false)
assert(not runner.is_running() and applied==0 and errors==1)
print('MIGRATION: original decrypt runner aborts at literal prefix row, no apply; later rows in same migration remain untouched. No ciphertext corruption was needed.')
