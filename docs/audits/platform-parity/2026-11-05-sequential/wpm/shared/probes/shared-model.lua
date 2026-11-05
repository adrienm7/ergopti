local root = assert(arg[1], 'pass pinned worktree')
package.path = root .. '/static/ergopti_plus/_shared/lua/?.lua;' .. root .. '/static/ergopti_plus/_shared/lua/?/init.lua;' .. package.path
local Model, Live, Codec = require('wpm_widget.model'), require('keystats.live_wpm'), require('toml_codec')
local canon = assert(Model.load(root .. '/static/ergopti_plus/_shared/modules/wpm_widget/constants.toml', Codec.decode))
local fh = assert(io.open(root .. '/static/ergopti_plus/_shared/modules/timings/constants.toml'))
local timings = Codec.decode(fh:read('*a')); fh:close()
local k, u = timings.keystats, timings.ui
local n = 0
local function eq(name, actual, expected)
  n = n + 1; assert(actual == expected, name .. ': ' .. tostring(actual) .. ' ~= ' .. tostring(expected))
  print('CONTROL ' .. name .. ' actual=' .. tostring(actual))
end
local function tracker() return Live.new{window_ms=k.wpm_window_ms,min_duration_ms=k.wpm_min_duration_ms,idle_reset_ms=k.wpm_idle_reset_ms} end
local t = tracker()
eq('empty', Live.stats(t, 10000).wpm, 0)
Live.record(t, 1, 10000); eq('one-character', Live.stats(t, 10000).wpm, 0)
Live.record(t, 9, 10000); eq('ten-character-burst-minimum-duration', Live.stats(t, 10000).wpm, 60)
eq('decay-at-two-seconds', Live.stats(t, 12000).wpm, 60)
eq('decay-at-four-seconds', Live.stats(t, 14000).wpm, 30)
eq('idle-exact-boundary-is-live', Live.stats(t, 15000).wpm, 24)
eq('idle-after-five-seconds', Live.stats(t, 15001).wpm, 0)
Live.stats(t, 25000); eq('window-exact-boundary-kept', #t.stamps, 10)
Live.stats(t, 25001); eq('window-old-stamps-pruned', #t.stamps, 0)
Live.mark_source(t, 'hotstring', 'magickey', 10000)
local stats = Live.stats(t, 11000)
eq('source-time-seconds', stats.source_time, 10)
eq('variant-is-group', Model.active_source(stats, 1, 11), 'magickey')
eq('hold-exact-boundary', Model.active_source(stats, 1, 11), 'magickey')
eq('hold-expired', Model.active_source(stats, 1, 11.001), 'none')
for _, source in ipairs{'none','manual','hotstring','repeat_key','rolls'} do eq('neutral-'..source, Model.source_hex(canon,source), canon.colors.bg_manual) end
eq('AI-source',Model.source_hex(canon,'llm'),canon.colors.bg_ai)
eq('group-override',Model.source_hex(canon,'magickey',function(group) eq('resolver-receives-group',group,'magickey'); return 'FF8800' end),'#ff8800')
eq('group-invalid-fallback',Model.source_hex(canon,'magickey',function() return 'bad' end),canon.colors.fallback_accent)
eq('group-throw-fallback',Model.source_hex(canon,'magickey',function() error('synthetic refusal') end),canon.colors.fallback_accent)
eq('strip-rounding',Model.darken_hex('#0055cc',0.4),'#002252')
local broken=assert(Model.load(root .. '/static/ergopti_plus/_shared/modules/wpm_widget/constants.toml',Codec.decode))
broken.graph.scale_max=nil; eq('missing-required-key-refused',Model.validate(broken),nil)
broken=assert(Model.load(root .. '/static/ergopti_plus/_shared/modules/wpm_widget/constants.toml',Codec.decode))
broken.colors.bg_ai='purple'; eq('invalid-colour-refused',Model.validate(broken),nil)
eq('missing-canon-file-refused',Model.load('/private/synthetic/nonexistent/canon.toml',Codec.decode),nil)
eq('decoder-throw-refused',Model.load(root .. '/static/ergopti_plus/_shared/modules/wpm_widget/constants.toml',function() error('synthetic decode refusal') end),nil)
local opts={now_s=10,hold_s=1,use_colors=false,unit='MPM'}
local s={wpm=60,source='llm',source_variant='llm',source_time=10}
eq('colours-off-manual-fill',Model.compact_frame(canon,s,opts).background,canon.colors.bg_manual)
eq('localized-unit',Model.compact_frame(canon,s,opts).unit,'MPM')
eq('localized-label',Model.menubar_frame(canon,s,opts).label,'60 MPM')
eq('menubar-uncoloured-background',Model.menubar_frame(canon,s,opts).background,nil)
local history={}; for i=1,65 do Model.push_history(canon,history,i,'manual') end
eq('history-bound',#history,60); eq('history-oldest',history[1].wpm,6)
local frame=Model.graph_frame(canon,{{wpm=0},{wpm=240}},s,opts)
eq('graph-high-clipped',frame.points[2].y,23)
local x,y=Model.default_anchor(canon,{x=-1920,y=0,w=1920,h=1080})
eq('negative-monitor-anchor-x',x,-85); eq('full-screen-anchor-y',y,1007)
local gx,gy=Model.frame_origin(canon,frame,x,y)
local ax,ay=Model.anchor_from_origin(canon,frame,gx,gy)
eq('graph-anchor-roundtrip-x',ax,x); eq('graph-anchor-roundtrip-y',ay,y)
eq('menubar-empty-hide',Model.menubar_visible({wpm=0},'none',false),false)
eq('menubar-preview-show',Model.menubar_visible({wpm=0},'none',true),true)
eq('widget-never-active-hide',Model.widget_visible{wpm=0,source='none',now_s=10,idle_hide_s=3},false)
eq('widget-idle-hide',Model.widget_visible{wpm=0,source='none',now_s=13,last_active_s=10,last_mouse_s=0,idle_hide_s=3},false)
eq('widget-zero-speed-new-mouse-hide',Model.widget_visible{wpm=0,source='none',now_s=11,last_active_s=10,last_mouse_s=10.5,idle_hide_s=3},false)
eq('widget-preview-survives-mouse',Model.widget_visible{wpm=0,source='none',tooltip_visible=true,now_s=11,last_active_s=10,last_mouse_s=10.5,idle_hide_s=3},true)
-- Real producer -> model: ten characters at 10s, mouse after the last key.
local live=tracker(); Live.record(live,10,10000)
local last=10
for _, now in ipairs{10.2,10.4,11,13.2,14.8,15.2,17.6,17.8} do
  local st=Live.stats(live,now*1000)
  local show; show,last=Model.widget_visible{wpm=st.wpm,source='none',tooltip_visible=false,now_s=now,last_active_s=last,last_mouse_s=10.1,idle_hide_s=u.wpm_widget_idle_hide_ms/1000}
  print(string.format('TRACE now=%.1f actual-wpm=%d mouse-after-key=10.1 show=%s last_active=%.1f',now,st.wpm,tostring(show),last))
  if now==10.2 then eq('DISCREPANCY-observation-new-mouse-cannot-hide-positive-wpm',show,true); print('POLICY_DISCREPANCY H-WPMS-001 mouse after last key: declaration and Windows counterpart imply show=false; actual Lua show=true; user-facing intent unconfirmed') end
end
-- Missing non-required neutral keys: characterize only, no shipped-file defect claim.
canon.neutral_sources.rolls=nil
local accepted=Model.validate(canon)
eq('LIMIT-missing-rolls-key-accepted',accepted~=nil,true)
print('TOTAL observation assertions='..n..' observed policy discrepancies=1; confirmed findings=0; model execution only, no native desktop receiving')
