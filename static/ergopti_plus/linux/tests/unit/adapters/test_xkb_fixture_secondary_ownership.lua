--- tests/unit/adapters/test_xkb_fixture_secondary_ownership.lua

local h=require('tests.helpers')
local function bracket(acquire)
 -- Execute the actual fixture's acquisition bracket without allocating native
 -- handles; identity markers expose duplicated first-owner custody on failure.
 local source=debug.getinfo(1,'S').source:gsub('^@','')
 local path=source:gsub('tests/unit/adapters/test_xkb_fixture_secondary_ownership.lua$','tests/hardware/run_xkb_source_qualification.lua')
 local f=assert(io.open(path,'rb'));local text=f:read('*a');assert(f:close())
 local body=assert(text:match('( local first_pid,first_control=_server_pid,_control.-)\n assert%(started,second_display%)'))
 local fn=assert((loadstring or load)('return function(start,first)\nlocal _server_pid,_control=first.pid,first.control\nlocal _second_server_pid,_second_control\n'..body..'\nreturn {main_pid=_server_pid,main_control=_control,second_pid=_second_server_pid,second_control=_second_control,started=started}\nend'))()
 local first={pid=91,control={}}
 local result=fn(acquire,first)
 return result,first
end
h.describe('actual native fixture second-owner failure bracket',function()
 h.it('does not duplicate the first display when second start throws before allocation',function()
  local result,first=bracket(function()error('controlled second readiness failure')end)
  h.assert_eq(result.started,false);h.assert_eq(result.main_pid,first.pid)
  h.assert_true(rawequal(result.main_control,first.control))
  h.assert_eq(result.second_pid,nil);h.assert_eq(result.second_control,nil)
 end)
 h.it('preserves first ownership when a second acquisition fails before connection',function()
  local source=debug.getinfo(1,'S').source:gsub('^@','')
  local path=source:gsub('tests/unit/adapters/test_xkb_fixture_secondary_ownership.lua$','tests/hardware/run_xkb_source_qualification.lua')
  local f=assert(io.open(path,'rb'));local text=f:read('*a');assert(f:close())
  local body=assert(text:match('( local first_pid,first_control=_server_pid,_control.-)\n assert%(started,second_display%)'))
  local fn=assert((loadstring or load)('return function(first)\nlocal _server_pid,_control=first.pid,first.control\nlocal _second_server_pid,_second_control\nlocal function start() _server_pid=92;error("controlled failure after new PID before connection")end\n'..body..'\nreturn {_server_pid,_control,_second_server_pid,_second_control}\nend'))()
  local first={pid=91,control={}};local result=fn(first)
  h.assert_eq(result[1],91);h.assert_true(rawequal(result[2],first.control))
  h.assert_eq(result[3],92);h.assert_eq(result[4],nil)
 end)
end)
