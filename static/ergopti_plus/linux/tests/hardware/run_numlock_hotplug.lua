--- tests/hardware/run_numlock_hotplug.lua

--- ==============================================================================
--- MODULE: NumLock Across Native Source Hotplug
--- DESCRIPTION:
--- Exercises real uinput source addition/removal and a fresh native EVIOCGLED
--- positive control before and after the change. The production Hook resolves
--- keypad input while an independent libxkbcommon state consumes the real output
--- events. Discovery selects only these virtual fixtures; no physical hardware
--- is claimed. Run from the Linux driver root under X11 with LuaJIT and uinput:
---     luajit tests/hardware/run_numlock_hotplug.lua add
---     luajit tests/hardware/run_numlock_hotplug.lua remove
--- ==============================================================================

require('compat.utf8').install()
local Hook=require('adapters.keyboard_hook')
local Names=require('infra.device_names')
local Reader=require('adapters.evdev_reader')
local Finder=require('modules.hotstrings.device_finder')
local Layout=require('adapters.keyboard_layout')
local Clock=require('infra.monotonic')
local Json=require('json')
local mode=assert(arg[1]);assert(mode=='add' or mode=='remove')
local names,paths,keyboards,caps,chars,rows={},{},{},{},{},{}
local ownerA
local selected={}
local oldname,oldfind=Names.VIRTUAL_KEYBOARD,Finder.find_devices
local Injector
local Sink,Capture,sink_chars
local function record(stage,data)
	data.stage=stage;data.mode=mode;data.monotonic_ms=Clock.now_ms()
	print('NUMLOCK_RECEIPT '..Json.encode(data))
end
local function await(predicate,bound)
	local deadline=Clock.now_ms()+bound
	repeat
		local value=predicate();if value then return value end
		require('luv').sleep(1)
	until Clock.now_ms()>=deadline
	return nil
end
local function node(name)
	local file=assert(io.open('/proc/bus/input/devices','r'));local text=file:read('*a');file:close()
	for block in text:gmatch('I:.-\n\n') do
		if block:find('N: Name="'..name..'"',1,true) then
			local event=(block:match('H: Handlers=([^\n]*)') or ''):match('(event%d+)')
			if event then return '/dev/input/'..event end
		end
	end
end
local function create(index)
	names[index]='Ergopti Native NumLock '..mode..' '..index
	keyboards[index]=require('tests.hardware.led_source_keyboard').create(names[index])
	caps[index]=assert(keyboards[index].capture_output())
	paths[index]=assert(await(function() return node(names[index]) end,5000))
