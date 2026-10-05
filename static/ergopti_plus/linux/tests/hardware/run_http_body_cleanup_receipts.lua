--- tests/hardware/run_http_body_cleanup_receipts.lua
--- ==============================================================================
--- MODULE: Native HTTP Body Cleanup Debt Receipts
--- DESCRIPTION:
--- Uses real curl, OS pipes, libuv handles and /proc descriptor observations.
--- Only refusals are injected: nil/false/throw before close, or error receipts
--- after actual close and descriptor reuse. Labels distinguish simulated return
--- values from native resource behavior. Owned fixtures clean their exact debt.
--- ==============================================================================

local uv=require('luv')
local Http=require('adapters.http_client')
assert(uv.getuid()~=0)
local BodyPipe=require('infra.http_body_pipe')
local pipe_backend=type(uv.pipe)=='function' and uv or BodyPipe
local pipe_field=type(uv.pipe)=='function' and 'pipe' or 'allocate'
local original_pipe, original_open, original_close, original_handle_close = pipe_backend[pipe_field], uv.pipe_open, uv.fs_close, uv.close
local server_handles, sockets = {}, {}
local directory=assert(uv.fs_mkdtemp('/tmp/ergopti-body-cleanup-XXXXXX'))
local sentinel=directory..'/sentinel'
local f=assert(io.open(sentinel,'wb'));assert(f:write('owned sentinel') and f:close())
local function close(h) if h and not uv.is_closing(h) then uv.close(h) end end
local function wait_for(done)
  local limit=uv.hrtime()+4000000000
  repeat uv.run('nowait'); if done() then return end; uv.sleep(1) until uv.hrtime()>=limit
  error('native close-debt probe did not retire')
end
local function retired()
  local alive=false
  uv.walk(function(h) if not server_handles[h] and not uv.is_closing(h) then alive=true end end)
  return not alive
end
local function count()
  local scan=assert(uv.fs_scandir('/proc/self/fd')); local n=0
  while uv.fs_scandir_next(scan) do n=n+1 end
  return n
