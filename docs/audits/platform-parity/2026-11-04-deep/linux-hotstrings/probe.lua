local root = '/workspace/ergopti/static/ergopti_plus/'
package.path = root .. '_shared/lua/?.lua;' .. root .. '_shared/lua/?/init.lua;' .. root .. 'linux/?.lua;' .. package.path
package.loaded['logger.shim'] = setmetatable({}, { __index = function() return function() end end })
package.loaded['infra.hotstring_preferences'] = { get = function() return true end, set = function() return true end }
package.loaded['modules.dynamic_hotstrings.user_code'] = {
    invalidate = function() return true end, is_enabled = function() return false end,
    count = function() return 0 end, preview = function() return nil end, request = function() return false end,
}
package.loaded['infra.config_paths'] = { home = function() return '/workspace/scratch/deep-parity/linux-hotstrings' end }
local dir = '/workspace/scratch/deep-parity/linux-hotstrings/'
local f = assert(io.open(dir .. 'personal_info.toml', 'w'))
f:write('[info]\nfirst_name = "Ada"\nlast_name = "Lovelace"\n[letters]\np = "first_name"\nn = "last_name"\n')
f:close()
local dynamic = require('modules.dynamic_hotstrings.manager')
assert(dynamic.init({ trigger_char = '★', personal_info_path = dir .. 'personal_info.toml' }))
assert(dynamic.set_enabled(true))
local Core = require('hotstring_engine')
for _, text in ipairs({'@p', '@pn', 'td', 'dt', 'date'}) do
    local engine = Core.new()
    assert(engine:load_mappings(dynamic.prefix_mappings()))
    for _, cp in utf8.codes(text) do engine:on_char(utf8.char(cp)) end
    local static = engine:candidates(20)
    local extra = dynamic.preview_candidates(engine:current_buffer(), engine:buffer_starts_at_word_boundary())
    print('PRODUCTION_PREVIEW', text, 'static=' .. #static, 'extra=' .. #extra,
        'resolves=' .. tostring(dynamic.preview(text .. '★', true) ~= nil))
    if text == '@pn' then assert(#extra == 1) else assert(#static + #extra == 0) end
end
-- Execute the actual daemon show/metrics fragment with a renderer refusal.
local sourcefile = assert(io.open(root .. 'linux/ergopti_hotstrings.lua', 'r'))
local source = sourcefile:read('*a'); sourcefile:close()
local start = assert(source:find('tooltip_preview.show(candidates, kind)', 1, true))
local finish = assert(source:find('\n\t\t\tend)', start, true))
local fragment = source:sub(start, finish - 1)
local records = 0
local env = { tooltip_preview = { show = function() return false end },
    candidates = {{ trigger = 'offer' }}, kind = 'autocorrect', type = type, tostring = tostring,
    app_id = 'fixture', now_ms = 1, keystats = { record_suggestion = function() records = records + 1 end } }
assert(load(fragment, '@actual-daemon-preview-metrics-fragment', 't', env))()
print('REFUSED_PREVIEW', 'suggestions=' .. records)
assert(records == 1)
-- A slow completing key is still before the default three-second idle reset.
local engine = Core.new()
assert(engine:load_mappings({}))
engine:on_char('t', { typed_at_ms = 0 })
engine:on_char('d', { typed_at_ms = 10 })
engine:on_char('★', { typed_at_ms = 1010 })
local injections = 0
package.loaded['modules.hotstrings.injector'] = { inject = function()
    injections = injections + 1
    return { ok = true }
end }
local publication = { current = function() return true end, cached = function() return true end }
local ordinary_allowed = Core.within_expansion_delay({ expander_gap_ms = 1000 }, 0.01, 1, 1)
local fired = dynamic.on_trigger(engine:current_buffer(), '★', true, publication)
print('DYNAMIC_DELAY', 'gap_ms=1000', 'configured_seconds=0.01',
    'ordinary_allowed=' .. tostring(ordinary_allowed), 'dynamic_fired=' .. tostring(fired), 'injections=' .. injections)
assert(not ordinary_allowed and fired and injections == 1)
