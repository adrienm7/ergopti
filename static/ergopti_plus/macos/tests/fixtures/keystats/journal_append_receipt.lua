--- tests/fixtures/keystats/journal_append_receipt.lua

--- ==============================================================================
--- MODULE: Physical Journal Append Receipt Fixture
--- DESCRIPTION:
--- Drives the public LogManager FIFO through the actual writer, aggregator and
--- Python SQLite bridge. Portable mode injects a documented refusal after real
--- prefix bytes; Common Linux mode induces EFBIG in the actual native FILE.
--- ==============================================================================

local root, temporary = assert(arg[3]), assert(arg[2])
assert(os.getenv('HOME') == temporary, 'physical replay must own its HOME')
local driver = root .. '/static/ergopti_plus/macos'
package.path=driver..'/?.lua;'..driver..'/?/init.lua;'..root..'/static/ergopti_plus/_shared/lua/?.lua;'..root..'/static/ergopti_plus/_shared/lua/?/init.lua'
package.cpath = ''
local Json, Helpers = require('json'),require('tests.helpers')
local function rpc(message)
 message.kind='request';assert(io.stdout:write(Json.encode(message)..'\n'));assert(io.stdout:flush())
 return assert(Json.decode_lossless(assert(io.stdin:read('*l'))))
end
local function request(message) local r=rpc(message);assert(r.ok,r.error);return r.value end
local function attrs(path)
 local v=request({op='stat',path=path});if v==false then return nil end
 return {mode=v.type,size=v.size}
end
local function sqlite_open(path)
 local identity=request({op='open',path=path});local db={last_error='',opened=true}
 function db:exec(sql)
  local r=rpc({op='exec',connection=identity,sql=sql});self.last_error=r.error or '';return r.ok and r.value or 1
 end
 function db:nrows(sql)
  local rows=request({op='rows',connection=identity,sql=sql})
  for _,row in ipairs(rows) do for key,value in pairs(row) do if Json.is_null(value) then row[key]=nil end end end
  local i=0;return function() i=i+1;return rows[i] end
 end
 function db:prepare(sql)
  local s={}
  function s:bind_values(...) self.values={...};return 0 end
  function s:step() local r=rpc({op='bound',connection=identity,sql=sql,values=self.values});db.last_error=r.error or '';return r.ok and 101 or 1 end
  function s:finalize() return 0 end
  return s
 end
 function db:errmsg() return self.last_error end
 function db:isopen() return self.opened end
 function db:close() local r=request({op='close',connection=identity});self.opened=false;return r end
 return db
