local root, artifacts=assert(arg[1],'source root required'),assert(arg[2],'artifact root required')
local mac=root..'/static/ergopti_plus/macos'
local shared=root..'/static/ergopti_plus/_shared/lua'
package.path=mac..'/?.lua;'..mac..'/?/init.lua;'..mac..'/tests/stubs/?.lua;'..shared..'/?.lua;'..shared..'/?/init.lua;'..package.path
local helpers=require('tests.helpers')
local Logger=helpers.load_with_stubs('infra.logger')
local uv=require('luv')
local dir=artifacts..'/logs/crash-fixture/'
assert(uv.fs_mkdir(dir,448) or uv.fs_stat(dir))
Logger.crash_reports_dir=function()return dir end
local lines={}
Logger.set_sink(function(line)lines[#lines+1]=line end)
local canary='sk-SYNTHETIC_MDG_CANARY_20261105'
local private='/Users/PrivateUser/PrivateConfig/PrivatePack.toml'
Logger.follow_config_dir('/Users/PrivateUser/PrivateConfig')
Logger.error('synthetic_probe','Failure '..canary..' at '..private)
local sanitized=Logger.redact_message('Failure '..canary..' at '..private)
assert(not sanitized:find(canary,1,true) and not sanitized:find('PrivateUser',1,true))
package.loaded['modules.updater']={current_version=function()return '1.2.3' end}
package.loaded['infra.diagnostic_snapshot']={resolve_commit=function()return '3aaaae7','build' end}
package.loaded['infra.config_paths']={is_initialized=function()return true end,get_config_dir=function()return '/Users/PrivateUser/PrivateConfig' end}
package.loaded['infra.i18n']={get=function(k)return k end}
package.loaded['infra.fs_dir']={try_entries=function()return {},true end}
local mode='healthy';local native_calls=0
package.loaded['adapters.file_system']={create_if_absent=function(path,content)
  native_calls=native_calls+1
  if mode=='false' then return false,'error','synthetic write refused' end
  if mode=='throw' then error('synthetic write raised') end
  local fd,detail,errno=uv.fs_open(path,193,384)
  if not fd then return false,errno=='EEXIST' and 'exists' or 'error',detail end
  local wrote,werr=uv.fs_write(fd,content,0);local closed,cerr=uv.fs_close(fd)
  if wrote~=#content or closed~=true then return false,'error',werr or cerr end
  return true,'created'
end}
hs.fs.attributes=function()return {mode='directory'}end
hs.fs.mkdir=function()error('unexpected mkdir')end
package.loaded['modules.diagnostics.crash_reporter']=nil
local Reporter=require('modules.diagnostics.crash_reporter')
local report=Reporter.report('Failure '..canary..' at '..private..'\ntrace '..canary,{stack='trace '..canary})
assert(report.error_msg:find(canary,1,true))
local path=assert(Reporter.save(report))
local file=assert(io.open(path,'rb'));local saved=assert(file:read('*a'));assert(file:close())
assert(saved:find(canary,1,true) and saved:find('PrivateUser',1,true))
assert(not sanitized:find(canary,1,true),'canonical redactor healthy control')
print('actual_report_and_save: canary_in_error=true canary_in_stack=true private_account_in_saved_json=true')
print('healthy_control: canonical_redactor_removes_canary=true ordinary_log_line_printed_redacted=true')
for _,failure in ipairs({'false','throw'})do
 mode=failure
 assert(Reporter.save(report)==nil)
 print('persistence_'..failure..': returned_nil=true')
end
assert(native_calls>=3)
assert(uv.fs_unlink(path))
print('native_port: actual_Linux_libuv_exclusive_create_write_close=true files_removed=true Darwin_adapter_not_executed=true')
local Json=require('json')
local function document(relative)
 local f=assert(io.open(root..'/static/ergopti_plus/_shared/'..relative,'rb'))
 local text=assert(f:read('*a'));assert(f:close());return Json.decode(text)
end
local schema=document('modules/diagnostics/schema.json')
schema.export_strings=document('data/locales/en.json')
local snapshot={driver='macos',schema_version=2,generated_at='2026-11-05T00:00:00Z',extensive=false,sections={},probes={}}
for _,s in ipairs(schema.sections)do if s.kind~='summary' then snapshot.sections[s.id]={} end end
snapshot.sections.paths={config_dir=private,logs_dir=private}
snapshot.sections.issues={recent={canary..' '..private},recent_source='ring',last_error=canary}
snapshot.sections.versions={ergopti='1.2.3',unknown_secret=canary}
snapshot.unknown_secret=canary
local Share=require('healthcheck.share')
local exported=Share.document(snapshot,schema,schema.export_strings[schema.share_policy.notice_key])
assert(not exported.text:find(canary,1,true) and not exported.text:find('PrivateUser',1,true))
local daydocs={schema=schema,redaction=document('modules/diagnostics/redaction.json'),day_log=document('modules/diagnostics/day_log.json')}
local Day=require('healthcheck.day_log')
local raw='2026-11-05 00:00:00 [ERROR] '..canary..' '..private..'\n'
local reply=Day.prepare(snapshot,daydocs,{home='/Users/PrivateUser',user='PrivateUser',config_dir='/Users/PrivateUser/PrivateConfig'},function()return{found=true,size=#raw,text=raw}end)
assert(reply.state=='ready' and not Json.encode(reply):find(canary,1,true))
local logfile=Day.file(snapshot,daydocs,Share.snapshot(snapshot,schema,true))
assert(not logfile.text:find(canary,1,true))
assert(not pcall(Day.file,{},daydocs,{driver='macos'}))
Day.discard(snapshot)
assert(not pcall(Day.file,snapshot,daydocs,{driver='macos'}))
print('shared_export_control: typed_document_canary_absent=true daylog_preview_and_file_canary_absent=true refreshed_or_discarded_snapshot_has_no_attachment=true')
