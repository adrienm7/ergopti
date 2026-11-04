local base='/workspace/ergopti/static/ergopti_plus/'
package.path=base..'linux/?.lua;'..base..'linux/?/init.lua;'..base..'_shared/lua/?.lua;'..base..'_shared/lua/?/init.lua;'..package.path
local path=base..'linux/tests/unit/modules/llm/features/test_translate_selection.lua'
local f=assert(io.open(path,'r')); local source=f:read('*a'); f:close()
local start=assert(source:find('helpers.describe(',1,true))
local scenario=assert(load(source:sub(1,start-1)..'\nreturn scenario', '@actual-translation-harness'))()
scenario({selection='A selected sentence'},function(world)
    assert(world.engine.translate_selection('fr'))
    assert(#world.posts==1)
    package.loaded['adapters.http_client'].cancel=function() return false end
    assert(world.engine.translate_selection('fr'))
    assert(#world.posts==1,'new request cannot dispatch while original cancellation refused')
    world.respond(1,'TRANSLATION: original reply')
    print('REFUSED_TRANSLATION','posts='..#world.posts,'predicting='..tostring(world.engine.is_predicting()),
        'loading='..tostring(world.shown and world.shown.meta.loading),'offers='..#world.engine.get_suggestions())
    assert(world.engine.is_predicting() and world.shown.meta.loading and #world.engine.get_suggestions()==0)
    -- Restore boundary before scenario-owned teardown.
    package.loaded['adapters.http_client'].cancel=function() return true end
end)
