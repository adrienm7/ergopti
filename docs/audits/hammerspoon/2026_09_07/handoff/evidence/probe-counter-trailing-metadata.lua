-- Run from macos/. Real counter, canonical reader and registry; fixture-only I/O.
package.path='./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;'..package.path
local helpers=require('tests.helpers')
local Registry=helpers.load_with_stubs('modules.keymap.registry')
require('tests.support.hotstring_counter_fixture')(function(counter, fixture, ctx)
    fixture.content='[[section]]\n"a" = { output = "b" }\n[_meta.sections]\n"section" = "Section description"\n'
    local counted=counter.count_all(ctx, {}).ext
    package.loaded['infra.toml.reader']=require('toml_codec.reader')
    local state={groups={},mappings={},mappings_lookup={},mappings_by_tail_char={},
        mappings_by_star_tail_char={},SECTION_DELAYS={},recompute_word_timeout=function() end,
        seq_counter=0,magic_key='*'}
    assert(Registry.init(state)==true)
    assert(Registry.load_toml('fixture', '/virtual/fixture.toml')==true)
    local sections=state.groups.fixture.sections
    assert(#sections==1 and sections[1].count==1)
    assert(counted==2)
    print('CONFIRMED trailing metadata: counter='..counted..', registry logical entries='..sections[1].count)
end)
