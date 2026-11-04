local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
local H=require('tests.helpers')
local F=require('tests.fakes')
local P=require('tests.support.metrics_preferences_fixture')
local J=require('json')
local mono=require('infra.monotonic'); local observed=1000; mono.now_ms=function() return observed end
for _,mode in ipairs({'same_snapshot','across_commit'}) do
for _,boundary in ipairs({'pause','private','secure','suppressed','disabled'}) do
 P.with(function()
  local writer=F.sqlite_writer()
  package.loaded['modules.keystats.sqlite_writer']=writer
  package.loaded['modules.keystats.keystats']=nil
  local k=require('modules.keystats.keystats'); k.init({sqlite_path='/tmp/audit-boundary.sqlite'})
  assert(k.set_enabled(true))
  observed=1000; k.on_keydown('a',1000,'test-app'); if mode=='across_commit' then assert(k.flush()) end
  if boundary=='pause' then k.suspend_collection() elseif boundary=='private' then k.set_private_window(true) elseif boundary=='secure' then k.set_secure_field(true) elseif boundary=='suppressed' then k.suppress() else assert(k.set_enabled(false)) end
  k.on_keydown('X',1100,'test-app')
  if boundary=='pause' then k.resume_collection() elseif boundary=='private' then k.set_private_window(false) elseif boundary=='secure' then k.set_secure_field(false) elseif boundary=='suppressed' then k.unsuppress() else assert(k.set_enabled(true)) end
  observed=1300; k.on_keydown('b',1200,'test-app'); k.on_keydown(' ',1300,'test-app')
  assert(k.flush())
  print('BOUNDARY '..mode..' '..boundary..' '..J.encode(k.get_app_stats()['test-app']))
  for _,entry in ipairs(writer.typing) do print('RAW '..J.encode(entry.row)) end
  for _,entry in ipairs(writer.ngrams) do if entry.table_name=='ngram_bigrams' or entry.table_name=='ngram_words' then print('NGRAM '..J.encode(entry)) end end
 end)
end

end
