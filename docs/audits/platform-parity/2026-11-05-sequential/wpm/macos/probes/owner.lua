local root=assert(arg[1]); local mode=arg[2] or 'all'
local base=root..'/static/ergopti_plus/'
package.path=base..'macos/?.lua;'..base..'macos/?/init.lua;'..base..'_shared/lua/?.lua;'..base..'_shared/lua/?/init.lua;'..package.path
local logs={}; package.loaded['infra.logger']=setmetatable({}, {__index=function(_,level) return function(_,fmt,...) logs[#logs+1]=level..':'..string.format(fmt,...) end end})
package.loaded['infra.paths']={shared=function(p)return base..'_shared/'..p end}
package.loaded['infra.i18n']={get=function()return 'WPM'end}
local codec=require('toml_codec'); local f=assert(io.open(base..'_shared/modules/timings/constants.toml'));local timings=assert(codec.decode(f:read('*a'))); f:close()
package.loaded['infra.timings']={sec=function(g,k)return assert(timings[g][k])/1000 end}
package.loaded.json={encode=function()return '{}'end}
local stats={wpm=0,source='none',source_time=0}; package.loaded['modules.keystats']={get_live_stats=function()return stats end}
package.loaded['ui.tooltip']={is_visible=function()return false end}
package.loaded['modules.hotstrings.hotstrings_config']={resolve=function()return {color='#112233'}end}
local now=100; local screen={x=0,y=0,w=1600,h=1000};local mouse={x=0,y=0};local timers,canvases,items={},{},{}; local settings={};local refuse_canvas=false
hs={settings={get=function(k)return settings[k]end,set=function(k,v)settings[k]=v end,clear=function(k)local yes=settings[k]~=nil;settings[k]=nil;return yes end},
 timer={absoluteTime=function()return now*1e9 end,new=function(delay,fn)local t={fn=fn,on=false};function t:start()self.on=true;return self end;function t:stop()self.on=false;return self end;function t:running()return self.on end;timers[#timers+1]=t;return t end},
 mouse={absolutePosition=function()return mouse end}, screen={mainScreen=function()return {fullFrame=function()return screen end}end},drawing={windowLevels={cursor=1000}},
 eventtap={event={types={mouseMoved=1,leftMouseDown=2,rightMouseDown=3,scrollWheel=4}},new=function(_,fn)local t={on=false,fn=fn};function t:start()self.on=true;return self end;function t:stop()self.on=false;return self end;function t:isEnabled()return self.on end;return t end},
 canvas={windowBehaviors={canJoinAllSpaces=1},windowLevels={floating=3,overlay=4}},
 styledtext={new=function(s,a)return {text=s,attrs=a}end},menubar={new=function()local m={};function m:setTitle(t)self.title=t;return self end;function m:delete()self.deleted=true end;items[#items+1]=m;return m end}}
function hs.canvas.new(frame)
 if refuse_canvas then return nil end
 local c={f=frame,elements={},visible=false,events={false,false,false,false},delivered=0}
 for _,name in ipairs({'behavior','level','ignoresMouseEvents'})do c[name]=function(self)return self end end
 function c:canvasMouseEvents(d,u,e,m)self.events={d,u,e,m};return self end
 function c:mouseCallback(fn)self.callback=fn;return self end
 function c:replaceElements(elements)self.elements=elements;return self end
 function c:frame(f)if f then self.f=f;return self end;return self.f end
 function c:show()self.visible=true;return self end
 function c:hide()self.visible=false;return self end
 function c:delete()self.deleted=true;self.visible=false end
 -- Hammerspoon 1.1.1 libcanvas.m default flags are NO; dispatch requires opt-in.
 function c:receive(event)
  local key=({mouseDown='trackMouseDown',mouseUp='trackMouseUp',mouseMove='trackMouseMove'})[event]
  local idx=({mouseDown=1,mouseUp=2,mouseMove=4})[event];local admitted=self.events[idx]
  for _,e in ipairs(self.elements)do admitted=admitted or e[key]==true end
  if admitted and self.callback then self.delivered=self.delivered+1;self.callback(self,event,1,10,10)end
 end
 canvases[#canvases+1]=c;return c
end
local function tick()now=now+.2;for _,t in ipairs(timers)do if t.on then t.fn()end end end
local widget=require('ui.wpm.wpm_widget');local bar=require('ui.wpm.wpm_menubar')
assert(widget.start(false));assert(#canvases==0);assert(bar.start());assert(#items==0);print('healthy idle startup: no canvas or menubar')
stats={wpm=42,source='manual',source_time=now};tick();local c=assert(canvases[1]);assert(c.visible and #c.elements==4);assert(items[1].title.text:find('42'));print('healthy typing: compact canvas + 42 WPM menubar')
stats={wpm=77,source='hotstring',source_variant='private_synthetic_group',source_time=now};tick();assert(c.elements[1].fillColor.hex=='#112233');assert(items[1].title.attrs.backgroundColor.hex=='#112233');widget.set_use_source_colors(false);bar.set_use_source_colors(false);tick();assert(c.elements[1].fillColor.hex~='#112233' and not items[1].title.attrs.backgroundColor);print('healthy source/color switch: live group override reaches both owners; colors-off neutralizes both')
local x,y=c.f.x,c.f.y; mouse={x=10,y=10};c:receive('mouseDown');mouse={x=100,y=100};c:receive('mouseMove');c:receive('mouseUp');assert(c.delivered==0 and c.f.x==x and c.f.y==y);print('WPMM-001 native admission: 0 delivered callbacks; requested drag leaves coordinates '..x..','..y)
-- Positive seam control proves that the callback and dispatch can actually move.
c:canvasMouseEvents(true,true,false,true);mouse={x=10,y=10};c:receive('mouseDown');mouse={x=100,y=100};c:receive('mouseMove');c:receive('mouseUp');assert(c.delivered==3 and c.f.x==x+90);print('positive admission control: 3 callbacks; actual owner moves +90,+90 and saves')
assert(widget.start(true));assert(#c.elements>=4);local snap=widget.configuration_snapshot();assert(snap.graph and snap.running);assert(widget.stop());assert(widget.resume_after_pause());assert(widget.configuration_snapshot().graph);c=canvases[#canvases];print('healthy pause/resume: graph setting retained, resources reacquired');local cb=c.callback;assert(widget.stop());local before=#canvases;cb(c,'mouseDown');cb(c,'mouseUp');tick();assert(c.deleted and #canvases==before);print('stale closure control: stopped canvas cannot resurrect')
-- Start from normal default, then a real screen topology shrink.
settings={};package.loaded['ui.wpm.wpm_widget']=nil;widget=require('ui.wpm.wpm_widget');assert(widget.start(false));local hot=canvases[#canvases];local oldx=hot.f.x;screen={x=0,y=0,w=800,h=600};local nlogs=#logs;tick();assert(hot.f.x==oldx and hot.f.x>screen.w);print('WPMM-002 display shrink 1600x1000 -> 800x600: still x='..hot.f.x..', y='..hot.f.y..'; entire canvas outside display; new diagnostics='..(#logs-nlogs))
widget.reset_position();tick();assert(hot.f.x<800 and hot.f.y<600);print('reset backstop restores visible geometry '..hot.f.x..','..hot.f.y)
stats={wpm=0,source='none',source_time=0};now=now+10;tick();assert(not hot.visible);assert(items[#items].deleted);print('healthy idle decay: canvas hidden and native menubar item deleted');stats={wpm=42,source='manual',source_time=now};assert(widget.stop());refuse_canvas=true;assert(widget.start(false)==false);assert(not widget.is_running());print('refused canvas control: start false; stopped; diagnostics retained')
assert(bar.stop());print('PASS actual owners: widget, menubar, shared model/canon, graphics adapter, timer adapter, storage adapter; native hs seams only')
for _,l in ipairs(logs)do if l:find('error:')then print(l)end end