end
local server=uv.new_tcp();server_handles[server]=true
assert(server:bind('127.0.0.1',0))
assert(server:listen(8,function(err)
  assert(not err)
  local s=uv.new_tcp();sockets[#sockets+1]=s;server_handles[s]=true
  assert(server:accept(s))
  local bytes=''
  assert(uv.read_start(s,function(e,c)
    assert(not e)
    if not c then close(s);return end
    bytes=bytes..c
    if bytes:find('\r\n\r\n',1,true) then
      uv.read_stop(s)
      assert(uv.write(s,'HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc',function()close(s)end))
    end
  end))
end))
local origin='http://127.0.0.1:'..server:getsockname().port
local warmup
assert(Http.get(origin,{}, {},function(r)warmup=r end))
wait_for(function()return warmup~=nil and retired()end)
-- Check both native allocation paths without assuming the binding exports pipe.
do
  local pair=assert(BodyPipe.allocate(uv))
  for _,fd in pairs(pair)do
    local info=assert(io.open('/proc/self/fdinfo/'..fd,'r'))
    local flags=assert(tonumber(assert(info:read('*a')):match('flags:%s+(%d+)'),8))
    assert(info:close())
    assert(flags%4096>=2048 and flags%1048576>=524288,'native pipe must retain NONBLOCK and CLOEXEC')
    assert(original_close(fd))
  end
end
local checks,failures=0,0
for _,attach in ipairs({false,true})do
for _,receipt in ipairs({'nil','false','throw'})do
  checks=checks+1
  local owner='native-body-close-debt-'..checks
  local raw,allow,retained_handle,pair={},false,nil,nil
  pipe_backend[pipe_field]=function(...)
    local p,a,b=original_pipe(...)
    if p then pair=p;raw[p.read]=true;raw[p.write]=true end
    return p,a,b
  end
  uv.pipe_open=function(h,fd)
    retained_handle=retained_handle or h
    if attach then return nil,'SIMULATED pipe attachment refusal' end
    local v,e=original_open(h,fd)
    if v~=nil and v~=false and not e then raw[fd]=nil end
    return v,e
  end
  uv.close=function(h,callback)
    if not attach and h==retained_handle and not allow then
      if receipt=='throw' then error('SIMULATED native handle close refusal') end
      if receipt=='false' then return false end
      if receipt=='nil' then return nil end
      return nil,'SIMULATED native handle close refusal'
    end
    return original_handle_close(h,callback)
  end
  uv.fs_close=function(fd)
    if attach and raw[fd] and not allow then
      if receipt=='throw' then error('SIMULATED descriptor close refusal') end
      if receipt=='false' then return false end
      if receipt=='nil' then return nil end
      return nil,'SIMULATED descriptor close refusal'
    end
    local v,e,c=original_close(fd)
    if v then raw[fd]=nil end
    return v,e,c
  end
  local function other_clients_retired()
    local alive=false
    uv.walk(function(h) if not server_handles[h] and h~=retained_handle and not uv.is_closing(h) then alive=true end end)
    return not alive
  end
  local before=count()
  local terminal,callbacks=nil,0
  local dispatched=Http.post(origin,{},'{"text":"literal"}',function(r)terminal,callbacks=r,callbacks+1 end,{owner=owner,timeout_ms=25})
  wait_for(other_clients_retired)
  local held=0
  for _,fd in pairs(pair)do
    local link=uv.fs_readlink('/proc/self/fd/'..fd)
    if link and link:match('^pipe:%[')then held=held+1 end
  end
  assert(held==(attach and 2 or 1), 'simulated refusal must retain the expected actual pipe resources')
  local blocked
  local successor=Http.get_owned(origin,{}, {owner=owner},function(r)blocked=r end)
  local fenced=successor.started==false and successor:is_settled() and blocked and blocked.error=='previous request cleanup pending'
  if successor.started then successor:cancel();wait_for(other_clients_retired)end
  local retained=count()==before+(attach and 2 or 1)
  allow=true
  Http.cancel(owner)
  wait_for(other_clients_retired)
  uv.run('nowait')
  local accepted=Http.cancel(owner)
  uv.run('nowait')
  local recovered=count()==before
  local success=dispatched==false and callbacks==0 and fenced and retained and accepted and recovered
  print((success and 'PASS ' or 'FAIL ')..'SIMULATED '..receipt..' close '..(attach and 'attachment rollback' or 'inherited body channel')..': raw='..held..' callbacks='..callbacks..' fenced='..tostring(fenced)..' retry='..tostring(accepted)..' recovered='..tostring(recovered))
  if not success then failures=failures+1 end
  -- Baseline cannot retry its abandoned FDs: clean only these probe-owned pairs.
  if retained_handle and not uv.is_closing(retained_handle)then original_handle_close(retained_handle)end
  for fd in pairs(raw)do assert(original_close(fd));raw[fd]=nil end
  uv.run('nowait')
  pipe_backend[pipe_field],uv.pipe_open,uv.fs_close,uv.close=original_pipe,original_open,original_close,original_handle_close
end
end
-- These injected failures call the real close first; errors do not imply liveness.
for _,reused in ipairs({false,true})do
for _,receipt in ipairs({'nil','false','throw'})do
  checks=checks+1
  local owner='native-retired-body-fd-'..checks
  local pair,sentinel_fd,reported=nil,nil,false
  local attempts=0
  pipe_backend[pipe_field]=function(...) local p,a,b=original_pipe(...);pair=p;return p,a,b end
  uv.pipe_open=function()return nil,'SIMULATED attachment allocation failure'end
  uv.fs_close=function(fd)
    if pair and fd==pair.read then
      attempts=attempts+1
      if not reported then
        reported=true
        assert(original_close(fd))
        if reused then
          sentinel_fd=assert(uv.fs_open(sentinel,'r',384))
          assert(sentinel_fd==fd,'fixture must reuse the retired descriptor number')
        end
        if receipt=='throw'then error('SIMULATED close error after real retirement')end
        if receipt=='false'then return false end
        if receipt=='nil'then return nil end
        return nil,'SIMULATED close error after real retirement'
      end
    end
    return original_close(fd)
  end
  local before=count()
  local callbacks=0
  local dispatched=Http.post(origin,{},'{"text":"literal"}',function()callbacks=callbacks+1 end,{owner=owner})
  wait_for(retired)
  local blocked
  local candidate=Http.get_owned(origin,{}, {owner=owner},function(r)blocked=r end)
  local fenced=candidate.started==false and blocked and blocked.error=='previous request cleanup pending'
  if candidate.started then candidate:cancel();wait_for(retired)end
  Http.cancel(owner);uv.run('nowait')
  local alive=not reused or (uv.fs_fstat(sentinel_fd) and uv.fs_read(sentinel_fd,100,0)=='owned sentinel')
  local recovered=count()==before+(reused and 1 or 0)
  local success=dispatched==false and callbacks==0 and fenced and alive and attempts==1 and recovered
  print((success and 'PASS 'or'FAIL ')..'SIMULATED '..receipt..' after actual retirement '..(reused and 'with FD reuse' or 'with EBADF')..': attempts='..attempts..' fenced='..tostring(fenced)..' sentinel='..tostring(alive)..' recovered='..tostring(recovered))
  if not success then failures=failures+1 end
  if sentinel_fd then assert(original_close(sentinel_fd))end
  pipe_backend[pipe_field],uv.pipe_open,uv.fs_close=original_pipe,original_open,original_close
end
end

-- A native process-exit retry can publish its original failure after every ACK.
do
  checks=checks+1
  local first,allow=nil,false
  local before=count()
  uv.pipe_open=function(h,fd)first=first or h;return original_open(h,fd)end
  uv.close=function(h,callback)
    if h==first and not allow then return nil,'SIMULATED close refusal'end
    return original_handle_close(h,callback)
  end
  local callbacks,result=0,nil
  local dispatched=Http.post(origin,{},'{"text":"literal"}',function(r)result,callbacks=r,callbacks+1 end,{owner='native-healthy-retry',timeout_ms=25})
  local blocked
  local candidate=Http.get_owned(origin,{}, {owner='native-healthy-retry'},function(r)blocked=r end)
  local fenced=not candidate.started and blocked and blocked.error=='previous request cleanup pending'
  if candidate.started then candidate:cancel()end
  allow=true
  wait_for(function()
    local alive=false
    uv.walk(function(h)if not server_handles[h] and h~=first and not uv.is_closing(h)then alive=true end end)
    return (dispatched or callbacks==1) and not alive
  end)
  local success=not dispatched and fenced and result and result.error=='curl body pipe retirement failed' and count()==before
  print((success and 'PASS 'or'FAIL ')..'native process-exit retry after SIMULATED reader close refusal')
  if not success then failures=failures+1 end
  if first and not uv.is_closing(first)then original_handle_close(first)end
  uv.run('nowait')
  uv.pipe_open,uv.close=original_open,original_handle_close
end

-- A refused initial identity may not be learned from a later unrelated file.
do
  checks=checks+1
  local original_stat=uv.fs_fstat
  local pair,allow=nil,false
  local before=count()
  pipe_backend[pipe_field]=function(...)local p,a,b=original_pipe(...);pair=p;return p,a,b end
  uv.fs_fstat=function(fd)
    if pair and (fd==pair.read or fd==pair.write) and not allow then return nil,'SIMULATED initial metadata refusal','EIO'end
    return original_stat(fd)
  end
  local callbacks=0
  local dispatched=Http.post(origin,{},'{}',function()callbacks=callbacks+1 end,{owner='unknown-native-body'})
  wait_for(retired)
  if dispatched then
    print('FAIL SIMULATED initial metadata refusal must precede transfer and retain unknown identity')
    failures=failures+1
  else
  assert(original_close(pair.read))
  local replacement=assert(uv.fs_open(sentinel,'r',384))
  assert(replacement==pair.read)
  allow=true
  local blocked
  local candidate=Http.get_owned(origin,{}, {owner='unknown-native-body'},function(r)blocked=r end)
  local fenced=not candidate.started and blocked and blocked.error=='previous request cleanup pending'
  if candidate.started then candidate:cancel();wait_for(retired)end
  local retained=not Http.cancel('unknown-native-body')
  local alive=original_stat(replacement) and uv.fs_read(replacement,100,0)=='owned sentinel'
  assert(original_close(replacement))
  if original_stat(pair.write)then assert(original_close(pair.write))end
  local recovered=Http.cancel('unknown-native-body') and count()==before
  local success=not dispatched and callbacks==0 and fenced and retained and alive and recovered
  print((success and 'PASS 'or'FAIL ')..'SIMULATED initial metadata refusal preserves actual reused descriptor and waits for EBADF')
  if not success then failures=failures+1 end
  end
  uv.fs_fstat=original_stat;pipe_backend[pipe_field]=original_pipe
end

close(server);for _,s in ipairs(sockets)do close(s)end;uv.run()
assert(not uv.loop_alive())
assert(uv.fs_unlink(sentinel) and uv.fs_rmdir(directory))
assert(checks == 14, 'native cleanup regression case inventory changed')
print('Native resource / simulated refusal body cleanup: '..checks..' checks, '..failures..' failures')
os.exit(failures==0 and 0 or 1)
