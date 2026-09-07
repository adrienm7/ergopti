-- Run from macos/. Actual discovery, no native/filesystem operations.
local pending, warnings, successes = {}, 0, 0
package.loaded['infra.logger']=setmetatable({
    warn=function() warnings=warnings+1 end,
    info=function() successes=successes+1 end,
}, {__index=function() return function() end end})
package.loaded['infra.i18n']={get=function(key) return key end}
package.loaded['infra.text_utils']={escape_gsub_replacement=function(value) return value end}
package.loaded['adapters.shell_runner']={spawn=function(_,_,done)
    pending[#pending+1]=done
    return {start=function() return true end}
end}
_G.hs={application={infoForBundlePath=function() return {} end},image={}}
local picker=assert(loadfile('infra/app_picker.lua'))()
local first, second
picker.discover_apps(function(choices) first=choices end)
pending[1](1,'/Applications/Partial.app\n')
picker.discover_apps(function(choices) second=choices end)
assert(#pending==1 and first==second and #second==1)
assert(warnings==0 and successes==1)
print('CONFIRMED exit1 partial stdout published and cached: second request launches no scan; warning0 success1')
