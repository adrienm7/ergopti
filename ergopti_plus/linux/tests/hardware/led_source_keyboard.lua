--- tests/hardware/led_source_keyboard.lua

--- ==============================================================================
--- MODULE: Native LED Source Keyboard Fixture
--- DESCRIPTION:
--- Creates a test-owned uinput source with real Caps, Num and Scroll LED support.
--- Its private tokens settle fixture descriptors only; they grant no production
--- output authority. A second native evdev descriptor writes LED feedback so the
--- regression does not depend on an absent desktop input controller.
--- ==============================================================================

local ffi=require('ffi')
if not pcall(ffi.typeof,'struct ergopti_hardware_led_setup') then ffi.cdef[[
struct ergopti_hardware_led_setup { unsigned short bus,vendor,product,version; char name[80]; unsigned int ffmax; };
struct ergopti_hardware_led_event { long seconds,microseconds; unsigned short type,code; int value; };
]] end
if not pcall(function() return ffi.C.write end) then ffi.cdef[[long write(int fd,const void* data,unsigned long count);]] end
local M={}
--- Creates one real kernel source with keyboard and lock LED capabilities.
--- @param name string Test-owned kernel device name.
--- @return table source Exact fixture descriptor owner.
function M.create(name)
	assert(type(name) == 'string' and #name > 0 and #name < 80 and not name:find('%z'), 'invalid source name')
	local fd=ffi.C.open('/dev/uinput',0x80000+0x800+2)
	assert(fd>=0,'uinput source open failed')
	local token={};local closed=false
	local function ioctl(request,value)
		local pointer=ffi.cast('void*',value)
		assert(ffi.C.ioctl(fd,request,pointer)==0,'real source ioctl refused '..request)
	end
	local configured, failure = pcall(function()
		ioctl(0x40045564,1);ioctl(0x40045564,17)
		for code=1,255 do ioctl(0x40045565,code) end
		for code=0,2 do ioctl(0x40045569,code) end
		local setup=ffi.new('struct ergopti_hardware_led_setup')
		setup.bus=3;setup.vendor=1;setup.product=1;setup.version=1;ffi.copy(setup.name,name)
		assert(ffi.sizeof(setup)==92);ioctl(0x405c5503,setup);ioctl(0x5501,0)
	end)
	if not configured then ffi.C.close(fd); error(failure, 0) end
	local function write(target,kind,code,value)
		local events=ffi.new('struct ergopti_hardware_led_event[2]')
		events[0].type=kind;events[0].code=code;events[0].value=value
		local count=ffi.sizeof(events)
		return ffi.C.write(target,events,count)==count
	end
	return {capture_output=function() return token end,
		emit_owned=function(cap,code,value) assert(cap==token and not closed);return write(fd,1,code,value) end,
		set_led=function(path,code,value)
			local controller=ffi.C.open(path,0x80000+0x800+2);assert(controller>=0,'LED controller fd unavailable')
			local acknowledged=write(controller,17,code,value)
			local settled=ffi.C.close(controller)==0
			assert(acknowledged and settled,'real EV_LED controller write/close not acknowledged')
		end,
		close_owned=function(cap)
			assert(cap==token);if closed then return true end
			ioctl(0x5502,0);assert(ffi.C.close(fd)==0);closed=true;return true
		end}
end
return M
