--- _shared/lua/test/physical_editor_inventory_contract.lua

--- Exact editor receipts recheck route and private currency after all external callbacks.
local Inventory = require("shortcuts.physical_editor_inventory")
return function(h)
 local function fixture()
  local path='/controlled/config.toml'
  local state={route=path,bytes='',keyboard=true,parameters=true,native=true}
  local owner=Inventory.new({path=path,current_path=function()
   if state.on_route then state.on_route() end
   return state.route
  end,read=function()
   if state.on_read then state.on_read() end
   return state.bytes,'ok'
  end,keyboard={capture_physical_editor_inventory=function()
   return {assignments={},current=function() return state.keyboard end}
  end},parameters={capture_parameter_source_guard=function()
   return function() return state.parameters end
  end,get_all_action_parameters=function() return {} end},recognizes=function() return true end,
  source_guard=function() return function() return state.native end end})
  local inventory,receipt=owner.capture();h.assert_eq(type(inventory),'table')
  return owner,state,receipt
 end
 h.describe('physical editor terminal source currency',function()
  h.it('admits an unchanged exact issuer receipt',function()
   local o,_,r=fixture();h.assert_eq(o.current(r),true)
  end)
  h.it('refuses a same-byte route handoff inside the native read callback',function()
   local o,s,r=fixture();s.on_read=function() s.route='/controlled/foreign.toml' end
   h.assert_eq(o.current(r),false);h.assert_eq(o.expected_source(r),nil)
  end)
  for _,field in ipairs({'keyboard','parameters','native'}) do
   h.it('refuses '..field..' private currency changed inside final route callback',function()
    local o,s,r=fixture();local calls=0
    s.on_route=function() calls=calls+1;if calls==2 then s[field]=false end end
    h.assert_eq(o.current(r),false);h.assert_eq(calls,2)
   end)
  end
  h.it('refuses a changed source without substituting a new receipt',function()
   local o,s,r=fixture();s.bytes='# foreign publisher\n'
   h.assert_eq(o.current(r),false);h.assert_eq(o.expected_source(r),nil)
  end)
  h.it('contains failed external native reads',function()
   local o,s,r=fixture();s.on_read=function() error('Controlled native read refusal') end
   h.assert_eq(o.current(r),false)
  end)
  h.it('contains failed final routing without admitting private bytes',function()
   local o,s,r=fixture();local calls=0;s.on_route=function() calls=calls+1;if calls==2 then error('Controlled final route refusal') end end
   h.assert_eq(o.current(r),false);h.assert_eq(calls,2)
  end)
  h.it('rejects a forged issuer receipt',function()
   local o=fixture();h.assert_eq(o.current({}),false);h.assert_eq(o.expected_source({}),nil)
  end)
 end)
end
