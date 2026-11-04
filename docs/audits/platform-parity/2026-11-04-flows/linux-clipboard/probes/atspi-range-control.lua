local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
if not utf8 then require('compat.utf8').install() end
require('tests.helpers')
require('tests.support.adapters.synthetic_input.selection_write_fixture').with(function(state,owner)
    local token=state.read()
    state.selection={first=7,last=12,text='other'}
    local committed,result=state.staged(token,'SOURCE')
    print('ATSPI_RANGE_CONTROL','committed='..tostring(committed),'emits='..state.emits,
        'payload_written='..tostring(result and result.payload_written),'settled='..tostring(owner.is_settled()))
    assert(not committed and state.emits==0 and result.payload_written==false and owner.is_settled())
end)
