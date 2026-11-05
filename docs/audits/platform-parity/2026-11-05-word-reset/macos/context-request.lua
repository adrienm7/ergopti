-- Audit-only corroboration: actual Bridge/PredictionEngine request body through fake HTTP.
-- Public action admission and exact buffer transitions are proved by public-context.lua.
local repo = assert(arg[1], 'repository root required')
local driver = repo .. '/static/ergopti_plus/macos'
package.path = driver .. '/?.lua;' .. driver .. '/?/init.lua;' .. driver .. '/tests/stubs/?.lua;' .. repo .. '/static/ergopti_plus/_shared/lua/?.lua;' .. repo .. '/static/ergopti_plus/_shared/lua/?/init.lua;' .. package.path
local file = assert(io.open(driver .. '/tests/unit/modules/keymap/llm_bridge/test_private_expansion_never_prompted.lua','rb'))
local source = file:read('*a'); file:close()
local marker = '\nhelpers.describe("a private expansion never reaches an AI prompt (private-ai-context)"'
local stop = assert(source:find(marker,1,true), 'fixture boundary must exist')
assert(not source:find(marker,stop+1,true), 'fixture boundary must be unique')
local factory = assert(load(source:sub(1,stop-1) .. '\nreturn build_world,prompted_text,type_text,restore_environment','@request-fixture-prefix','t'))
local build,prompt,type_text,restore = factory()
local BEFORE = 'bonjour ceci est le dossier initial'
local AFTER = ' puis voici la prochaine phrase'
local observations = {}
for _,case in ipairs({
 {reset_ai=false,reset_word=true,expected_old=true},
 {reset_ai=true,reset_word=false,expected_old=false},
 {reset_ai=false,reset_word=false,expected_old=true},
 {reset_ai=true,reset_word=true,expected_old=false},
}) do
 local world = build()
 type_text(world,BEFORE)
 world.bridge.set_llm_reset_on_nav(case.reset_ai)
 if case.reset_word then world.state.buffer='' end
 world.bridge.check_nav_reset()
 assert(world.state.llm_buffer == (case.reset_ai and '' or BEFORE), 'immediate policy baseline')
 type_text(world,AFTER)
 local serialized = assert(prompt(world), 'actual prediction engine must serialize a request to fake HTTP')
 local carries_old = serialized:find(BEFORE,1,true) ~= nil
 assert(carries_old == (not case.reset_word), 'actual request follows hotstring-buffer lifetime')
 observations[#observations+1] = {reset_ai=case.reset_ai,reset_word=case.reset_word,expected_old=case.expected_old,actual_old=carries_old,ai_context=world.state.llm_buffer,policy_holds=carries_old==case.expected_old}
 restore()
end
print(require('json').encode({requests=observations,transport='fake HTTP; no network request',caller_proof='public-context.lua'}))
