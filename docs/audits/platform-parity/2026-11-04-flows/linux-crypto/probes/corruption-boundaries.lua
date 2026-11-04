local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('compat.utf8').install();require('tests.helpers')
local N=require('infra.openssl_cipher');assert(N.available)
local key,iv=string.rep('ab',32),string.rep('00',16)
local text='A_SYNTHETIC_ONLY\0'..string.rep('data',9)..'\n'
local encrypted=assert(N.encrypt(key,iv,text));assert(N.decrypt(key,iv,encrypted)==text)
for _,row in ipairs({{name='wrong_key',key=string.rep('cd',32),iv=iv,bytes=encrypted},
 {name='truncated_block',key=key,iv=iv,bytes=encrypted:sub(1,-2)},
 {name='empty_cipher',key=key,iv=iv,bytes=''},
 {name='invalid_key',key='xx',iv=iv,bytes=encrypted}})do
 local value,reason=N.decrypt(row.key,row.iv,row.bytes);assert(value==nil and type(reason)=='string');print('REFUSED '..row.name)
end
for _,encoded in ipairs({'AA=A','AAAA=','A===','AA A','AB=='})do assert(N.decode_base64(encoded)==nil)end
local changed=assert(N.decrypt(key,'01'..iv:sub(3),encrypted));assert(changed=='@'..text:sub(2))
print('OBSERVED CBC integrity limit: one-bit IV change passes EVP padding and changes only first plaintext byte; no authentication promised by v1 format.')
for _,value in ipairs({'','\0','a\0b\n',string.rep('x',65536)})do assert(N.decode_base64(assert(N.encode_base64(value)))==value)end
collectgarbage('collect');print('PASS native refusal, canonical Base64 and binary/64KiB round-trip controls; no real password or key files used.')