end
_G.hs=require('tests.stubs.hs')
local loop=require('tests.support.runloop_timers').create()
hs.fs.attributes=attrs;hs.timer=loop.api
hs.sqlite3.open=sqlite_open
for _,name in ipairs({'fs','timer','json','sqlite3'}) do package.loaded['hs.'..name]=hs[name] end
local errors,logger={},Helpers.make_logger_stub()
logger.error=function(_,fmt,...) errors[#errors+1]=string.format(fmt,...) end
package.loaded['infra.logger']=logger
package.loaded['modules.keystats.export']={sync_foreign_data_sql=function()return{}end, get_native_app_category=function() return nil end}
-- This proof isolates raw-row ingest. SQL outbox publication writes real Lua bytes
-- and acknowledges its actual cache clear, but does not qualify LedgerAppend recovery.
package.loaded['adapters.ledger_append']={flush=function(path,batch,ack)
 if batch~='' then local h=assert(io.open(path,'ab'));assert(h:write(batch));assert(h:close()) end
 return ack()
end}
local Writer=require('modules.keystats.sqlite_writer')
local paths={sqlite_path=temporary..'/cache.sqlite',today_log_path=temporary..'/today.log',data_sql_path=temporary..'/data.sql'}
Writer.init({paths=paths,device_id='retry-proof',device_obj={device_id='retry-proof',name='Proof',os='darwin',host_signature='proof',created_at='2026-10-26 00:00:00.000'}})
assert(Writer.open_db(),table.concat(errors,' | '))
local Agg=require('modules.keystats.aggregator');Agg.init({device_id='retry-proof'})
local mode = assert(os.getenv('ERGOPTI_JOURNAL_APPEND_MODE'))
assert(mode == 'portable' or mode == 'native', 'explicit journal failure mode required')
local native_open, storage_refused, first_write, append_opens = io.open, true, true, 0
local streams = {}
io.open = function(path, access)
 local stream, detail, code = native_open(path, access)
 if not stream or path ~= paths.today_log_path or access ~= 'a+' then return stream, detail, code end
 append_opens = append_opens + 1
 streams[#streams + 1] = stream
 if mode == 'native' then return stream end
 return {
  setvbuf = function(_, ...) return stream:setvbuf(...) end,
  seek = function(_, ...) return stream:seek(...) end,
  read = function(_, ...) return stream:read(...) end,
  close = function() return stream:close() end,
  write = function(_, bytes)
   if storage_refused then
    if first_write then first_write = false; assert(stream:write(bytes:sub(1, #bytes - 1))) end
    return nil, 'injected refusal after physical prefix', 28
   end
   return stream:write(bytes)
  end,
 }
end
local Rotation=require('modules.keystats.rotation');Rotation.init({paths=paths,state={}})
assert(Rotation.is_initialized())
local Manager=require('modules.keystats.log_manager')
local function upvalue(fn,wanted,new)
 for i=1,math.huge do local name,value=debug.getupvalue(fn,i);assert(name,'missing upvalue '..wanted)
  if name==wanted then if new~=nil then debug.setupvalue(fn,i,new) end;return value end
 end
end
upvalue(upvalue(Manager.log_app_switch,'_require_state'),'_state',{})
local manager_paths=upvalue(upvalue(Manager.ingest_once,'_flush_local_data_sql_outbox'),'_paths')
for k,v in pairs(paths) do manager_paths[k]=v end
local queue=upvalue(upvalue(Manager.append_log,'_queue_deferred_log'),'_deferred_log_queue')
Manager.log_app_switch('Editor','Terminal',100,'2026-10-26 00:00:00.000')
local operation=assert(queue[1]);local row=operation.value
request({op='stat',path=paths.today_log_path,native_write_limit=mode == 'native' and #hs.json.encode(row) or nil})
assert(loop.step(),'the actual scheduler must own the first drain')
assert(queue[1]==operation,'refused append must retain the exact FIFO head')
local failed=assert(io.open(paths.today_log_path,'rb'));local prefix=assert(failed:read('*a'));assert(failed:close())
assert(prefix:sub(-1)=='}' and prefix:sub(-1)~='\n','real native write must end after complete JSON before LF')
-- Ingest retries the same FIFO head, then must fence the complete but still
-- unacknowledged JSON object while storage continues to refuse its final LF.
Manager.ingest_once()
local before = 0
for item in Writer.get_db():nrows('SELECT COUNT(*) AS n FROM events_app_switch') do before = item.n end
assert(before == 0, 'unacknowledged journal bytes must not enter raw events or metrics')
assert(queue[1] == operation, 'ingest must preserve the refused FIFO operation')
request({op='stat',path=paths.today_log_path,native_write_restore=mode == 'native'})
storage_refused = false
assert(loop.step(),'the original scheduler must own the retry')
assert(queue[1]==nil,'accepted retry must retire the original FIFO head')
assert(not loop.step(), 'settled FIFO must release its original deferred timer')
Manager.ingest_once()
local db=Writer.get_db();local count,ms=0,0
for r in db:nrows("SELECT COUNT(*) AS n FROM events_app_switch") do count=r.n end
for r in db:nrows("SELECT app_time_ms FROM agg_app_day WHERE app='Editor'") do ms=r.app_time_ms end
local ids={};for r in db:nrows('SELECT id FROM events_app_switch ORDER BY id') do ids[#ids+1]=r.id end
assert(Writer.close_db())
io.open = native_open
for _, stream in ipairs(streams) do if io.type(stream) == 'file' then assert(stream:close()) end end
print(Json.encode({kind='done',logical_public_calls=1,duration_ms=100,raw_rows=count,aggregate_app_time_ms=ms,rows_before_recovery=before,append_streams=append_opens,fault_mode=mode,ids=ids,retained_same_fifo_after_refusal=true,fifo_empty_after_retry=true,first_prefix_complete_json_without_LF=true,errors=errors,limits='native timers/metadata/SQLite are test boundary adapters; actual Lua stdio, Manager/Rotation/Writer/Aggregator and canonical real SQLite execute; SQL ledger append is isolated typed publisher, not recovery proof'}))
