--- tests/hardware/run_http_owned_post_native.lua

--- ==============================================================================
--- MODULE: Actual Owned HTTP POST Receipts
--- DESCRIPTION:
--- Drives the production curl producer through real private body bytes, native
--- close acknowledgments, source revocation and owned descendant group absence.
--- The existing subreaper retains exact failure/timeout retirement ownership.
--- ==============================================================================

--- Actual curl owned POST bytes, source fencing, close ACKs and group retirement.
local driver,shared,descendant_marker=assert(arg[1]),assert(arg[2]),arg[3]
package.path=driver..'/?.lua;'..driver..'/?/init.lua;'..shared..'/?.lua;'..shared..'/?/init.lua;'..package.path
local uv=require('luv');require('compat.utf8').install()
local holds,acks,spawned,pids={}, {},0,{}
local port_failure
local allow_signals = descendant_marker == nil or descendant_marker == ''

local proxy=setmetatable({}, {__index=uv})
proxy.close=function(handle,callback)
 return uv.close(handle,function()if callback then if holds.active then acks[#acks+1]=callback else callback() end end end)
end
proxy.spawn=function(command,options,callback)
 local process,pid=uv.spawn(command,options,callback)
 if pid then pids[#pids+1]=pid end
 if process then
  spawned=spawned+1
  local file=io.open('/proc/'..pid..'/cmdline','rb')
  if not file then port_failure='native argv observation unavailable'
  else
   local args=file:read('*a');file:close()
   if not args or args:find('PRIVATE-POST',1,true) or args:find('PRIVATE-HEADER',1,true) then port_failure='private text or credential entered actual argv' end
  end
 end
 return process,pid
end
proxy.kill=function(pid,signal)
 if signal~=0 and not allow_signals then
  local owned=false;for _,captured in ipairs(pids)do if pid==-captured then owned=true end end
  if not owned then port_failure='native refusal escaped exact acquired group' end
  return nil,'fixture refuses its own native group termination','EPERM'
 end
 return uv.kill(pid,signal)
end
package.loaded.luv=proxy
local Http=require('adapters.http_client')
package.loaded.luv=uv
local server=assert(uv.new_tcp());assert(server:bind('127.0.0.1',0));local sockets,requests,timers={}, {},{}
local slow_socket
local origin='http://127.0.0.1:'..server:getsockname().port
local function close(h)if h and not uv.is_closing(h) then uv.close(h) end end
assert(server:listen(8,function(error)
 if error then requests.failure=error;return end
 local socket=assert(uv.new_tcp());sockets[#sockets+1]=socket;assert(server:accept(socket));local input,handled='',false
 socket:read_start(function(read_error,chunk)
  if read_error then requests.failure=read_error;close(socket);return end
  if not chunk then close(socket);return end
  if handled then return end
  input=input..chunk;local boundary=input:find('\r\n\r\n',1,true);if not boundary then return end
  local length=tonumber(input:sub(1,boundary):lower():match('content%-length:%s*(%d+)')) or 0
  if #input<boundary+3+length then return end
  handled=true;local method,path=input:match('^(%u+) ([^ ]+) ');requests[#requests+1]={method=method,path=path,body=input:sub(boundary+4,boundary+3+length)}
  if path=='/slow' then
   slow_socket=socket
   socket:write('HTTP/1.1 200 Fixture\r\nContent-Length: 100\r\nConnection: close\r\n\r\nfirst')
  else
   local body='{"status":"success"}\n\0tail'
   socket:write('HTTP/1.1 200 Fixture\r\nContent-Length: '..#body..'\r\nConnection: close\r\n\r\n'..body,function()socket:shutdown(function()close(socket)end)end)
  end
 end)
end))
local guard=assert(uv.new_timer());local expired=false;uv.timer_start(guard,8000,0,function()expired=true end)
local operations={};local function retain(op)operations[#operations+1]=op;return op end
local function until_receipt(predicate)
 while not predicate() and not expired do uv.run('once') end
 assert(not expired,'bounded actual fixture deadline');assert(not requests.failure,requests.failure)
end
local completed=0;local function pass(name)completed=completed+1;print('PASS '..name)end
local ok,failure=xpcall(function()
 holds.active=true
 local chunks,result,settled='',nil,0
 local op=retain(Http.post_stream_owned(origin..'/echo',{['X-Private']='PRIVATE-HEADER'},'PRIVATE-POST\n@literal\\u0000',{owner='native-post',timeout_ms=3000,authorized=function()return true end},function(chunk)chunks=chunks..chunk end,function(value)result=value end))
 assert(op.started);op:on_settled(function()settled=settled+1 end)
 until_receipt(function()return #requests==1 and #acks>=6 and op._request.exited and (allow_signals or uv.fs_stat(descendant_marker)~=nil) end)
 assert(not op:is_settled() and result==nil and settled==0,'actual exit cannot borrow held native close callbacks')
 assert(requests[1].method=='POST' and requests[1].body=='PRIVATE-POST\n@literal\\u0000','real curl delivers exact inherited-pipe request bytes')
 assert(chunks=='{"status":"success"}\n\0tail','raw streaming response bytes/status separation')
 if not allow_signals then
  local live=uv.kill(-pids[1],0);assert(live~=nil and live~=false,'actual exited leader retains a live private descendant group')
  local marker=assert(io.open(descendant_marker,'rb'));local child_pid=assert(tonumber(marker:read('*a')));assert(marker:close())
  local metadata=assert(io.open('/proc/'..child_pid..'/stat','rb'));local fields=metadata:read('*a'):match('%)(.*)$');assert(metadata:close())
  local state,ppid,group=fields:match('^%s*(%S+)%s+(%d+)%s+(%d+)');assert(tonumber(group)==pids[1] and state~='Z','independently observed live descendant belongs to exact exited leader group')
  local refused=Http.post_stream_owned(origin..'/echo',{},'PRIVATE-POST',{owner='native-post'},function()end,function()end)
  assert(not refused.started and refused:is_settled(),'a live group blocks same-owner successors')
  allow_signals=true
 end
 holds.active=false;for _,ack in ipairs(acks)do ack()end;acks={}
 until_receipt(function()return op:is_settled()end)
 assert(result and result.ok and result.status==200 and settled==1)
 pass('real private POST exact bytes and held native close ACKs')
 local before=spawned;local callback,construction=0,0
 local header=setmetatable({},{__tostring=function()construction=construction+1;return 'PRIVATE-HEADER' end})
 local refused=retain(Http.post_stream_owned(origin..'/echo',{Authorization=header},'PRIVATE-POST',{owner='refused',authorized=function()return false end},function()callback=callback+1 end,function()callback=callback+1 end))
 assert(not refused.started and refused:is_settled() and spawned==before and callback==0 and construction==0)
 pass('literal source refusal precedes actual native allocation and credentials')
 local rejected
 local nul=retain(Http.post_stream_owned(origin..'/echo',{},'PRIVATE-POST\0tail',{owner='nul'},function()end,function(value)rejected=value end))
 assert(not nul.started and nul:is_settled() and spawned==before and rejected and rejected.error=='curl request body cannot contain NUL')
 pass('literal request NUL refuses without real curl dispatch')
 local current,received,done=true,'',nil
 local slow=retain(Http.post_stream_owned(origin..'/slow',{},'PRIVATE-POST',{owner='slow',timeout_ms=3000,authorized=function()return current end},function(chunk)received=received..chunk;current=false;if slow_socket then slow_socket:write('second') end end,function(value)done=value end))
 assert(slow.started);until_receipt(function()return slow:is_settled()end)
 assert(received=='first' and done==nil,'later actual response is fenced after originating source revocation')
 pass('real chunk source revocation fences subsequent data and retires curl')
 if descendant_marker and descendant_marker~='' then
  local marker=assert(io.open(descendant_marker,'rb'),'owned shim descendant readiness marker exists');assert(marker:read('*a'):match('%d+'));assert(marker:close())
  pass('real shim descendant remains within owned curl process group until ESRCH')
 end
 assert(not port_failure,port_failure)
end,debug.traceback)
-- Release deliberately held ACKs even on a failing assertion, and cancel only
-- the exact operations retained by this fixture before owning socket teardown.
allow_signals=true;holds.active=false;for _,ack in ipairs(acks)do ack()end
for _,op in ipairs(operations)do if not op:is_settled()then op:cancel()end end
for _,h in ipairs(timers)do close(h)end;for _,h in ipairs(sockets)do close(h)end;close(server);close(guard)
uv.run();assert(not uv.loop_alive(),'fixture retired every native handle')
if not ok then error(failure)end
print('Actual owned POST: '..completed..' passed, 0 failed; exact native cleanup complete.')
