--- tests/unit/modules/llm/test_runtime_owned_timer.lua

--- ==============================================================================
--- MODULE: Registered Ollama Runtime Regression Cases
--- DESCRIPTION:
--- Preserves independent controlled receipts through the normal Linux helpers.
--- Actual filesystem/process/serve/UI acceptance remains a separate gate.
--- ==============================================================================

local helpers = require("tests.helpers")
local names = {"llm.bootstrap_budget", "llm.runtime_repair", "modules.llm.runtime_source", "modules.llm.owned_timer", "modules.llm.runtime_composition", "infra.logger", "logger.shim", "infra.i18n", "llm.profile_selector", "infra.llm_bridge", "infra.manifest_reader", "infra.config_paths", "config_outdated", "toml_codec.writer", "infra.llm_preferences", "modules.llm.profiles"}
local previous = {}
for _, name in ipairs(names) do previous[name] = package.loaded[name] end
local function run_registered()
local Timer = helpers.load_module("modules.llm.owned_timer")
local function eq(a,b)assert(a==b,'expected '..tostring(b)..' got '..tostring(a))end
local function test(name, body) helpers.it(name .. " (ollama-runtime)", body) end
local function world()
	local w={handle={},calls=0,events={},now=123000000}
	local n={}
	function n.new_timer()if w.throw_create then error('unknown')end;if w.nil_create then return nil,'refused'end;return w.handle end
	function n.timer_stop(handle)eq(handle,w.handle);if w.stop_false then return false end;return 0 end
	function n.is_closing(handle)eq(handle,w.handle);return w.closing==true end
	function n.close(handle,cb)
		eq(handle,w.handle);w.close_count=(w.close_count or 0)+1
		if w.close_false then return false end
		w.closing=true;w.close_callback=cb
		if w.sync_close then cb()end
		if w.throw_close then error('after scheduled')end
	end
	function n.hrtime()return w.now end
	local arm={}
	function arm.start(native,handle,delay,repeating,cb)
		eq(native,n);eq(handle,w.handle);eq(repeating,0);w.delay=delay;w.fire=cb
		if w.early then cb()end
		if w.start_false then return false end
		return 0
	end
	w.port=Timer.new(n,arm)
	function w:start(delay)self.op=self.port.after(delay or 10,function()self.calls=self.calls+1;if self.observer then self.observer()end end);return self.op end
	function w:close()self.close_callback()end
	return w
end
test('monotonic clock milliseconds',function()eq(world().port.now_ms(),123)end)
test('positive one-shot start captured',function()local w=world();local o=w:start();eq(o.started,true);eq(w.delay,10);eq(o:is_settled(),false)end)
test('deadline delivery precedes physical close acknowledgment',function()local w=world();local o=w:start();w.fire();eq(w.calls,1);eq(o:is_settled(),false);w:close();eq(o:is_settled(),true)end)
test('cancel scheduling never pretends physical closure',function()local w=world();local o=w:start();eq(o:cancel(),false);w.fire();eq(w.calls,0);w:close();eq(o:cancel(),true)end)
test('duplicate deadline callback delivered once',function()local w=world();w:start();w.fire();w.fire();eq(w.calls,1)end)
test('exact closing request not repeated',function()local w=world();local o=w:start();o:cancel();o:cancel();eq(w.close_count,1)end)
test('close refusal retains exact handle for retry',function()local w=world();w.close_false=true;local o=w:start();eq(o:cancel(),false);w.close_false=false;eq(o:cancel(),false);eq(w.close_count,2);w:close();eq(o:is_settled(),true)end)
test('foreign native close is not our acknowledgment',function()local w=world();local o=w:start();w.closing=true;eq(o:cancel(),false);eq(w.close_count,nil);eq(o:is_settled(),false)end)
test('throwing close still needs original callback',function()local w=world();w.throw_close=true;local o=w:start();eq(o:cancel(),false);eq(o:is_settled(),false);eq(o:cancel(),false);w:close();eq(o:is_settled(),true)end)
test('throwing creation retains unknown debt',function()local w=world();w.throw_create=true;local o=w:start();eq(o:cancel(),false);eq(o:is_settled(),false);eq(o.cleanup_error,'native_timer_acquisition_unknown')end)
test('literal nil native refusal acquires no handle',function()local w=world();w.nil_create=true;local o=w:start();eq(o:is_settled(),true);eq(w.close_count,nil)end)
test('start refusal closes acquired handle physically',function()local w=world();w.start_false=true;local o=w:start();eq(o.started,false);eq(o:is_settled(),false);w:close();eq(o:is_settled(),true)end)
test('early native callback stages until exact timer acquired',function()local w=world();w.early=true;local o=w:start();eq(w.calls,1);eq(o:is_settled(),false);w:close();eq(o:is_settled(),true)end)
test('synchronous close settlement retained',function()local w=world();w.sync_close=true;local o=w:start();eq(o:cancel(),true);eq(o:is_settled(),true)end)
test('stop refusal cannot weaken exact physical close',function()local w=world();w.stop_false=true;local o=w:start();o:cancel();eq(o:is_settled(),false);w:close();eq(o:is_settled(),true)end)
test('settled observers are physical and one shot',function()local w=world();local o=w:start();local count=0;o:on_settled(function()count=count+1 end);o:cancel();eq(count,0);w:close();w:close();eq(count,1)end)
test('late settled listener receives exact acknowledgment',function()local w=world();w.sync_close=true;local o=w:start();o:cancel();local count=0;o:on_settled(function()count=count+1 end);eq(count,1)end)
test('deadline observer exceptions do not suppress cleanup',function()local w=world();w.observer=function()error('fixture')end;local o=w:start();w.fire();w:close();eq(o:is_settled(),true);eq(o.observer_error,'native_timer_observer_refused')end)
test('invalid delay refuses without allocation',function()local w=world();local o=w.port.after(0,function()end);eq(o:is_settled(),true);eq(o.started,false);eq(w.close_count,nil)end)
test('malformed clock refuses',function()local w=world();w.now=0/0;eq(pcall(w.port.now_ms),false)end)

end
local called, detail = pcall(run_registered)
for _, name in ipairs(names) do package.loaded[name] = previous[name] end
if not called then error(detail, 0) end
