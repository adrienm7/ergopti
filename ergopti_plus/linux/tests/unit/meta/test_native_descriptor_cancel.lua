--- tests/unit/meta/test_native_descriptor_cancel.lua

--- ==============================================================================
--- MODULE: Native Descriptor Cancellation Receipt Controls
--- DESCRIPTION:
--- Native exact descriptor cancellation receipts; literal refusal ports only.
--- ==============================================================================

local helpers=require("tests.helpers")
local Ports=require("tests.support.prepared_native_ports")
local url="http://127.0.0.1:9000/fixed"
local function start(core,callback)
 return core.dispatch_owned(url,{},"{}",{owner="exact-descriptor",method="POST",buffered=false,owned_api=false},function()end,callback)
end
helpers.describe("native exact construction descriptor cancellation",function()
 helpers.it("unknown initial metadata retains refusal, rejects later replacement authority, then observes EBADF",function()
  local core,state=Ports.fresh_client({body_metadata_failure=true,defer_close=true})
  local callbacks=0;local op=start(core,function()callbacks=callbacks+1 end)
  helpers.assert_eq(op.started,false);helpers.assert_eq(op:is_settled(),false);helpers.assert_eq(#state.requests,0)
  local accepted,cause=op:request_cancel()
  helpers.assert_eq(accepted,false);helpers.assert_eq(cause,"body-descriptor-retirement-pending")
  helpers.assert_eq(#state.descriptor_closes,0);helpers.assert_eq(callbacks,0)
  state.allow_metadata=true
  for _,fd in ipairs(state.descriptors)do state.identities[fd]={dev=9,ino=99,type="file"}end
  accepted,cause=op:request_cancel()
  helpers.assert_eq(accepted,false);helpers.assert_eq(cause,"body-descriptor-retirement-pending")
  helpers.assert_eq(#state.descriptor_closes,0);helpers.assert_eq(op:is_settled(),false)
  for _,fd in ipairs(state.descriptors)do helpers.assert_eq(state.identities[fd].ino,99);state.identities[fd]=nil end
  helpers.assert_true(op:request_cancel());helpers.assert_eq(op:is_settled(),false)
  state.ack_closes();helpers.assert_true(op:is_settled());helpers.assert_eq(callbacks,0)
  helpers.assert_eq(#state.descriptor_closes,0)
 end)
 for _,receipt in ipairs({"nil","false","throw"})do
  local fixed=receipt
  helpers.it("known original descriptors retain typed "..fixed.." close refusal until exact close ACK",function()
   local core,state=Ports.fresh_client({body_attach_failure=true,raw_close_receipt=fixed,defer_close=true})
   local callbacks=0;local op=start(core,function()callbacks=callbacks+1 end)
   helpers.assert_eq(op.started,false);helpers.assert_eq(op:is_settled(),false);helpers.assert_eq(#state.requests,0)
   local accepted,cause=op:request_cancel()
   helpers.assert_eq(accepted,false);helpers.assert_eq(cause,"body-descriptor-retirement-pending")
   for _,fd in ipairs(state.descriptors)do helpers.assert_eq(state.identities[fd].type,"fifo")end
   helpers.assert_eq(callbacks,0)
   state.allow_closes=true;helpers.assert_true(op:request_cancel());helpers.assert_eq(op:is_settled(),false)
   for _,fd in ipairs(state.descriptors)do helpers.assert_nil(state.identities[fd])end
   state.ack_closes();helpers.assert_true(op:is_settled());helpers.assert_eq(callbacks,0)
  end)
  for _,reused in ipairs({false,true})do
   local replacement=reused
   helpers.it("positive native absence after "..fixed.." close never retries a "..(replacement and "reused"or"EBADF").." descriptor",function()
    local core,state=Ports.fresh_client({body_attach_failure=true,raw_close_receipt=fixed,close_after_retirement=true,reuse_descriptor=replacement,defer_close=true})
    local callbacks=0;local op=start(core,function()callbacks=callbacks+1 end)
    helpers.assert_eq(op.started,false);helpers.assert_eq(op:is_settled(),false)
    local close_attempts=#state.descriptor_closes
    local accepted,cause=op:request_cancel();helpers.assert_true(accepted);helpers.assert_nil(cause)
    helpers.assert_eq(#state.descriptor_closes,close_attempts,"positively absent/reused descriptor has no second close authority")
    for _,fd in ipairs(state.descriptors)do
     if replacement then helpers.assert_eq(state.identities[fd].ino,99)else helpers.assert_nil(state.identities[fd])end
    end
    helpers.assert_eq(op:is_settled(),false);state.ack_closes();helpers.assert_true(op:is_settled());helpers.assert_eq(callbacks,0)
   end)
  end
 end
 helpers.it("generic handle-only construction debt retains accepted logical cancellation",function()
  local core,state=Ports.fresh_client({timer_failure=true,defer_close=true})
  local callbacks=0
  local op=core.dispatch_owned(url,{},nil,{owner="generic-handles",method="GET",buffered=true,owned_api=false},nil,function()callbacks=callbacks+1 end)
  helpers.assert_eq(op.started,false);helpers.assert_eq(#state.descriptors,0);helpers.assert_eq(op:is_settled(),false)
  local accepted,cause=op:request_cancel();helpers.assert_true(accepted);helpers.assert_nil(cause)
  helpers.assert_eq(op:is_settled(),false);state.ack_closes();helpers.assert_true(op:is_settled());helpers.assert_eq(callbacks,0)
 end)
end)
