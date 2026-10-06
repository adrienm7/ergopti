--- modules/llm/owned_timer.lua

--- ==============================================================================
--- MODULE: Exact Native Linux Bootstrap Timer
--- DESCRIPTION:
--- Preserves one native timer identity through start refusal, callback
--- delivery, cancellation and actual close acknowledgment.
--- ==============================================================================

local M={}
local MAX_INTEGER=9007199254740991
local function integer(n) return type(n)=='number' and n>=0 and n<=MAX_INTEGER and n%1==0 end
function M.new(native, arm)
	assert(type(native)=='table' and type(arm)=='table' and type(arm.start)=='function', 'native timer unavailable')
	for _,name in ipairs({'new_timer','timer_stop','close','is_closing','hrtime'}) do
		assert(type(native[name])=='function','native timer method missing: '..name)
	end
	local create,stop,close,closing,clock,start=native.new_timer,native.timer_stop,native.close,
		native.is_closing,native.hrtime,arm.start
	local port={}
	function port.now_ms()
		local n=clock();assert(type(n)=='number' and n>=0 and n==n and n<math.huge, 'native clock unavailable')
		local ms=math.floor(n/1000000);assert(integer(ms),'native clock overflow');return ms
	end
	function port.after(delay,callback)
		local op={started=false};local handle,state,cancelled,listeners=nil,'acquiring',false,{}
		local acquiring,early=false,false
		local function notify(fn,...)
			local ok=pcall(fn,...);if not ok then op.observer_error='native_timer_observer_refused' end
		end
		local function settle()
			if state=='closed' then return end
			state='closed';op.cleanup_error=nil
			local pending=listeners;listeners={}
			for _,fn in ipairs(pending) do notify(fn) end
		end
		local function retire()
			if state=='closed' then return true end
			if acquiring or state=='acquiring' or state=='unknown' then return false end
			if state=='closing' then return false end
			local checked,is_closing=pcall(closing,handle)
			if not checked or is_closing~=false then op.cleanup_error='native_timer_foreign_close';return false end
			pcall(stop,handle) -- Physical closure is stronger than timer_stop's scheduling receipt.
			state='closing'
			local accepted,value,err=pcall(close,handle,function()settle()end)
			if state=='closed' then return true end
			if not accepted or value==false or err~=nil then
				-- A throwing close may already be queued. Only our callback can prove
				-- closure; refuse retries while native reports a foreign/unknown close.
				state='open';op.cleanup_error='native_timer_close_pending'
			end
			return false
		end
		function op:is_settled()return state=='closed'end
		function op:on_settled(fn)
			if type(fn)~='function'then return false end
			if state=='closed'then notify(fn)else listeners[#listeners+1]=fn end
			return true
		end
		function op:cancel()cancelled=true;return retire()end
		local function fired()
			if acquiring then early=true;return end
			if cancelled or state~='open'then return end
			cancelled=true
			notify(callback)
			retire()
		end
		if not integer(delay)or delay==0 or type(callback)~='function'then
			op.result={ok=false,error='native_timer_admission_invalid'};settle();return op
		end
		acquiring=true
		local ok,value=pcall(create)
		if not ok then state='unknown';op.cleanup_error='native_timer_acquisition_unknown'
		elseif value==nil then settle()
		else handle=value;state='open'end
		if handle then
			local armed,accepted,err=pcall(start,native,handle,delay,0,fired)
			if armed and (accepted==true or accepted==0)and err==nil then op.started=true
			else cancelled=true;op.result={ok=false,error='native_timer_start_refused'}end
		end
		acquiring=false
		if handle then if cancelled then retire()elseif early then fired()end end
		return op
	end
	return port
end
return M
