local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'macos/?.lua;'..root..'macos/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
_G.hs=require('tests.stubs.hs')
local Text=require('tests.helpers').load_with_stubs('modules.shortcuts.actions.text')
local cases={decomposed_latin=utf8.char(0x65,0x301),hangul_jamo=utf8.char(0x1100,0x1161),devanagari_vowel=utf8.char(0x915,0x93e),emoji_modifier=utf8.char(0x1f44d,0x1f3fd),flag=utf8.char(0x1f1eb,0x1f1f7)}
for name,text in pairs(cases)do print(name..' codepoints='..utf8.len(text)..' current_cursor_steps='..Text._cursor_steps(text))end
assert(Text._cursor_steps(cases.decomposed_latin)==1)
assert(Text._cursor_steps(cases.emoji_modifier)==1 and Text._cursor_steps(cases.flag)==1)
print('LIMIT: no native application caret navigation executed; Hangul/Indic behavior remains a qualification question')
