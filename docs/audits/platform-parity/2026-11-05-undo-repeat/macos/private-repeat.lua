-- Audit-only native-port fixture: execute the existing real-owner privacy fixture prefix,
-- then extend its scenario through the production repeat and remote prediction owners.
local repo = assert(arg[1], 'repository root required')
local driver = repo .. '/static/ergopti_plus/macos'
package.path = driver .. '/?.lua;' .. driver .. '/?/init.lua;' .. driver .. '/tests/stubs/?.lua;' .. repo .. '/static/ergopti_plus/_shared/lua/?.lua;' .. repo .. '/static/ergopti_plus/_shared/lua/?/init.lua;' .. package.path
local file = assert(io.open(driver .. '/tests/unit/modules/keymap/llm_bridge/test_private_expansion_never_prompted.lua', 'rb'))
local source = file:read('*a'); file:close()
local marker = '\nhelpers.describe("a private expansion never reaches an AI prompt (private-ai-context)"'
local stop = assert(source:find(marker, 1, true), 'fixture boundary must exist')
assert(not source:find(marker, stop + 1, true), 'fixture boundary must be unique')
local fixture = assert(load(source:sub(1, stop - 1) .. '\nreturn build_world,expand_private,prompted_text,type_text', '@privacy-fixture-prefix', 't'))
local build, expand, prompt, type_text = fixture()
local world = build()
local records = {}
require('modules.keystats').notify_synthetic = function(text, source_type, deletes, variant, echo, private)
 records[#records + 1] = {text=text,source=source_type,variant=variant,private=private == true}
end
local synthetic = require('adapters.synthetic_input')
synthetic.enter_callback()
expand(world)
local private_consume, private_events = synthetic.leave_callback(true)
assert(private_consume and #private_events > 0)
assert(world.state.buffer:find('2840175123456', 1, true), 'actual private expansion must produce synthetic secret')
assert(records[1].private == true, 'positive privacy propagation control')
assert(world.state.llm_buffer == '', 'private expansion must initially clear AI context')
world.state.is_repeat_feature_enabled = function() return true end
world.state.buffer = world.state.buffer .. '★'
synthetic.enter_callback()
local repeated = world.expander.try_repeat_feature('★', false)
local consume, events = synthetic.leave_callback(repeated)
assert(repeated == true and consume == true and #events == 2, 'production repeat must construct one key pair')
world.bridge.update_preview(world.state.buffer)
assert(records[2].text == '6' and records[2].variant == 'repeat_key' and records[2].private == false)
assert(world.state.llm_buffer == '6', 'secret-derived repeat becomes public AI context')
type_text(world, ' merci pour votre dossier')
local request = assert(prompt(world), 'fake remote transport must capture actual production request')
assert(request:find('6 merci pour votre dossier', 1, true), 'request carries secret-derived repeat')
assert(not request:find('2840175123456', 1, true), 'full-secret baseline remains protected')
print(require('json').encode({private_expansion=records[1],repeat_output=records[2],repeat_events=#events,ai_context=world.state.llm_buffer,remote_includes_repeat=request:find('6 merci pour votre dossier',1,true) ~= nil,full_secret_present=request:find('2840175123456',1,true) ~= nil}))
