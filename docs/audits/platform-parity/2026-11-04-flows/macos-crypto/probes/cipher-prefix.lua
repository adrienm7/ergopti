-- Real macOS cipher + real SQL writer; only native Shell/hash/JSON ports record synthetic fixtures.
local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'macos/?.lua;'..root..'macos/?/init.lua;'..root..'_shared/lua/?.lua;'..package.path
local calls={derive=0,encrypt=0,decrypt=0,hash=0}
local noop=function() end
package.loaded['infra.logger']=setmetatable({},{__index=function() return noop end})
package.loaded['infra.paths']={shared=function(path) return root..'_shared/'..path end}
package.loaded['hs.fs']={};package.loaded['hs.sqlite3']={}
package.loaded['hs.json']={encode=function(v) assert(type(v)=='table');return '[]' end}
_G.hs={}
package.loaded['adapters.crypto']={sha256=function() calls.hash=calls.hash+1;return string.rep('a',64) end}
package.loaded['adapters.shell_runner']={
 exec=function() return 'FIXTURE-MACHINE-ID' end,
 exec_private_stdin=function(cmd,input)
  if cmd:find('-pbkdf2',1,true) then calls.derive=calls.derive+1;return 'key='..string.rep('ab',32)..'\n' end
  calls.encrypt=calls.encrypt+1;return 'RklYVFVSRQ==\n'
 end,
 exact_stdin_pipeline=function(cmd,input) calls.decrypt=calls.decrypt+1;return cmd end,
 exec_checked=function() return 'DECODED-FIXTURE' end,
}
local Cipher=require('modules.keystats.text_cipher');Cipher.set_enabled(true)
local Writer=require('modules.keystats.sqlite_writer')
Writer.init{paths={},device_obj={},device_id='fixture-mac'}
local cases={'ordinary synthetic fixture','ergopti-enc-v1:SENTINEL-PRIVATE-CONTENT','ergopti-enc-v1:'..string.rep('c',32)..':RklYVFVSRQ=='}
for index,text in ipairs(cases) do
 local before=calls.encrypt
 local sql=Writer.build_inserts{type='typing',timestamp='2026-11-04 12:00:00.000',text=text,events={}}
 assert(#sql==1)
 local retained=sql[1]:find(text,1,true)~=nil
 if index==1 then assert(not retained and calls.encrypt-before==2) else assert(retained and calls.encrypt-before==1) end
 print(('case=%d literal_text_in_SQL=%s primitive_encrypt_calls=%d decrypted_text=%s'):format(index,tostring(retained),calls.encrypt-before,Cipher.decrypt(text)))
end
assert(calls.derive==1)
print('Actual raw typing SQL path verified; no DB/keychain/files/user secrets accessed; crypto ports synthetic.')
