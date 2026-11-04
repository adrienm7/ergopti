local root = '/workspace/ergopti/static/ergopti_plus/'
package.path = root..'macos/?.lua;'..root..'macos/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..root..'macos/tests/stubs/?.lua;'..package.path
local helpers=require('tests.helpers')
local SharedParser=require('llm.parser')
local function pred(text) return {to_type=text,deletes=0,chunks={},nw=text} end
package.loaded['modules.llm.parser']={new_thinking_filter=SharedParser.new_thinking_filter,process_prediction=function(_,_,raw)return pred(raw)end}
local Handler=helpers.load_with_stubs('modules.llm.streaming_handler',{
 application={frontmostApplication=function()return {title=function()return 'Fixture' end}end}})
local warnings={}
package.loaded['infra.logger'].warn=function(_,fmt,...)warnings[#warnings+1]=string.format(fmt,...)end
local renders={}
local tooltip={show_predictions=function(preds,_,_,_,_,_,_,_,loading)
 renders[#renders+1]={partial=loading=='…',text=preds[#preds].to_type}; return true end,
 get_current_index=function()return 1 end,make_diff_styled=function()return true end,
 tint=function()return {}end,mark_chain_complete=function()return true end}
assert(Handler.init({core_llm={get_active_profile=function()return {}end,get_current_model=function()return 'm'end},
 tooltip=tooltip,keystats={log_llm=function()end,log_llm_suggested=function()end}}))
local partial,success,fail=Handler.build_callbacks({buffer='context',tail='',my_fetch_id=1,get_fetch_id=function()return 1 end,
 is_streaming_enabled=true,is_streaming_multi_enabled=true,num_predictions=2,show_info_bar=false,
 prediction_indent=0,validation_mods={'none'},navigation_mods={},model_to_use='m',llm_display_name='m',
 is_noise_pred=function()return false end,reset_llm_dismiss_timer=function()return true end,
 pending_predictions_ref={value={}},predictions_visible_ref={value=false},is_ai_preview_enabled=true})
-- Real MLX sequential strategy; fake post functions stand at the transport/response seam.
package.loaded['modules.llm.api_mlx_fetch']=nil
package.loaded['modules.llm.api_common']={DEFAULT_TEMPERATURE=.5,get_retry_policy=function()return 2,.18,5 end,
 new_dedup_stats=function()return {}end,get_diversity_temperature=function(base)return base end,
 insert_prediction=function(results,p)results[#results+1]=p;return true end,log_prediction_summary=function()end,
 protected_call=function(cb,_,...)if cb then return cb(...)end end}
package.loaded['modules.llm.profiles']={resolve_system_prompt=function()return 'system'end}
local Fetch=require('modules.llm.api_mlx_fetch')
local calls=0
local mode=arg[1] or 'independent'
local function stream(...)
 local a={...};calls=calls+1
 local raw=calls==1 and 'first independent completion' or (mode=='cumulative' and 'first independent completion plus' or 'second independent completion')
 a[12](raw)
 if mode=='retry' and calls==1 then a[10]();return end
 a[9]({pred(raw)})
end
Fetch.init({post_and_parse=function()error('unexpected plain')end,post_and_parse_streaming=stream,dedup_enabled=false})
Fetch.fetch_sequential('context','','m',.5,30,mode=='retry' and 1 or 2,{},success,fail,function()return 1 end,true,partial)
local interim=0
for _,r in ipairs(renders)do if r.partial then interim=interim+1;print('interim render: '..r.text)end end
for _,w in ipairs(warnings)do print('warning: '..w)end
print('transport streams='..calls..' interim renders='..interim..' final candidate render='..renders[#renders].text)
if mode=='cumulative' then
 assert(calls==2 and interim==2 and #warnings==0,'same-prefix control must render twice')
else
 assert(calls==2 and interim==1 and #warnings==1,'current defect changed; re-evaluate')
 assert(warnings[1]:find('cumulative-prefix',1,true))
end