end
local function pump()
	Hook.pump()
	while true do
		local event=Reader.read_event('pass2-output');if not event then break end
		assert(not(event.type==0 and event.code==3),'independent sink overflowed')
		if event.type==1 then
			rows[#rows+1]={event.code,event.value}
			if Sink then local text,_,err=Sink.process(event.code,event.value);assert(not err,err)
				if text and event.value~=0 then sink_chars[#sink_chars+1]=text end
			end
		end
	end
end
local function emit(index,code,value)
	local before=#rows;assert(keyboards[index].emit_owned(caps[index],code,value))
	assert(await(function() pump();return #rows>before end,1000),'real source transition never reached output')
end
local function bitmap(slot)
	return (assert(Reader.pressed_keys(slot,767),'native key bitmap unavailable'))
end
local function caps_state()
	local leds=assert(Reader.active_leds('keyboard:'..paths[1],1))
	return {source_LED_NUM=leds[0]==true,sink_KP1=Sink.peek_text(79),hook_KP1=Capture.peek_text(79),
		source_held=bitmap('keyboard:'..paths[1]),sink_held=bitmap('pass2-output'),owner_current=Reader.source_owner_current(ownerA)}
end
local ok,failure=xpcall(function()
	assert(Reader.use_ffi_backend());create(1)
	if mode=='remove' then create(2) end
	-- The kernel keyboard handler may initialize a new source with the console's
	-- ambient NumLock LED. Establish the fixture's OFF starting state through
	-- real EV_LED writes before Hook seeds capture, matching the fresh sink.
	for index, keyboard in ipairs(keyboards) do keyboard.set_led(paths[index],0,0) end
	selected={paths[1]};if paths[2] then selected[2]=paths[2] end
	Injector=require('modules.hotstrings.injector');assert(Injector.open_fast_channel())
	assert(Reader.open(assert(await(function() return node(oldname) end,5000)),'pass2-output'))
	assert(Layout.refresh())
	local mapping=assert(io.popen('xkbcomp -xkb "$DISPLAY" - 2>/dev/null','r'))
	local text=mapping:read('*a');assert(mapping:close())
	Sink=assert(loadfile('adapters/xkb_capture.lua'))();assert(Sink.load(text));sink_chars={}
	Capture=require('adapters.xkb_capture')
	Finder.find_devices=function() return selected,{} end
	Hook=require('adapters.keyboard_hook')
	Hook.start({intercept=true,requireOutputBroker=true,outputBroker=assert(Injector.output_broker()),
		onCaptureReacquired=function() return Layout.publish_current_capture() end,onEmitRaw=Injector.emit_key,onChar=function(char) chars[#chars+1]=char end})
	assert(Hook.isRunning());assert(Layout.publish_current_capture())
	ownerA=assert(Reader.capture_source_owner('keyboard:'..paths[1]))
	for _, path in ipairs(paths) do
		local leds=assert(Reader.active_leds('keyboard:'..path,1))
		assert(leds[0]==nil,'native source LED_NUM starting state is not OFF')
	end
	local initial=caps_state()
	record('native-starting-state',{state=initial})
	assert(initial.hook_KP1=='' and initial.sink_KP1=='','native NumLock states did not start neutral')
	emit(1,69,1);emit(1,69,0)
	keyboards[1].set_led(paths[1],0,1)
	assert(Reader.active_leds('keyboard:'..paths[1],1)[0]==true,'real source LED_NUM did not turn on')
	emit(1,79,1);emit(1,79,0)
	record('positive-control-observed',{matcher=table.concat(chars),sink_native_text=table.concat(sink_chars),rows=rows,state=caps_state()})
	assert(table.concat(chars)=='1' and table.concat(sink_chars)=='1','native NumLock positive controls disagree')
	record('positive-control',{matcher=table.concat(chars),rows=rows,state=caps_state()})
	chars,rows,sink_chars={},{},{}
	if mode=='add' then create(2);selected={paths[1],paths[2]}
	else assert(keyboards[2].close_owned(caps[2]));keyboards[2]=nil;caps[2]=nil;selected={paths[1]};pump() end
	for _=1,Hook.DEVICE_CHECK_TICKS do Hook.check_device() end
	assert(Hook.isRunning(),'source change stopped retained keyboard')
	assert(Reader.is_open('keyboard:'..paths[2])==(mode=='add'),'hotplug source cohort never committed')
	local after=caps_state()
	record('after-hotplug',{state=after,source_b_open=Reader.is_open('keyboard:'..paths[2])})
	emit(1,79,1);emit(1,79,0)
	record('post-hotplug-character',{matcher=table.concat(chars),rows=rows,state=caps_state(),
		expected_matcher='1',sink_native_text=table.concat(sink_chars),source_LED_NUM_before_character=after.source_LED_NUM})
	local good=table.concat(chars)=='1' and table.concat(sink_chars)=='1' and after.owner_current and after.source_LED_NUM
	record('final-held',{source=bitmap('keyboard:'..paths[1]),sink=bitmap('pass2-output')})
	assert(good,'native NumLock disagrees with matcher despite fresh source LED_NUM after '..mode..' hotplug')
	assert(next(bitmap('keyboard:'..paths[1])) == nil and next(bitmap('pass2-output')) == nil,
		'native NumLock probe left source/output keys down')
	Hook.stop()
	assert(not Hook.isRunning() and not Reader.is_open('keyboard:'..paths[1]), 'native source not retired on stop')
	assert(Reader.open(paths[1], 'numlock-stop-observer') and Reader.grab('numlock-stop-observer'),
		'native source grab not returned after stop')
	assert(Reader.close('numlock-stop-observer'))
	print('PASS: native source LED_NUM and sink KP1 agree after '..mode..' hotplug')
end,debug.traceback)
if not ok then record('failure',{error=tostring(failure)}) end
if Hook then pcall(Hook.stop) end
if Sink then pcall(Sink.clear) end
pcall(Reader.close,'pass2-output');if Injector then pcall(Injector.close_fast_channel) end
for index,writer in pairs(keyboards) do pcall(writer.close_owned,caps[index]) end
Finder.find_devices=oldfind;Names.VIRTUAL_KEYBOARD=oldname
if not ok then io.stderr:write(tostring(failure)..'\n');os.exit(1) end
