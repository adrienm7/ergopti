--- tests/unit/ui/test_ui_builder_outer_frame.lua
-- Independent controls frozen before outer-frame normalization.
-- Models native borderless creation, decoration expansion and outer-frame API.
local helpers = require("tests.helpers")
local source, source_error = helpers.read_driver_unit("function M.show_webview(opts)")
assert(source, source_error)
local function eq(actual, expected, why) assert(actual == expected, (why or "value") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected)) end
local function fixture(options)
 options = options or {}
 local state = {current=true, acquired=false, deleted=0, create_calls=0, events={}, frame_calls=0, raw_timers=0, show_calls=0, html_calls=0}
 local requested = {x=101,y=73,w=560,h=520}
 local original = {x=101,y=73,w=560,h=520}
 if options.bad_frame then requested[options.bad_frame.key]=options.bad_frame.value end
 local function mutate_requested() requested.w=999;requested.h=999;requested.x=-99;requested.y=-99 end
 local wv, native = {}, {}
 local function mark(name) state.events[#state.events+1]=name end
 for _,name in ipairs({'windowTitle','shadow','level','allowTextEntry','allowGestures','navigationCallback'}) do
  wv[name]=function(self) mark(name); return self end
 end
 function wv:windowStyle() mark('style'); state.actual.h=state.actual.h+(options.decoration or 24); if options.retire_at_style then state.current=false end; if options.mutate_requested then requested.w=999;requested.h=999;requested.x=-99;requested.y=-99 end; return self end
 function wv:frame(rect)
  if not rect then return state.actual end
  state.frame_calls=state.frame_calls+1;mark('frame');state.acquired_at_frame=state.acquired
  if options.throw_frame then error('modeled frame refusal') end
  state.frame_argument={x=rect.x,y=rect.y,w=rect.w,h=rect.h};state.actual={x=rect.x,y=rect.y,w=rect.w,h=rect.h}
  if options.retire_at_frame then state.current=false end
  return self
 end
 function wv:html() mark('html');state.html_calls=state.html_calls+1;return self end
 function wv:show() mark('show');state.show_calls=state.show_calls+1;return self end
 function wv:delete() state.deleted=state.deleted+1;mark('delete');return self end
 local win={moveToScreen=function() mark('move');return true end,raise=function()mark('raise');return true end,focus=function()mark('focus');return true end}
 function wv:hswindow()return win end
 native.webview={windowMasks={titled=1,closable=2,utility=16},new=function(rect)state.create_calls=state.create_calls+1;state.actual={x=rect.x,y=rect.y,w=rect.w,h=rect.h};mark('create');if options.mutate_constructor then mutate_requested();rect.w=998;rect.h=998 end;return wv end}
 native.drawing={windowLevels={normal=0,floating=1}};native.screen={mainScreen=function()return {}end};native.focus=function()mark('appfocus');return true end
 local deps={['infra.logger']=setmetatable({},{__index=function(_,key)return function()if key=='debug' and options.mutate_logger then mutate_requested()end end end}),['infra.paths']={shared=function()return nil end},['webview.i18n_seed']={},['infra.deferred_work']={after=function()state.raw_timers=state.raw_timers+1;return true end},['adapters.timer_scheduler']={now_ns=function()return 0 end},['adapters.json_codec']={},['window_titles']={compose=function(title)return title end}}
 local env=setmetatable({hs=native,require=function(name)return assert(deps[name],'unexpected dependency '..name)end},{__index=_G})
 local chunk
 if _VERSION=='Lua 5.1' then chunk=assert(loadstring(source, '=outer-frame-source'));setfenv(chunk,env) else chunk=assert(load(source, '=outer-frame-source', 't',env))end
 local builder=chunk()
 local opts={frame=requested,title='modeled public test',html_string='<html></html>',inject_i18n=false,focus=options.focus==true}
 if options.owned then opts.on_webview_created=function(candidate)eq(candidate,wv);state.acquired=true;mark('acquire');if options.mutate_acquire then mutate_requested()end;return true end;opts.is_current=function()return state.current end;opts.schedule_after=function()return true end end
 if not options.nonparticipant then
  opts.normalize_outer_frame=true
  opts.outer_frame_is_current=function()if options.throw_scope then error('modeled session predicate refusal')end;return state.current end
 end
 if options.invalid_marker then opts.normalize_outer_frame=options.invalid_marker.value end
 if options.missing_scope then opts.outer_frame_is_current=nil end
 if options.unpaired_scope then opts.normalize_outer_frame=nil;opts.outer_frame_is_current=function()return state.current end end
 if options.missing_frame then wv.frame=nil end
 local result=builder.show_webview(opts)
 return state,result,wv,original
end
local function check(name, fn) helpers.it(name, fn) end
local function index(s,name)for i,x in ipairs(s.events)do if x==name then return i end end;return math.huge end
for _,decoration in ipairs({24,37})do check('outer frame independent of decoration '..decoration,function()local s,v,w=fixture({decoration=decoration});eq(v,w);eq(s.actual.w,560);eq(s.actual.h,520);eq(s.frame_calls,1)end)end
check('one frame mutation after style before content and show',function()local s=fixture();eq(s.frame_calls,1);assert(index(s,'style')<index(s,'frame'));assert(index(s,'frame')<index(s,'html'));assert(index(s,'frame')<index(s,'show'))end)
check('original requested coordinates and dimensions applied exactly',function()local s=fixture();eq(s.frame_calls,1);for k,v in pairs({x=101,y=73,w=560,h=520})do eq(s.frame_argument[k],v)end end)
check('focused presentation begins after canonical frame',function()local s,v,w=fixture({focus=true});eq(v,w);eq(s.frame_calls,1);assert(index(s,'frame')<index(s,'move'));assert(index(s,'frame')<index(s,'focus'))end)
check('exact caller acquires before normalization',function()local s,v,w=fixture({owned=true});eq(v,w);eq(s.frame_calls,1);eq(s.acquired_at_frame,true);assert(index(s,'acquire')<index(s,'frame'))end)
check('owner retired at style cannot normalize or present',function()local s,v=fixture({owned=true,retire_at_style=true});eq(v,nil);eq(s.frame_calls,0);eq(s.show_calls,0);eq(s.deleted,0)end)
check('owner retired inside normalization cannot load or present',function()local s,v=fixture({owned=true,retire_at_frame=true});eq(s.frame_calls,1);eq(v,nil);eq(s.html_calls,0);eq(s.show_calls,0);eq(s.deleted,0)end)
check('unowned native frame refusal deletes exact candidate',function()local s,v=fixture({throw_frame=true});eq(v,nil);eq(s.frame_calls,1);eq(s.deleted,1);eq(s.show_calls,0)end)
check('owned native frame refusal delegates exact cleanup',function()local s,v=fixture({owned=true,throw_frame=true});eq(v,nil);eq(s.frame_calls,1);eq(s.deleted,0);eq(s.acquired,true);eq(s.show_calls,0)end)
check('missing native frame capability cannot publish unowned candidate',function()local s,v=fixture({missing_frame=true});eq(v,nil);eq(s.deleted,1);eq(s.show_calls,0)end)
check('missing native frame capability cannot publish owned candidate',function()local s,v=fixture({owned=true,missing_frame=true});eq(v,nil);eq(s.deleted,0);eq(s.acquired,true);eq(s.show_calls,0)end)
check('original rectangle survives native style callback alias mutation',function()local s=fixture({mutate_requested=true});eq(s.frame_calls,1);for k,v in pairs({x=101,y=73,w=560,h=520})do eq(s.frame_argument[k],v)end end)
check('normalization introduces no timer or retry',function()local s=fixture({owned=true});eq(s.frame_calls,1);eq(s.raw_timers,0);eq(s.show_calls,1)end)

check('constructor alias mutation cannot recut original frame',function()local s,v,w=fixture({mutate_constructor=true});eq(v,w);eq(s.frame_calls,1);for k,n in pairs({x=101,y=73,w=560,h=520})do eq(s.frame_argument[k],n)end end)
check('ownership callback alias mutation cannot recut original frame',function()local s,v,w=fixture({owned=true,mutate_acquire=true});eq(v,w);eq(s.frame_calls,1);for k,n in pairs({x=101,y=73,w=560,h=520})do eq(s.frame_argument[k],n)end end)
check('logger callback alias mutation cannot recut original frame',function()local s,v,w=fixture({mutate_logger=true});eq(v,w);eq(s.frame_calls,1);for k,n in pairs({x=101,y=73,w=560,h=520})do eq(s.frame_argument[k],n)end end)
check('nonparticipant preserves legacy decorated geometry',function()local s,v,w=fixture({nonparticipant=true});eq(v,w);eq(s.frame_calls,0);eq(s.actual.h,544);eq(s.show_calls,1)end)
check('false marker refuses before allocation',function()local s,v=fixture({invalid_marker={value=false}});eq(v,nil);eq(s.create_calls,0);eq(s.frame_calls,0)end)
check('string marker refuses before allocation',function()local s,v=fixture({invalid_marker={value='true'}});eq(v,nil);eq(s.create_calls,0);eq(s.frame_calls,0)end)
check('participant missing session predicate refuses before allocation',function()local s,v=fixture({missing_scope=true});eq(v,nil);eq(s.create_calls,0);eq(s.frame_calls,0)end)
check('session predicate without marker refuses before allocation',function()local s,v=fixture({unpaired_scope=true});eq(v,nil);eq(s.create_calls,0);eq(s.frame_calls,0)end)
check('permission session retired before frame refuses and cleans exact candidate',function()local s,v=fixture({retire_at_style=true});eq(v,nil);eq(s.frame_calls,0);eq(s.deleted,1);eq(s.show_calls,0)end)
check('permission session retired inside frame refuses and cleans exact candidate',function()local s,v=fixture({retire_at_frame=true});eq(v,nil);eq(s.frame_calls,1);eq(s.deleted,1);eq(s.html_calls,0);eq(s.show_calls,0)end)
check('throwing exact session predicate cannot publish',function()local s,v=fixture({throw_scope=true});eq(v,nil);eq(s.frame_calls,0);eq(s.deleted,1);eq(s.show_calls,0)end)
check('nonfinite coordinate refuses before allocation',function()local s,v=fixture({bad_frame={key='x',value=math.huge}});eq(v,nil);eq(s.create_calls,0)end)
check('NaN dimension refuses before allocation',function()local s,v=fixture({bad_frame={key='h',value=0/0}});eq(v,nil);eq(s.create_calls,0)end)
check('nonpositive dimension refuses before allocation',function()local s,v=fixture({bad_frame={key='w',value=0}});eq(v,nil);eq(s.create_calls,0)end)
