--- docs/audits/platform-parity/2026-11-04/hotstrings-probe.lua

--- MODULE: Dynamic Hotstring Parity Reproduction
--- Runs pure production matching logic with synthetic personal data and no input injection.

local base = assert(arg[1], 'Pass the repository root as the first argument') .. '/static/ergopti_plus/'
package.path=base..'_shared/lua/?.lua;'..base..'_shared/lua/?/init.lua;'..base..'linux/?.lua;'..package.path
package.loaded['logger.shim']=setmetatable({}, {__index=function() return function() end end})
local prefix=require('modules.dynamic_hotstrings.prefix_rules')
local rows=prefix.build({phone_number='0612345678'})
for _,r in ipairs(rows) do print('PREFIX',r.trigger,r.replacement,'auto='..tostring(r.auto_expand)) end
local engine=require('hotstring_engine').new()
engine:load_mappings(rows)
for c in ('0612'):gmatch('.') do local result=engine:on_char(c); if result then print('ENGINE', c, result.trigger, result.replacement) end end
local dyn=require('dynamic_hotstrings')
dyn.register_date_rules('★')
for _,word in ipairs({'td','@td','xtd','word@td'}) do
 local match=dyn.match_buffer(word,'dynamichotstrings',function() return true end,true)
 print('DATE',word, match and match.rule.suffix or 'NO MATCH')
end
