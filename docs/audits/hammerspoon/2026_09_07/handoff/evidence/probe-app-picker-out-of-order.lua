-- Run from macos/. Actual picker; native/process boundaries are virtual.
local pending, choosers, applied = {}, {}, {}
package.loaded['infra.logger']=setmetatable({}, {__index=function() return function() end end})
package.loaded['infra.i18n']={get=function(key) return key end}
package.loaded['infra.text_utils']={escape_gsub_replacement=function(value) return value end}
package.loaded['adapters.shell_runner']={spawn=function(_,_,done)
    pending[#pending+1]=done
    return {start=function() return true end}
end}
_G.hs={timer={absoluteTime=function() return 0 end},
    application={frontmostApplication=function() return nil end,infoForBundlePath=function() return {} end},
    image={imageFromAppBundle=function() return nil end},chooser={new=function(done)
        local chooser={done=done,deleted=false}
        for _,name in ipairs({'placeholderText','choices','bgDark','show'}) do chooser[name]=function(self) return self end end
        chooser.delete=function(self) self.deleted=true end
        choosers[#choosers+1]=chooser
        return chooser
    end}}
local picker=assert(loadfile('infra/app_picker.lua'))()
picker.build_menu({},function() applied[#applied+1]='A' end)[1].action()
picker.build_menu({},function() applied[#applied+1]='B' end)[1].action()
assert(#pending==2)
pending[2](0,'/Applications/B.app\n')
pending[1](0,'/Applications/A.app\n')
assert(choosers[1].deleted and not choosers[2].deleted)
choosers[2].done({text='A',appPath='/Applications/A.app'})
assert(applied[1]=='A')
print('CONFIRMED older scan A deletes newer chooser B and sends selection to obsolete A settings callback')
