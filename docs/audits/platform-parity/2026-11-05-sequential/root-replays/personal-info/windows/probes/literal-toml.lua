local root=assert(arg[1]);local fixture=assert(arg[2])
package.path=root..'/static/ergopti_plus/_shared/lua/?.lua;'..root..'/static/ergopti_plus/_shared/lua/?/init.lua;'..package.path
local Codec=require('toml_codec')
for _,kind in ipairs({'double','literal','quoted-key'})do
 local f=assert(io.open(fixture..'/reader-'..kind..'.toml','r'));local raw=f:read('*a');f:close()
 local parsed=assert(Codec.decode(raw),kind..' must be valid TOML')
 assert(parsed.info.first_name=='SYNTHETIC',kind..' decodes actual known field')
 assert(parsed.letters.p=='first_name',kind..' decodes actual alias')
end
print('PASS actual shared TOML codec: 3 syntactically distinct private sources decode identical known personal-info field and alias. Runtime='.._VERSION..' '..(jit and jit.version or 'PUC'))
print('LIMIT: pure codec oracle; no AutoHotkey parser, editor save or typing execution. Windows consequence remains source-derived.')
