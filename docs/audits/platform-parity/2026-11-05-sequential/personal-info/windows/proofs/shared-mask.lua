local root=assert(arg[1])
local shared=root..'/static/ergopti_plus/_shared'
package.path=shared..'/lua/?.lua;'..shared..'/lua/?/init.lua;'..package.path
local Json=require('json')
local Toml=require('toml_codec')
local Mask=require('personal_info.mask')
local function read(p)local f=assert(io.open(p,'r'));local t=f:read('*a');f:close();return t end
local corpus=assert(Json.decode(read(shared..'/tests/corpus/personal_info/mask_vectors.json')))
local declaration=assert(Toml.decode(read(shared..'/modules/personal_info/fields.toml')))
local nfields=0;for _ in pairs(declaration.fields)do nfields=nfields+1 end
assert(nfields==15,'expected actual complete field declaration')
assert(#corpus.vectors>=15 and #corpus.invalid_policies>=4)
for _,v in ipairs(corpus.vectors)do assert(Mask.mask_field(v.value,v.field,declaration)==v.expected,v.id)end
for _,v in ipairs(corpus.invalid_policies)do assert(Mask.mask(v.value,v.policy)==v.expected,v.id)end
assert(Mask.mask_field('SYNTHETIC_123456','unknown',nil)~= 'SYNTHETIC_123456')
assert(Mask.redact_for_log('A😀Z')=='•••','shared codepoint-sized logging redaction')
print('PASS actual shared Lua mask owner + actual TOML policy: '..#corpus.vectors..' vectors, '..#corpus.invalid_policies..' malformed policies, '..nfields..' fields; unknown-declaration and astral redaction controls. Runtime='.._VERSION..' '..(jit and jit.version or 'PUC'))
print('LIMIT: pure shared mask execution only. Not Windows AHK port, editor, typing, logs, clipboard, or native receiving.')
