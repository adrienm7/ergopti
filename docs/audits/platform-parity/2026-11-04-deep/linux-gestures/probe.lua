local base='/workspace/ergopti/static/ergopti_plus/'
package.path=base..'linux/?.lua;'..base..'linux/?/init.lua;'..base..'_shared/lua/?.lua;'..base..'_shared/lua/?/init.lua;'..package.path
require('tests.helpers')
local emissions=0
package.loaded['modules.gestures.combo_emitter']={press=function() emissions=emissions+1;return true end,
    can_fallback=function() return false end}
local Manager=require('modules.gestures.manager')
local Decoder=require('modules.gestures.mt_decoder')
Manager.init({enabled=false,persist=false})
Manager._test_begin_reading({})
assert(Manager.enable())
local f=assert(io.open(base..'linux/tests/unit/modules/gestures/engine/test_mt_decoder.lua','r'))
local source=f:read('*a');f:close()
local before=assert(source:find('helpers.describe(',1,true))
local gesture_events=assert(load(source:sub(1,before-1)..'\nreturn gesture_events','@actual-decoder-event-fixture'))()
for fingers=3,5 do
    local slot='swipe_'..fingers..'_horiz'
    assert(Manager.set_action(slot,'tab_next'))
    assert(require('modules.gestures.slot_report').slot_is_reachable(slot,5))
    local decoder=Decoder.new()
    local out
    for _,event in ipairs(gesture_events(fingers,400,0)) do
        local result=decoder:feed({type=event[1],code=event[2],value=event[3]})
        if result then out=result end
    end
    assert(out and out.direction=='right')
    local fired=Manager.dispatch_gesture(out)
    print('AXIS',slot,'assign='..Manager.get_action(slot),'reachable=true','decoded='..out.direction,'fired='..tostring(fired))
    assert(not fired and emissions==0)
end
assert(Manager.set_action('swipe_3_right','tab_next'))
assert(Manager.dispatch_gesture({fingers=3,direction='right',tap=false}))
assert(emissions==1)
print('DIRECTION_CONTROL','emissions='..emissions)

-- Exploratory semantic case, not promoted to a confirmed finding: a wide
-- out-and-back motion can become a tap because the current rule uses net travel.
local decoder=Decoder.new({stable_frames=1,now_sec=function() return 100 end})
local function send(t,c,v) return decoder:feed({type=t,code=c,value=v}) end
send(1,Decoder.BTN_TOUCH,1);send(1,0x14e,1)
for i=0,2 do
    send(3,Decoder.ABS_MT_SLOT,i);send(3,Decoder.ABS_MT_TRACKING_ID,700+i)
    send(3,Decoder.ABS_MT_POSITION_X,1000+i*200);send(3,Decoder.ABS_MT_POSITION_Y,900)
end
send(0,0,0)
for _,offset in ipairs({400,0}) do
    for i=0,2 do send(3,Decoder.ABS_MT_SLOT,i);send(3,Decoder.ABS_MT_POSITION_X,1000+i*200+offset) end
    send(0,0,0)
end
send(1,0x14e,0);send(1,Decoder.BTN_TOUCH,0)
local result=send(0,0,0)
print('EXPLORATORY_NET_TRAVEL','tap='..tostring(result and result.tap))

-- The existing kernel input-core model retains MT axis registers across lifts
-- and filters unchanged values. Feed two identical horizontal swipes through
-- it, keeping the same real decoder alive as the production reader does.
local model_file=assert(io.open(base..'linux/tests/support/input_core_emulation.lua','r'))
local model_source=model_file:read('*a');model_file:close()
local model_end=assert(model_source:find('function M.run(',1,true))
local emulated_device=assert(load(model_source:sub(1,model_end-1)..'\nreturn emulated_device',
    '@actual-kernel-input-core-model'))()
for _,second_y_offset in ipairs({0,10}) do
    local ffi,drain=emulated_device({advertise_msc=true})
    for _,kind in ipairs({0,1,3,4}) do ffi.C.ioctl(7,0x40045564,kind) end
    ffi.C.ioctl(7,0x40045568,5)
    local persistent=Decoder.new()
    for repetition=1,2 do
        for _,event in ipairs(gesture_events(3,400,0)) do
            local value=event[3]
            if repetition==2 and event[1]==3 and event[2]==Decoder.ABS_MT_POSITION_Y then
                value=value+second_y_offset
            end
            ffi.C.write(7,{type=event[1],code=event[2],value=value})
        end
        local outputs,y_reports={},0
        drain(function(event)
            if event.type==3 and event.code==Decoder.ABS_MT_POSITION_Y then y_reports=y_reports+1 end
            local out=persistent:feed(event)
            if out then outputs[#outputs+1]=out end
        end)
        print('KERNEL_FILTERED_REPEAT','second_y_offset='..second_y_offset,
            'repetition='..repetition,'y_reports='..y_reports,'gestures='..#outputs)
        assert(#outputs==((repetition==1 or second_y_offset~=0) and 1 or 0))
        if repetition==2 and second_y_offset==0 then assert(y_reports==0) end
    end
end
