--- tests/unit/modules/test_key_combinations.lua

--- Controlled production composition; no device, process or IO port is claimed native.
local helpers = require("tests.helpers")
local assert_false = function(value, message) helpers.assert_eq(value, false, message) end
local Owner = require("modules.shortcuts.key_combinations")
local Engine = require("platform.remap.tap_hold_engine")
local Native = require("platform.remap.key_combination_engine")
local catalog = {}; for _, id in ipairs({ "caps_lock", "tab", "left_shift", "left_alt", "space" }) do catalog[#catalog + 1] = { id = id, key = id } end
local path, binding = "/controlled/config.toml", "combination__caps_lock_then_tab"
local base_text = '[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "run_program"\n[shortcuts.key_combination_holds]\ncaps_lock_then_tab = "shift"\n[gesture_parameters]\ncombination__caps_lock_then_tab__run_program = "executableargvv1:controlled"\n'
local function make(text, keys, changed)
	local state = { bytes = text or base_text, paused = false, route = path }
	state.owner = Owner.new({ keys = catalog, hold_picker = { modifiers = { "ctrl", "shift", "alt" }, layers = { "nav" } },
		files = { read_with_status = function() if state.on_read then state.on_read() end; return state.bytes, "ok" end }, route = function() return state.route end,
		is_paused = function() return state.paused end, changed = changed or function() return true end,
		actions = { is_assignable = function(action) return action == "run_program" or action == "copy" end } })
	local base = Engine.new({ keys = keys or { caps_lock = { tap_action = "enter", hold_modifier = "ctrl", time_activation_seconds = .3 } },
		tap_min_ms = 0, one_shot_timeout_ms = 1000 })
	local thresholds = {}; for _, row in ipairs(catalog) do thresholds[row.id] = 300 end
	state.base, state.native = base, Native.new(base, state.owner.engine_options(thresholds))
	return state
end
local function origin(generation, source, physical)
	return { ready = true, generation = generation or 7, source = source or "owned-keyboard", physical = physical ~= false }
end
local function rows(events)
	local text = {}; for _, row in ipairs(events or {}) do text[#text + 1] = row.code .. ":" .. row.value end; return table.concat(text, " ")
end
local function process(state, code, value, at_ms, receipt)
	return state.native:process(code, value, at_ms, receipt or origin())
end
local function take(state)
	process(state, 58, 1, 0)
	local out, action, slot, frame = process(state, 15, 1, 10)
	helpers.assert_eq(rows(out), "42:1")
	helpers.assert_eq(action, nil)
	helpers.assert_true(frame.ack(true))
	return frame
end
helpers.describe("configured Linux ordered pair ownership", function()
	helpers.it("reads canonical shared pair slots and exact action source parameters", function()
		local state = make(); helpers.assert_true(state.owner.has_bindings())
		helpers.assert_eq(state.owner.get_action("caps_lock_then_tab"), "run_program")
		helpers.assert_eq(state.owner.configuration_domain(binding), "combination")
		local guard = state.owner.capture_action(binding,"run_program"); helpers.assert_true(guard())
		state.bytes = state.bytes:gsub("executableargvv1:controlled", "executableargvv1:changed")
		assert_false(guard(), "parameter bytes are part of canonical source authority")
	end)
	helpers.it("refuses rerouted source and foreign binding identities", function()
		local state = make(); local guard = state.owner.capture_action(binding,"run_program")
		state.route = "/other/config.toml"; assert_false(guard())
		helpers.assert_eq(state.owner.configuration_domain("combination__unknown_then_tab"),nil)
	end)
	helpers.it("retains a refused configuration lease and retries the exact token", function()
		local accepted = false; local state = make(nil,nil,function() return accepted end); local exact, foreign = {}, {}
		assert_false(state.owner.acquire_configuration(exact)); helpers.assert_true(state.owner.configuration_pending())
		helpers.assert_eq(state.owner.capture_action(binding,"run_program"),nil)
		assert_false(state.owner.acquire_configuration(foreign)); assert_false(state.owner.release_configuration(foreign))
		accepted = true; helpers.assert_true(state.owner.acquire_configuration(exact)); helpers.assert_true(state.owner.release_configuration(exact))
		assert_false(state.owner.configuration_pending())
	end)
	helpers.it("fences reentrant configuration acquisition before the native callback", function()
		local state, entered; state = make(nil,nil,function()
			entered = state.owner.capture_runtime() == nil and state.owner.acquire_configuration({}) == false
			return true
		end)
		local token = {}; helpers.assert_true(state.owner.acquire_configuration(token)); helpers.assert_true(entered)
		helpers.assert_true(state.owner.release_configuration(token))
	end)
	helpers.it("lifts only the first owned hold before action and restores afterward", function()
		local state = make(); take(state)
		local out, action, slot, frame = process(state,15,0,100)
		helpers.assert_eq(rows(out),"42:0 29:0"); helpers.assert_eq(action,"run_program"); helpers.assert_eq(slot,binding)
		helpers.assert_true(frame.ack(true)); local called = false
		helpers.assert_true(frame.run(function(a,b) called = a == action and b == binding; helpers.assert_eq(state.base.key_refs[29],nil) end,origin()))
		helpers.assert_true(called)
		local restored, ack = frame.restore(origin()); helpers.assert_eq(rows(restored),"29:1"); helpers.assert_true(ack.ack(true))
		helpers.assert_eq(rows(process(state,58,0,150)),"29:0", "first tap remains cancelled")
	end)
	helpers.it("does not lift another owner's reference to the same modifier", function()
		local state = make(nil,{ caps_lock = { tap_action="enter",hold_modifier="ctrl",time_activation_seconds=.3 },
			left_shift = { tap_action="copy",hold_modifier="ctrl",time_activation_seconds=.3 } })
		process(state,42,1,0); take(state)
		local out,_,_,frame = process(state,15,0,100); helpers.assert_eq(rows(out),"42:0")
		helpers.assert_eq(state.base.key_refs[29],1); helpers.assert_true(frame.ack(true))
		frame.run(function() helpers.assert_eq(state.base.key_refs[29],1) end,origin())
		local restored = frame.restore(origin()); helpers.assert_eq(rows(restored),"")
	end)
	helpers.it("does not restore a first press that was physically released", function()
		local state = make(); take(state); process(state,58,0,40)
		local out,_,_,frame = process(state,15,0,100); helpers.assert_eq(rows(out),"42:0")
		helpers.assert_true(frame.ack(true)); frame.run(function() end,origin())
		local restored = frame.restore(origin()); helpers.assert_eq(rows(restored),"")
	end)
	helpers.it("lifts and restores the first owned navigation layer", function()
		local text = base_text:gsub("caps_lock_then_tab", "left_alt_then_tab")
		local state = make(text,{ left_alt = {tap_action="backspace",hold_layer="nav",time_activation_seconds=.3} })
		process(state,56,1,0); helpers.assert_eq(state.base.layer_depth,1)
		local out,_,_,frame = process(state,15,1,10); helpers.assert_true(frame.ack(true))
		out,_,_,frame = process(state,15,0,100); helpers.assert_eq(state.base.layer_depth,0); helpers.assert_true(frame.ack(true))
		frame.run(function() helpers.assert_eq(state.base.layer_depth,0) end,origin()); frame.restore(origin())
		helpers.assert_eq(state.base.layer_depth,1)
	end)
	helpers.it("cancels a held pair tap on an unrelated physical key", function()
		local state = make(); take(state); process(state,30,1,20)
		local out,action,_,frame = process(state,15,0,100); helpers.assert_eq(rows(out),"42:0"); helpers.assert_eq(action,nil); helpers.assert_true(frame.ack(true))
	end)
	helpers.it("fires a tap-only pair at down and repeat with the canonical binding", function()
		local state = make(base_text:gsub('caps_lock_then_tab = "shift"','caps_lock_then_tab = "none"'))
		process(state,58,1,0)
		for _, sample in ipairs({ {1,10}, {2,50} }) do
			local out,action,slot,frame = process(state,15,sample[1],sample[2]); helpers.assert_eq(action,"run_program"); helpers.assert_eq(slot,binding)
			helpers.assert_true(frame.ack(true)); frame.run(function() end,origin()); local restored, ack = frame.restore(origin()); if ack then helpers.assert_true(ack.ack(true)) end
		end
		local _,action,_,frame = process(state,15,0,100); helpers.assert_eq(action,nil); helpers.assert_true(frame.ack(true))
	end)
	helpers.it("refuses a cross-keyboard pair and a duplicate-code source collision", function()
		local state = make(); process(state,58,1,0)
		local _,action,_,frame = process(state,15,1,10,origin(7,"other-keyboard")); helpers.assert_eq(action,nil); helpers.assert_eq(frame,nil)
		helpers.assert_eq(rows(process(state,58,1,20,origin(7,"other-keyboard"))),"")
		helpers.assert_eq(rows(process(state,58,0,30,origin(7,"other-keyboard"))),"")
		helpers.assert_true(state.base.held[58] ~= nil)
	end)
	helpers.it("does not admit combinations from a virtual source", function()
		local state = make(); process(state,58,1,0,origin(7,nil,false))
		local _,action,_,frame = process(state,15,1,10,origin(7,nil,false)); helpers.assert_eq(action,nil); helpers.assert_eq(frame,nil)
	end)
	helpers.it("retires instead of acknowledging late focus after canonical mutation", function()
		local state = make(); take(state); state.bytes = state.bytes .. "\n# source changed\n"
		local out,action,_,frame = process(state,15,0,100); helpers.assert_eq(action,nil)
		helpers.assert_true(rows(out):find("29:0",1,true) ~= nil); helpers.assert_true(rows(out):find("42:0",1,true) ~= nil)
		helpers.assert_true(frame.ack(true))
	end)
	helpers.it("retires on physical generation revocation without action", function()
		local state = make(); take(state); local out,action,_,frame = process(state,15,0,100,origin(8))
		helpers.assert_eq(action,nil); helpers.assert_true(#out == 2); helpers.assert_true(frame.ack(true))
	end)
	helpers.it("retains a refused native lift and exact retirement rows", function()
		local state = make(); take(state); local _,_,_,frame = process(state,15,0,100)
		assert_false(frame.ack(false)); assert_false(state.native:activate())
		local exact = state.native:release_all(); helpers.assert_true(#exact == 2); helpers.assert_eq(state.native:release_all(),exact)
		assert_false(state.native:ack_retirement(nil)); assert_false(state.native:activate())
		helpers.assert_true(state.native:ack_retirement(true)); helpers.assert_true(state.native:activate())
	end)
	helpers.it("blocks a reentrant successor until the action frame has returned", function()
		local state = make(); take(state); local _,_,_,frame = process(state,15,0,100); helpers.assert_true(frame.ack(true))
		frame.run(function() state.native:release_all(); assert_false(state.native:ack_retirement(true)); assert_false(state.native:activate()) end,origin())
		local restored = frame.restore(origin()); helpers.assert_eq(rows(restored),""); helpers.assert_true(state.native:ack_retirement(true))
	end)
	helpers.it("rejects an undecided roll as first key without advancing its timeline", function()
		local state = make(base_text:gsub("caps_lock_then_tab","space_then_tab"),{ space={tap_action="",hold_modifier="ctrl",time_activation_seconds=.3} })
		-- Roll policy is set only by the native loader; this independent base
		-- makes that actual pending state rather than inventing a policy event.
		state.base.by_code[57].roll = true
		process(state,57,1,0); helpers.assert_true(state.base.held[57].undecided)
		local _,action,_,frame = process(state,15,1,10); helpers.assert_eq(action,nil); helpers.assert_eq(frame,nil)
	end)
	helpers.it("preserves the original three-value binding on native roll replay", function()
		local base = Engine.new({ keys={space={tap_action="",hold_modifier="ctrl",time_activation_seconds=.3},win={tap_action="run_program",time_activation_seconds=.3}},roll_keys={"space"},tap_min_ms=0,one_shot_timeout_ms=1000 })
		base:process(57,1,0); base:process(125,1,10)
		local due = base:tick(301); local found = false
		for _, row in ipairs(due) do if row.tap == "run_program" then found = row.binding == "tap_hold__win" end end
		helpers.assert_true(found)
	end)
end)

local function protected_modules(replacements, callback)
	local previous = {}; for name, module in pairs(replacements) do previous[name] = { package.loaded[name] }; package.loaded[name] = module end
	local ok, err = pcall(callback)
	for name, old in pairs(previous) do package.loaded[name] = old[1] end
	if not ok then error(err,0) end
end
helpers.describe("ordered pairs through actual native consumers", function()
	helpers.it("dispatches the action between acknowledged lift and restore in the actual hook", function()
		local state = make(); local emitted, observed = {}, false
		protected_modules({ ["adapters.keyboard_hook"] = false, ["modules.hotstrings.device_finder"] = { physical_sources = function(devices)
			local out = {}; for _, device in ipairs(devices) do out[#out + 1] = { path=device,sysfs="/controlled/physical",name="controlled",physical=true } end; return out
		end } }, function()
			local hook = helpers.load_module("adapters.keyboard_hook")
			helpers.assert_true(hook.set_remapper(state.native,function(action,slot)
				observed = action == "run_program" and slot == binding and not hook.held_modifiers().ctrl
				emitted[#emitted + 1] = "action"
			end))
			hook._test_drive({ {type=1,code=58,value=1,at_ms=0},{type=1,code=15,value=1,at_ms=10},
				{type=1,code=15,value=0,at_ms=100},{type=1,code=58,value=0,at_ms=150} },
				{onEmitRaw=function(code,value) emitted[#emitted + 1] = code .. ":" .. value; return true end},true)
			helpers.assert_true(observed)
			helpers.assert_eq(table.concat(emitted," "),"29:1 42:1 42:0 29:0 action 29:1 29:0")
		end)
	end)
	helpers.it("builds pairs from actual loader state without disabling them with tap-holds", function()
		local Loader = require("platform.remap.tap_hold_loader")
		local defaults = require("infra.paths").shared("tap_hold/defaults.toml")
		local loaded = Loader.load_document(defaults,{ tap_hold={enabled=false,inherit_defaults=true} },nil,"/controlled/tap_hold.toml")
		local hook = {}; hook.set_remapper = function(engine,callback) hook.engine,hook.on_tap = engine,callback; return true end
		for _, name in ipairs({"key_text","held_modifiers","held_text_modifier_codes","held_shortcut_modifier_codes"}) do hook[name] = function() return {} end end
		protected_modules({ ["modules.shortcuts.key_combinations"] = false, ["platform.remap.tap_hold_manager"] = false, ["platform.remap.tap_hold_loader"]={ FALLBACK_THRESHOLD_SECONDS=Loader.FALLBACK_THRESHOLD_SECONDS, load=function() return loaded end },
			["platform.remap.nav_layer"]={load=function() return {} end},
			["adapters.file_system"]={read_with_status=function() return base_text,"ok" end},
			["infra.config_paths"]={config=function() return path end} },function()
			-- The owner must capture these actual declared ports before the manager
			-- requires it; previous cache identity is restored by the outer guard.
			local manager = require("platform.remap.tap_hold_manager")
			manager.init({keyboard_hook=hook,execute_action=function() end,action_names=function() return {"run_program"} end,
				on_text_injected=function() end,defaults_path=defaults,user_path="/controlled/tap_hold.toml"})
			helpers.assert_true(manager.is_active()); helpers.assert_true(hook.engine.has_combinations ~= nil)
			helpers.assert_eq(next(hook.engine.by_code),nil,"tap-hold configuration switch stays independent")
			local out = hook.engine:process(58,1,0,origin()); helpers.assert_eq(out,nil)
			local _,action,_,frame = hook.engine:process(15,1,10,origin()); helpers.assert_eq(action,nil); helpers.assert_true(frame.ack(true))
			local _,tap,slot = hook.engine:process(15,0,100,origin()); helpers.assert_eq(tap,"run_program"); helpers.assert_eq(slot,binding)
		end)
	end)
end)
helpers.describe("combination binding canonical program dispatch",function()
	helpers.it("uses the actual manager parameter source guard and blocks source changes",function()
		local scalar = '{"version":1,"executable":"/controlled/program","arguments":["literal argument"]}'
		local text = '[shortcuts.key_combination_taps]\ncaps_lock_then_tab="run_program"\n[shortcuts.key_combination_holds]\ncaps_lock_then_tab="shift"\n[gesture_parameters]\n' .. binding .. '__run_program=\'' .. scalar .. '\'\n'
		local state = make(text); local captured, admission
		local prior_open = io.open
		io.open = function(name,mode)
			if name == path and mode == "r" then return {read=function() return state.bytes end,close=function() return true end} end
			return prior_open(name,mode)
		end
		local ok,err = pcall(function()
			protected_modules({ ["modules.gestures.manager"]=false,
				["adapters.file_system"]={read_with_status=function() return state.bytes,"ok" end},
				["modules.shortcuts.key_combinations"]={ get_action=state.owner.get_action,capture_action=state.owner.capture_action },
				["modules.gestures.program_owner"]={new=function(capture) return {
					stop=function() return true end,run=function(slot) captured,admission = capture(slot); return captured ~= nil and admission() == true end,
				} end},
				["adapters.window_switch"]={new=function() return {stop=function() return true end} end},
				["ui.gesture_conflicts"]={notify_boot=function() end},
			},function()
				local manager = require("modules.gestures.manager")
				manager.init({persist=true,enabled=false,config_path=path,is_paused=function() return state.paused end})
				helpers.assert_eq(manager.get_action_parameter(binding,"run_program"),scalar)
				helpers.assert_true(manager.run_program(binding)); helpers.assert_eq(captured,scalar)
				state.bytes = state.bytes .. "\n# edited after capture\n"
				assert_false(admission(),"actual manager cannot keep a stale pair source alive")
			end)
		end)
		io.open = prior_open
		if not ok then error(err,0) end
	end)
end)
helpers.describe("pair native receipt refusal boundaries",function()
	helpers.it("never invokes action or modal after a refused real hook output port",function()
		local state = make(); local actions, modal = 0,0
		protected_modules({ ["adapters.keyboard_hook"]=false,["modules.hotstrings.device_finder"]={physical_sources=function(devices)
			local out={};for _, device in ipairs(devices) do out[#out+1]={path=device,sysfs="/controlled/physical",name="controlled",physical=true} end;return out
		end} },function()
			local hook = require("adapters.keyboard_hook")
			helpers.assert_true(hook.set_remapper(state.native,function() actions=actions+1 end))
			hook._test_drive({{type=1,code=58,value=1,at_ms=0},{type=1,code=15,value=1,at_ms=10},{type=1,code=15,value=0,at_ms=100}},
				{onEmitRaw=function(code,value) return not (code==42 and value==1) end},true)
			helpers.assert_eq(actions,0)
			local exact = state.native:release_all(); helpers.assert_eq(state.native:release_all(),exact)
			helpers.assert_true(#exact > 0)
			assert_false(hook.set_remapper(nil),"refused retirement blocks replacement")
			hook.while_released(function() modal=modal+1 end)
			helpers.assert_eq(modal,0,"modal acquisition cannot discard native debt")
		end)
	end)
	helpers.it("suppresses reentrant physical release restoration after the action retires ownership",function()
		local state=make();take(state)
		local _,_,_,frame=process(state,15,0,100);helpers.assert_true(frame.ack(true))
		frame.run(function() process(state,58,0,110) end,origin())
		local restored=frame.restore(origin());helpers.assert_eq(rows(restored),"")
		helpers.assert_true(state.native:ack_retirement(true))
	end)
	helpers.it("retires held pair output on pause during the periodic native tick",function()
		local state=make();take(state);state.paused=true
		local due=state.native:tick(100);helpers.assert_eq(#due,1);helpers.assert_true(#due[1].owned_rows==2)
		helpers.assert_true(due[1].frame.ack(true));helpers.assert_eq(state.owner.capture_runtime(),nil,"pending desired pause still refuses action admission")
	end)
end)
helpers.describe("configured pair publication lifecycle",function()
	helpers.it("refreshes copied native slots only after exact retirement before owned publication release",function()
		local Loader=require("platform.remap.tap_hold_loader")
		local defaults=require("infra.paths").shared("tap_hold/defaults.toml")
		local loaded=Loader.load_document(defaults,{tap_hold={enabled=true,inherit_defaults=true}},nil,"/controlled/tap_hold.toml")
		local bytes=base_text
		local hook={};hook.set_remapper=function(engine,callback)
			if hook.engine and hook.engine.has_combinations then
				hook.engine:release_all(); if hook.engine:ack_retirement(true)~=true then return false end
			elseif hook.engine then hook.engine:release_all() end
			if engine and engine.activate and engine:activate()~=true then return false end
			hook.engine,hook.on_tap=engine,callback;return true
		end
		for _,name in ipairs({"key_text","held_modifiers","held_text_modifier_codes","held_shortcut_modifier_codes"}) do hook[name]=function() return {} end end
		protected_modules({["modules.shortcuts.key_combinations"]=false,["platform.remap.tap_hold_manager"]=false,
			["platform.remap.tap_hold_loader"]={FALLBACK_THRESHOLD_SECONDS=Loader.FALLBACK_THRESHOLD_SECONDS,load=function() return loaded end},
			["platform.remap.nav_layer"]={load=function() return {} end},["adapters.file_system"]={read_with_status=function() return bytes,"ok" end},
			["infra.config_paths"]={config=function() return path end}},function()
			local manager=require("platform.remap.tap_hold_manager")
			helpers.assert_true(manager.init({keyboard_hook=hook,execute_action=function() end,action_names=function() return {"run_program","copy"} end,
				on_text_injected=function() end,defaults_path=defaults,user_path="/controlled/tap_hold.toml"}))
			local pairs=require("modules.shortcuts.key_combinations");local token={}
			helpers.assert_true(pairs.acquire_configuration(token));helpers.assert_eq(hook.engine,nil)
			local next_text=bytes:gsub('caps_lock_then_tab = "run_program"','caps_lock_then_tab = "copy"'):gsub('caps_lock_then_tab = "shift"','caps_lock_then_tab = "alt"')
			local selected=pairs.configuration_candidate(require("toml_codec").decode(next_text),true)
			helpers.assert_true(pairs.apply_configuration(token,selected));helpers.assert_eq(hook.engine,nil,"unpublished candidate cannot receive physical input")
			bytes=next_text
			helpers.assert_true(pairs.release_configuration(token));helpers.assert_true(hook.engine~=nil)
			hook.engine:process(58,1,0,origin())
			local out,action,_,frame=hook.engine:process(15,1,10,origin())
			helpers.assert_eq(rows(out),"56:1","new Alt hold must replace the old Shift snapshot")
			helpers.assert_eq(action,nil);helpers.assert_true(frame.ack(true))
			local _,tap,slot,release=hook.engine:process(15,0,100,origin())
			helpers.assert_eq(tap,"copy");helpers.assert_eq(slot,binding);helpers.assert_true(release.ack(true))
			for _,unsupported in ipairs({"one_shot_shift","caps_word"}) do
				local accepted=pcall(pairs.configuration_candidate,require("toml_codec").decode(next_text:gsub('"copy"','"'..unsupported..'"')),true)
				assert_false(accepted,"native-only tap state must not be claimed as a dispatched pair action")
			end
		end)
	end)
end)
helpers.describe("pair source and restoration refusals",function()
	helpers.it("refuses malformed source after installation and forwards unrelated grabbed input",function()
		local state=make();state.bytes='[shortcuts.key_combination_taps\n'
		protected_modules({["adapters.keyboard_hook"]=false,["modules.hotstrings.device_finder"]={physical_sources=function(devices)
			local out={};for _,device in ipairs(devices) do out[#out+1]={path=device,sysfs="/controlled/physical",name="controlled",physical=true} end;return out
		end}},function()
			local hook=require("adapters.keyboard_hook");local emitted,actions={},0
			helpers.assert_true(hook.set_remapper(state.native,function() actions=actions+1 end))
			hook._test_drive({{type=1,code=30,value=1,at_ms=0},{type=1,code=30,value=0,at_ms=10}},
				{onEmitRaw=function(code,value) emitted[#emitted+1]=code..":"..value;return true end},true)
			helpers.assert_eq(table.concat(emitted," "),"30:1 30:0");helpers.assert_eq(actions,0)
		end)
	end)
	helpers.it("keeps canonical unreadable startup neutral and baseline construction valid",function()
		local owner=Owner.new({keys=catalog,hold_picker={modifiers={"ctrl"},layers={"nav"}},
			files={read_with_status=function() error("PRIVATE SOURCE ERROR") end},route=function() return path end,
			is_paused=function() return false end,changed=function() return true end,actions={is_assignable=function() return true end}})
		assert_false(owner.has_bindings());helpers.assert_eq(owner.capture_runtime(),nil)
	end)
	helpers.it("retains a refused restore without acknowledging a successor",function()
		local state=make();take(state);local _,_,_,frame=process(state,15,0,100);helpers.assert_true(frame.ack(true))
		frame.run(function() end,origin());local out,restore=frame.restore(origin());helpers.assert_eq(rows(out),"29:1")
		assert_false(restore.ack(false));assert_false(state.native:activate())
		local retirement=state.native:release_all();helpers.assert_eq(rows(retirement),"29:0")
		assert_false(state.native:ack_retirement(false));helpers.assert_eq(state.native:release_all(),retirement)
		helpers.assert_true(state.native:ack_retirement(true))
	end)
	helpers.it("contains a throwing action while restoring only the same live first press",function()
		local state=make();take(state);local _,_,_,frame=process(state,15,0,100);helpers.assert_true(frame.ack(true))
		assert_false(frame.run(function() error("CONTROLLED CALLBACK REFUSAL") end,origin()))
		local restored,ack=frame.restore(origin());helpers.assert_eq(rows(restored),"29:1");helpers.assert_true(ack.ack(true))
	end)
	helpers.it("refuses a post-read route change under the exact returned source guard",function()
		local route,change=path,false
		local owner=Owner.new({keys=catalog,hold_picker={modifiers={"ctrl","shift"},layers={"nav"}},
			files={read_with_status=function() if change then route="/foreign/config.toml" end;return base_text,"ok" end},route=function() return route end,
			is_paused=function() return false end,changed=function() return true end,actions={is_assignable=function() return true end}})
		local guard=owner.capture_runtime();helpers.assert_true(guard());change=true
		assert_false(guard(),"post-read route must still be the exact captured source")
	end)
end)
helpers.describe("independent pair enablement across empty configuration",function()
	helpers.it("installs the first pair and re-installs after last deletion with tap-holds disabled",function()
		local Loader=require("platform.remap.tap_hold_loader")
		local defaults=require("infra.paths").shared("tap_hold/defaults.toml")
		local loaded=Loader.load_document(defaults,{tap_hold={enabled=false,inherit_defaults=true}},nil,"/controlled/tap_hold.toml")
		local bytes='[shortcuts.key_combination_taps]\n[shortcuts.key_combination_holds]\n'
		local hook={};hook.set_remapper=function(engine,callback)
			if hook.engine and hook.engine.has_combinations then hook.engine:release_all();if hook.engine:ack_retirement(true)~=true then return false end
			elseif hook.engine then hook.engine:release_all() end
			if engine and engine.activate and engine:activate()~=true then return false end
			hook.engine,hook.on_tap=engine,callback;return true
		end
		for _,name in ipairs({"key_text","held_modifiers","held_text_modifier_codes","held_shortcut_modifier_codes"}) do hook[name]=function() return {} end end
		protected_modules({["modules.shortcuts.key_combinations"]=false,["platform.remap.tap_hold_manager"]=false,
			["platform.remap.tap_hold_loader"]={FALLBACK_THRESHOLD_SECONDS=Loader.FALLBACK_THRESHOLD_SECONDS,load=function() return loaded end},
			["platform.remap.nav_layer"]={load=function() return {} end},["adapters.file_system"]={read_with_status=function() return bytes,"ok" end},
			["infra.config_paths"]={config=function() return path end}},function()
			local manager=require("platform.remap.tap_hold_manager")
			helpers.assert_true(manager.init({keyboard_hook=hook,execute_action=function() end,action_names=function() return {"run_program"} end,
				on_text_injected=function() end,defaults_path=defaults,user_path="/controlled/tap_hold.toml"}))
			helpers.assert_eq(hook.engine,nil)
			local pairs=require("modules.shortcuts.key_combinations")
			local function publish(text)
				local token={};helpers.assert_true(pairs.acquire_configuration(token))
				helpers.assert_true(pairs.apply_configuration(token,pairs.configuration_candidate(require("toml_codec").decode(text),true)))
				bytes=text;helpers.assert_true(pairs.release_configuration(token))
			end
			for cycle=1,2 do
				publish(base_text);helpers.assert_true(manager.is_active());helpers.assert_true(hook.engine.has_combinations~=nil)
				helpers.assert_eq(next(hook.engine.by_code),nil)
				hook.engine:process(58,1,0,origin());local _,_,_,frame=hook.engine:process(15,1,10,origin());helpers.assert_true(frame.ack(true))
				local _,action,slot,release=hook.engine:process(15,0,100,origin());helpers.assert_eq(action,"run_program");helpers.assert_eq(slot,binding);helpers.assert_true(release.ack(true))
				publish('[shortcuts.key_combination_taps]\n[shortcuts.key_combination_holds]\n');helpers.assert_eq(hook.engine,nil);assert_false(manager.is_active())
			end
		end)
	end)
end)
helpers.describe("pair external-boundary ownership",function()
	helpers.it("rechecks the exact frame after a guard retires and replaces its owner",function()
		local state=make();take(state);local _,_,_,frame=process(state,15,0,100);helpers.assert_true(frame.ack(true))
		state.on_read=function()
			state.on_read=nil;state.native:release_all();helpers.assert_true(state.native:ack_retirement(true));helpers.assert_true(state.native:activate())
			process(state,58,1,120)
		end
		local actions=0;assert_false(frame.run(function() actions=actions+1 end,origin()));helpers.assert_eq(actions,0)
		local restored=frame.restore(origin());helpers.assert_eq(rows(restored),"");helpers.assert_eq(state.base.key_refs[29],1)
	end)
	helpers.it("rechecks exact restoration ownership after native read reentrancy",function()
		local state=make();take(state);local _,_,_,frame=process(state,15,0,100);helpers.assert_true(frame.ack(true))
		helpers.assert_true(frame.run(function() end,origin()))
		state.on_read=function() state.on_read=nil;state.native:release_all();helpers.assert_true(state.native:ack_retirement(true));helpers.assert_true(state.native:activate());process(state,58,1,120) end
		local restored=frame.restore(origin());helpers.assert_eq(rows(restored),"");helpers.assert_eq(state.base.key_refs[29],1)
	end)
	helpers.it("resumes baseline letters after exact source-revocation retirement through the actual hook",function()
		local state=make();local emitted,actions={},0
		protected_modules({["adapters.keyboard_hook"]=false,["modules.hotstrings.device_finder"]={physical_sources=function(devices)
			local out={};for _,device in ipairs(devices) do out[#out+1]={path=device,sysfs="/controlled/physical",name="controlled",physical=true} end;return out
		end}},function()
			local hook=require("adapters.keyboard_hook");helpers.assert_true(hook.set_remapper(state.native,function() actions=actions+1 end))
			hook._test_drive({{type=1,code=58,value=1,at_ms=0},{type=1,code=15,value=1,at_ms=10},
				{type=1,code=30,value=1,at_ms=20},{type=1,code=30,value=0,at_ms=30}},
				{onEmitRaw=function(code,value) emitted[#emitted+1]=code..":"..value;if code==42 and value==1 then state.bytes='[malformed\n' end;return true end},true)
			helpers.assert_eq(actions,0);helpers.assert_true(table.concat(emitted," "):find("30:1 30:0",1,true)~=nil)
			helpers.assert_eq(state.base.key_refs[29],nil);helpers.assert_eq(state.base.key_refs[42],nil)
		end)
	end)
	helpers.it("keeps baseline output acquisition owned during reentrant native retirement",function()
		local state=make();local accepted,entered
		protected_modules({["adapters.keyboard_hook"]=false,["modules.hotstrings.device_finder"]={physical_sources=function(devices)
			local out={};for _,device in ipairs(devices) do out[#out+1]={path=device,sysfs="/controlled/physical",name="controlled",physical=true} end;return out
		end}},function()
			local hook=require("adapters.keyboard_hook");helpers.assert_true(hook.set_remapper(state.native,function() error("stale action must not run") end))
			hook._test_drive({{type=1,code=58,value=1,at_ms=0}}, {onEmitRaw=function(code,value)
				if code==29 and value==1 and not entered then entered=true;accepted=hook.set_remapper(nil) end
				return true
			end},true)
			helpers.assert_true(entered);assert_false(accepted,"output syscall has not returned, so retirement cannot ACK")
			local exact=state.native:release_all();helpers.assert_eq(rows(exact),"29:0");helpers.assert_eq(state.native:release_all(),exact)
			assert_false(state.native:activate())
		end)
	end)
end)

-- Reentrant native getters must not acknowledge a newly fenced owner.
local function terminal_owner(port)
	local state = { armed = false, calls = 0, token = {}, acquired = false }
	local function boundary(name)
		if state.armed and name == port then
			state.calls = state.calls + 1
			if state.calls == 2 then
				state.acquired = state.owner.acquire_configuration(state.token)
			end
		end
	end
	state.owner = Owner.new({ keys = catalog, hold_picker = { modifiers = { "ctrl", "shift", "alt" }, layers = { "nav" } },
		files = { read_with_status = function() return base_text, "ok" end },
		route = function() boundary("route"); return path end,
		is_paused = function() boundary("pause"); return false end,
		changed = function() return true end,
		actions = { is_assignable = function(action) return action == "run_program" end } })
	state.base = Engine.new({ keys = { caps_lock = { tap_action = "enter", hold_modifier = "ctrl", time_activation_seconds = .3 } },
		tap_min_ms = 0, one_shot_timeout_ms = 1000 })
	local thresholds = {}; for _, row in ipairs(catalog) do thresholds[row.id] = 300 end
	state.native = Native.new(state.base, state.owner.engine_options(thresholds))
	return state
end
helpers.describe("pair terminal native getter currency", function()
	for _, port in ipairs({ "route", "pause" }) do
		for _, kind in ipairs({ "runtime", "action" }) do
			helpers.it("refuses " .. kind .. " admission when the final " .. port .. " callback acquires a lease", function()
				local state = terminal_owner(port)
				local guard = kind == "runtime" and state.owner.capture_runtime() or state.owner.capture_action(binding, "run_program")
				helpers.assert_true(type(guard) == "function"); state.armed = true
				local accepted = guard()
				helpers.assert_eq(state.calls, 2); helpers.assert_true(state.acquired)
				helpers.assert_true(state.owner.configuration_snapshot(state.token) ~= nil)
				assert_false(accepted, "native callback completed after the captured private currency")
				helpers.assert_true(state.owner.release_configuration(state.token))
			end)
		end
		helpers.it("vetoes actual native pair dispatch after final " .. port .. " reentry", function()
			local state = terminal_owner(port); take(state)
			local lifted, action, slot, frame = process(state, 15, 0, 100)
			helpers.assert_eq(rows(lifted), "42:0 29:0"); helpers.assert_eq(action, "run_program"); helpers.assert_eq(slot, binding)
			helpers.assert_true(frame.ack(true)); state.armed = true
			local calls = 0; local accepted = frame.run(function() calls = calls + 1 end, origin())
			helpers.assert_true(state.acquired); assert_false(accepted); helpers.assert_eq(calls, 0)
			helpers.assert_eq(state.base.key_refs[29], nil)
			helpers.assert_true(state.owner.configuration_snapshot(state.token) ~= nil)
		end)
		helpers.it("vetoes actual native hold restoration after final " .. port .. " reentry", function()
			local state = terminal_owner(port); take(state)
			local _, _, _, frame = process(state, 15, 0, 100); helpers.assert_true(frame.ack(true))
			helpers.assert_true(frame.run(function() end, origin())); state.armed = true
			local restored, receipt = frame.restore(origin())
			helpers.assert_true(state.acquired); helpers.assert_eq(rows(restored), ""); helpers.assert_eq(receipt, nil)
			helpers.assert_eq(state.base.key_refs[29], nil)
			helpers.assert_true(state.owner.configuration_snapshot(state.token) ~= nil)
		end)
	end
end)

helpers.describe("exact staged pair delivery fence",function()
	helpers.it("requires the exact configuration owner and rejects foreign editor and release tokens",function()
		local state=make();local exact,foreign={},{}
		assert_false(state.owner.acquire_delivery_fence(exact))
		helpers.assert_true(state.owner.acquire_configuration(exact))
		helpers.assert_true(state.owner.acquire_delivery_fence(exact))
		assert_false(state.owner.acquire_delivery_fence(foreign));assert_false(state.owner.release_delivery_fence(exact))
		helpers.assert_true(state.owner.release_configuration(exact))
		helpers.assert_eq(state.owner.capture_runtime(),nil);helpers.assert_eq(state.owner.capture_action(binding,"run_program"),nil)
		helpers.assert_eq(state.owner.capture_edit_source(),nil);helpers.assert_eq(state.owner.capture_edit_source(foreign),nil)
		local receipt=state.owner.capture_edit_source(exact);helpers.assert_true(receipt.guard())
		assert_false(state.owner.acquire_configuration(foreign));assert_false(state.owner.release_delivery_fence(foreign))
		helpers.assert_true(state.owner.release_delivery_fence(exact));assert_false(state.owner.owns_delivery_fence(exact))
		helpers.assert_true(state.owner.capture_runtime()() == true)
	end)
	helpers.it("opens delivery with a private-only ACK after staged installation",function()
		local calls=0;local state=make(nil,nil,function() calls=calls+1;return true end);local exact={}
		helpers.assert_true(state.owner.acquire_configuration(exact));helpers.assert_true(state.owner.acquire_delivery_fence(exact))
		helpers.assert_true(state.owner.release_configuration(exact));helpers.assert_eq(calls,2)
		helpers.assert_true(state.owner.release_delivery_fence(exact));helpers.assert_eq(calls,2,"opening delivery must not invoke native callbacks")
		take(state)
	end)
	helpers.it("retains both exact capabilities when staged installation refuses",function()
		local accepted=true;local state=make(nil,nil,function() return accepted end);local exact={}
		helpers.assert_true(state.owner.acquire_configuration(exact));helpers.assert_true(state.owner.acquire_delivery_fence(exact))
		accepted=false;assert_false(state.owner.release_configuration(exact))
		helpers.assert_true(state.owner.owns_configuration(exact));helpers.assert_true(state.owner.owns_delivery_fence(exact))
		assert_false(state.owner.release_delivery_fence(exact));helpers.assert_eq(state.owner.capture_runtime(),nil)
		accepted=true;helpers.assert_true(state.owner.release_configuration(exact));helpers.assert_true(state.owner.release_delivery_fence(exact))
		take(state)
	end)
end)

helpers.describe("pair source receipt after final native pause callback",function()
	for _,phase in ipairs({"editor","configuration","matches"}) do
		helpers.it("refuses a same-byte canonical route handoff in final "..phase.." pause getter",function()
			local route, armed, calls=path,false,0;local token={}
			local owner=Owner.new({keys=catalog,hold_picker={modifiers={"shift","alt"},layers={"nav"}},
				files={read_with_status=function() return base_text,"ok" end},route=function() return route end,
				is_paused=function()
					if armed then calls=calls+1;if calls==(phase=="editor" and 3 or 2) then route="/controlled/foreign.toml" end end
					return false
				end,changed=function() return true end,actions={is_assignable=function(action) return action=="run_program" end}})
			helpers.assert_true(owner.acquire_configuration(token));helpers.assert_true(owner.acquire_delivery_fence(token))
			if phase=="editor" then helpers.assert_true(owner.release_configuration(token)) end
			armed=true
			local receipt
			if phase=="editor" then receipt=owner.capture_edit_source(token)
			elseif phase=="configuration" then receipt=owner.configuration_source(token)
			else receipt=owner.configuration_source_matches(token,{path=path,status="ok",content=base_text}) end
			helpers.assert_eq(route,"/controlled/foreign.toml","The final native pause getter must cause the handoff")
			if phase=="matches" then assert_false(receipt) else helpers.assert_eq(receipt,nil) end
			helpers.assert_true(owner.owns_delivery_fence(token));helpers.assert_eq(owner.capture_runtime(),nil)
		end)
	end
end)

-- These controls use actual Hook/Reader/Writer/native pair consumers through the
-- explicitly controlled constructor. They provide no kernel or physical proof.
local InputOwnerFixture = require("tests.support.input_owner_fixture")
local function input_rows(session)
	local result = {}; for _, row in ipairs(session.rows) do result[#result + 1] = row[1] .. ":" .. row[2] end
	return table.concat(result, " ")
end
local prefix = "29:1 29:0 29:1 29:0"
local function arm_input(session)
	session.pair(); helpers.assert_true(session.armed)
	session.edge("a", 58, 0, 150)
end
helpers.describe("installed input-owner OneShot prerequisite (controlled ports)", function()
	helpers.it("arms only the acknowledged frame without reserving or writing output", function()
		InputOwnerFixture.with_session(nil, function(s)
			s.pair(); helpers.assert_eq(s.action, "one_shot_shift")
			helpers.assert_true(s.armed); helpers.assert_eq(s.before_arm_acquisitions, s.after_arm_acquisitions)
			helpers.assert_eq(input_rows(s), "29:1 29:0 29:1", "Only original frame lift/restore writes occur")
			helpers.assert_true(s.hook.input_owner_current(s.lease))
			helpers.assert_eq(s.hook.capture_input_owner(), nil, "No frame authority outside its callback")
			assert_false(s.hook.arm_one_shot(s.lease), "A used frame cannot arm twice")
		end)
	end)
	helpers.it("consumes exact Shift and key custody through DOWN repeat and final UP", function()
		InputOwnerFixture.with_session(nil, function(s)
			arm_input(s); s.edge("a", 30, 1, 200); s.edge("a", 30, 2, 210); s.edge("a", 30, 0, 250)
			helpers.assert_eq(input_rows(s), prefix .. " 42:1 30:1 30:2 30:0 42:0")
			helpers.assert_eq(#s.writer.output_view(s.output).down, 0); helpers.assert_eq(s.base:input_arm_state(), nil)
			assert_false(s.hook.input_owner_current(s.lease)); helpers.assert_true(s.hook.isRunning())
			s.edge("a", 30, 1, 300); s.edge("a", 30, 0, 350)
			helpers.assert_eq(input_rows(s), prefix .. " 42:1 30:1 30:2 30:0 42:0 30:1 30:0")
		end)
	end)
	helpers.it("rejects copied scalar Writer and ordinary Recorder authority", function()
		InputOwnerFixture.with_session(nil, function(s)
			for _, foreign in ipairs({ {}, { ready = true, source = s.paths.a, generation = 1 }, s.output, s.engine }) do
				assert_false(s.hook.arm_one_shot(foreign)); assert_false(s.hook.input_owner_current(foreign))
			end
			helpers.assert_eq(s.base.one_shot_until, nil)
			s.pair(); helpers.assert_true(s.armed)
			assert_false(s.hook.input_owner_current({})); s.lease.ready = true
			assert_false(s.hook.input_owner_current(s.lease))
		end)
		local broker = require("adapters.modifier_broker").controlled(); assert_false(broker.output_current())
	end)
	helpers.it("leaves ordinary custom Reader callbacks usable without issuing an input lease", function()
		InputOwnerFixture.with_session({ custom_reader = true }, function(s)
			s.pair(); helpers.assert_eq(s.action, "one_shot_shift"); helpers.assert_eq(s.lease, nil)
			assert_false(s.armed); helpers.assert_eq(s.base.one_shot_until, nil)
			s.edge("a", 58, 0, 150); s.edge("a", 30, 1, 200); s.edge("a", 30, 0, 250)
			helpers.assert_eq(input_rows(s), prefix .. " 30:1 30:0")
		end)
	end)
	helpers.it("expires on the original input clock and does not shift the later key", function()
		InputOwnerFixture.with_session(nil, function(s)
			arm_input(s); s.edge("a", 30, 1, 1200); s.edge("a", 30, 0, 1250)
			helpers.assert_eq(input_rows(s), prefix .. " 30:1 30:0"); helpers.assert_eq(s.base:input_arm_state(), nil)
		end)
	end)
	helpers.it("cancels cross-device consumption without admitting a pair or shifting its key", function()
		InputOwnerFixture.with_session(nil, function(s)
			arm_input(s); s.edge("b", 30, 1, 200); s.edge("b", 30, 0, 250)
			helpers.assert_eq(input_rows(s), prefix .. " 30:1 30:0"); helpers.assert_eq(s.base.one_shot_until, nil)
		end)
	end)
	for _, phase in ipairs({ "configuration", "output", "text", "plan" }) do
		helpers.it("joins actual Reader retirement after the final " .. phase .. " callback", function()
			local options, triggered = {}, false
			local function revoke(s)
				if s.revoke and not triggered then triggered = true; assert(s.reader.ungrab("keyboard:" .. s.paths.a)) end
			end
			options[({ configuration = "on_guard", output = "on_output_view", text = "on_text", plan = "on_plan" })[phase]] = revoke
			InputOwnerFixture.with_session(options, function(s)
				if phase == "configuration" or phase == "output" then
					options.on_action = function() s.revoke = true end
					s.pair(); helpers.assert_true(triggered); assert_false(s.armed); helpers.assert_eq(s.base.one_shot_until, nil)
				else
					arm_input(s); s.revoke = true; s.edge("a", 30, 1, 200)
					helpers.assert_true(triggered); helpers.assert_eq(input_rows(s), prefix, "No new DOWN from the retired source")
				end
			end)
		end)
	end
	helpers.it("blocks reentrant publication of the same frame while its guard is running", function()
		local options = {}; local observed
		options.on_guard = function(s)
			if s.reenter and s.lease and not observed then observed = { s.hook.arm_one_shot(s.lease) } end
		end
		options.on_action = function(s) s.reenter = true end
		InputOwnerFixture.with_session(options, function(s)
			s.pair(); helpers.assert_true(s.armed); helpers.assert_true(observed ~= nil); assert_false(observed[1])
			helpers.assert_eq(s.before_arm_acquisitions, s.after_arm_acquisitions)
		end)
	end)
	helpers.it("withdraws after acknowledged Shift DOWN and releases only its original holder", function()
		local options = {}; options.after_sync = function(s, code, value)
			if code == 42 and value == 1 then options.after_sync = nil; assert(s.reader.ungrab("keyboard:" .. s.paths.a)) end
		end
		InputOwnerFixture.with_session(options, function(s)
			arm_input(s); s.edge("a", 30, 1, 200)
			helpers.assert_eq(input_rows(s), prefix .. " 42:1 42:0")
			assert_false(s.hook.isRunning()); helpers.assert_eq(#s.writer.output_view(s.output).down, 0)
		end)
	end)
	helpers.it("retains debt and retires the original channel when inverse SYN is refused", function()
		local options = {}
		options.after_sync = function(s, code, value)
			if code == 42 and value == 1 then options.after_sync = nil; s.revoke = true; assert(s.reader.ungrab("keyboard:" .. s.paths.a)) end
		end
		options.fail_sync = function(s, code, value) return s.revoke and code == 42 and value == 0 end
		InputOwnerFixture.with_session(options, function(s)
			arm_input(s); s.edge("a", 30, 1, 200)
			helpers.assert_eq(input_rows(s), prefix .. " 42:1 42:0"); assert_false(s.hook.isRunning())
			helpers.assert_eq(s.writer.output_view(s.output), nil); helpers.assert_true(s.broker.has_debt())
		end)
	end)
	helpers.it("refuses the old broker after the actual Writer closes and reopens", function()
		InputOwnerFixture.with_session(nil, function(s)
			helpers.assert_true(s.broker.output_current()); helpers.assert_true(s.writer.close_owned(s.output))
			helpers.assert_true(s.writer.open()); local successor = assert(s.writer.capture_output())
			assert_false(s.broker.output_current()); s.pair(); helpers.assert_eq(s.armed, nil, "Stale output cannot acknowledge the action frame")
			helpers.assert_eq(s.base.one_shot_until, nil); helpers.assert_true(s.writer.output_view(successor) ~= nil)
			helpers.assert_true(s.writer.close_owned(successor))
		end)
	end)
	for _, replacement in ipairs({ "reader", "writer", "engine", "issuer", "lease", "configuration", "tap_hold_epoch", "classification", "hook" }) do
		helpers.it("refuses observed " .. replacement .. " replacement before a new DOWN", function()
			InputOwnerFixture.with_session(nil, function(s)
				arm_input(s)
				if replacement == "reader" then s.reader.source_current = function() return true end
				elseif replacement == "writer" then s.writer.output_view = function() return { down = {}, write_epoch = 4 } end
				elseif replacement == "engine" then s.base.plan_text = function() return { { keycode = 30, mods = { "shift" } } } end
				elseif replacement == "issuer" then require("platform.remap.key_combination_engine").input_owner_current = function() return true end
				elseif replacement == "lease" then setmetatable(s.lease, {})
				elseif replacement == "configuration" then s.paused = true
				elseif replacement == "classification" then require("modules.hotstrings.device_finder").physical_sources = function() return {} end
				elseif replacement == "hook" then s.hook.arm_one_shot = function() return true end
				else helpers.assert_true(s.engine:set_tap_holds_enabled(false)); helpers.assert_true(s.engine:set_tap_holds_enabled(true)) end
				assert_false(s.hook.input_owner_current(s.lease))
				s.edge("a", 30, 1, 200); s.edge("a", 30, 0, 250)
				for _, row in ipairs(s.rows) do helpers.assert_true(row[1] ~= 42, "Revoked input ownership cannot deliver a new synthetic Shift") end
			end)
		end)
	end
	helpers.it("keeps the consumed key's original output retirement after remapper withdrawal", function()
		local options = {}; options.after_sync = function(s, code, value)
			if code == 42 and value == 1 then options.after_sync = nil; s.hook.set_remapper(nil) end
		end
		InputOwnerFixture.with_session(options, function(s)
			arm_input(s); s.edge("a", 30, 1, 200)
			helpers.assert_eq(input_rows(s), prefix .. " 42:1 42:0")
			local view = s.writer.output_view(s.output)
			helpers.assert_true(view == nil or #view.down == 0, "Exact original output is settled or retired")
			assert_false(s.hook.input_owner_current(s.lease))
		end)
	end)
	helpers.it("an original observer refuses closed capability copies busy sessions and export rebinding", function()
		InputOwnerFixture.with_session(nil, function(s)
			local Custody = require("input.modifier_custody")
			local exact = Custody.new(s.writer, s.output); helpers.assert_true(exact.output_current())
			local copied = {}; local view = s.writer.output_view(s.output)
			helpers.assert_eq(Custody.new(s.writer, copied), nil)
			local session = assert(exact.begin()); assert_false(exact.output_current()); helpers.assert_true(session.finish())
			helpers.assert_true(exact.output_current()); local old = s.writer.output_view
			s.writer.output_view = function() return view end; assert_false(exact.output_current()); s.writer.output_view = old
			helpers.assert_true(exact.output_current())
		end)
	end)
	helpers.it("the original observer refuses a getter that reenters then returns its old view", function()
		InputOwnerFixture.with_session(nil, function(s)
			local Custody = require("input.modifier_custody"); local exact, reenter
			local original = s.writer.output_view
			local ports = { capture_output_observer = s.writer.capture_output_observer, output_view = function(cap)
				local view = original(cap)
				if reenter then reenter = false; local session = assert(exact.begin()); assert(session.finish()) end
				return view
			end }
			for _, name in ipairs({ "acquire_transaction", "transaction_view", "commit_transaction" }) do ports[name] = s.writer[name] end
			exact = assert(Custody.new(ports, s.output)); helpers.assert_true(exact.output_current())
			reenter = true; assert_false(exact.output_current(), "A prior successful observation cannot survive a new custody cycle")
			helpers.assert_true(exact.output_current())
		end)
	end)
end)

helpers.describe("original Reader source lifetime (controlled constructor)", function()
	helpers.it("spends an unchanged title without inventing a synthetic delivery debt", function()
		InputOwnerFixture.with_session(nil, function(s)
			package.loaded["adapters.xkb_capture"].peek_text = function(code) return code == 30 and "1" or nil end
			arm_input(s); s.edge("a", 30, 1, 200); s.edge("a", 30, 0, 250)
			helpers.assert_eq(s.base:input_arm_state(), nil); helpers.assert_eq(input_rows(s), prefix .. " 30:1 30:0")
			s.edge("a", 58, 1, 400); s.edge("a", 15, 1, 410); s.edge("a", 15, 0, 500)
			helpers.assert_true(s.armed, "A new acknowledged frame may arm after a logical-only spend")
		end)
	end)
	helpers.it("keeps scripted Reader source lifetime explicitly unavailable", function()
		local fake = require("tests.fakes").evdev_reader()
		helpers.assert_eq(fake.capture_source_owner(), nil); assert_false(fake.source_owner_current({})); assert_false(fake.retire_source({}))
	end)
	helpers.it("rejects copied input source leases and keeps mutation authority in the acknowledged Hook frame", function()
		InputOwnerFixture.with_session(nil, function(s)
			local source = assert(s.reader.capture_source_owner("keyboard:" .. s.paths.a))
			helpers.assert_true(s.reader.source_owner_current(source)); assert_false(s.reader.source_owner_current({}))
			assert_false(s.reader.retire_source({})); assert_false(s.hook.arm_one_shot(source)); helpers.assert_eq(s.base.one_shot_until, nil)
		end)
	end)
	helpers.it("can retire its original ungrabbed descriptor without reviving input currency", function()
		InputOwnerFixture.with_session(nil, function(s)
			local source = assert(s.reader.capture_source_owner("keyboard:" .. s.paths.a))
			helpers.assert_true(s.reader.ungrab("keyboard:" .. s.paths.a)); assert_false(s.reader.source_owner_current(source))
			helpers.assert_true(s.reader.retire_source(source)); assert_false(s.reader.is_open("keyboard:" .. s.paths.a))
			helpers.assert_true(s.reader.retire_source(source), "A prior exact close ACK stays settled")
		end)
	end)
	helpers.it("does not retry unresolved original close debt", function()
		InputOwnerFixture.with_session({ fail_reader_close = true }, function(s)
			local source = assert(s.reader.capture_source_owner("keyboard:" .. s.paths.a))
			assert_false(s.reader.retire_source(source)); assert_false(s.reader.retire_source(source))
			helpers.assert_true(s.reader.has_native_origin_debt()); assert_false(s.reader.source_owner_current(source))
		end)
	end)
	for _, id in ipairs({ "a", "b" }) do
		helpers.it("preserves the reopened " .. id .. " source even when the same numeric FD is reused", function()
			local options = { recycle_descriptor = true }
			options.after_sync = function(s, code, value)
				if code == 42 and value == 1 then
					options.after_sync = nil
					local slot, previous = "keyboard:" .. s.paths[id], s.descriptor(id)
					s.old_source = assert(s.reader.capture_source_owner(slot))
					helpers.assert_true(s.reader.close(slot)); helpers.assert_true(s.reader.open(s.paths[id], slot)); helpers.assert_true(s.reader.grab(slot))
					s.new_source = assert(s.reader.capture_source_owner(slot))
					helpers.assert_eq(s.descriptor(id), previous, "Controlled constructor must actually recycle the numeric FD")
				end
			end
			InputOwnerFixture.with_session(options, function(s)
				arm_input(s); s.edge("a", 30, 1, 200)
				helpers.assert_eq(input_rows(s), prefix .. " 42:1 42:0"); assert_false(s.hook.isRunning())
				helpers.assert_true(s.reader.is_open("keyboard:" .. s.paths[id])); helpers.assert_true(s.reader.source_owner_current(s.new_source))
				assert_false(s.reader.source_owner_current(s.old_source)); helpers.assert_true(s.reader.retire_source(s.old_source))
				helpers.assert_true(s.reader.source_owner_current(s.new_source), "Old original retirement never acquires successor rights")
				helpers.assert_eq(#s.writer.output_view(s.output).down, 0)
				helpers.assert_true(s.reader.retire_source(s.new_source))
			end)
		end)
	end
	helpers.it("source retirement never invokes a rebound public slot closer", function()
		InputOwnerFixture.with_session(nil, function(s)
			local source = assert(s.reader.capture_source_owner("keyboard:" .. s.paths.a))
			local called = false; s.reader.close = function() called = true; return true end
			helpers.assert_true(s.reader.retire_source(source)); assert_false(called); assert_false(s.reader.is_open("keyboard:" .. s.paths.a))
		end)
	end)
end)

helpers.describe("original input issuer export fences (controlled ports)", function()
	for _, name in ipairs({ "capture_input_owner", "input_owner_current", "arm_one_shot", "set_remapper", "stop", "emergency_stop" }) do
		for _, mode in ipairs({ "missing", "replaced" }) do
			helpers.it("refuses a " .. mode .. " original Hook " .. name .. " before frame capture", function()
				InputOwnerFixture.with_session(nil, function(s)
					local original = s.hook[name]
					s.hook[name] = mode == "replaced" and function() return true end or nil
					local ok, err = pcall(function()
						s.pair(); helpers.assert_true(not s.armed); helpers.assert_eq(s.base.one_shot_until, nil)
						helpers.assert_eq(input_rows(s), "29:1 29:0 29:1")
					end)
					s.hook[name] = original; helpers.assert_true(ok, err)
				end)
			end)
		end
	end
	for _, name in ipairs({ "process", "tick", "activity", "handles", "release_all", "take_custody", "output_holder",
		"combination_hold", "combination_release", "combination_lift", "combination_restore", "arm_one_shot", "input_arm_state", "clear_input_arm" }) do
		helpers.it("refuses rebound base export " .. name .. " after arm", function()
			InputOwnerFixture.with_session(nil, function(s)
				arm_input(s); local actual = require("platform.remap.tap_hold_engine"); local original = actual[name]
				actual[name] = function() return { { code = 99, value = 1 } } end
				local current = s.hook.input_owner_current(s.lease)
				actual[name] = original; assert_false(current)
			end)
		end)
	end
	for _, target in ipairs({ "instance", "base_metatable", "owner_metatable" }) do
		helpers.it("refuses replaced " .. target .. " dispatch identity", function()
			InputOwnerFixture.with_session(nil, function(s)
				arm_input(s)
				local object = target == "instance" and s.base or getmetatable(target == "base_metatable" and s.base or s.engine)
				local name = target == "instance" and "process" or "__index"; local original = rawget(object, name)
				object[name] = function() return { { code = 99, value = 1 } } end
				local current = s.hook.input_owner_current(s.lease)
				object[name] = original; assert_false(current)
			end)
		end)
	end
	for _, target in ipairs({ "process", "release_all", "native_release_all", "hook_cleanup" }) do
		helpers.it("withdraws exact acknowledged Shift after " .. target .. " changes during SYN callback", function()
			local options, restore = {}, nil
			options.after_sync = function(s, code, value)
				if code ~= 42 or value ~= 1 then return end
				options.after_sync = nil
				local object = target == "hook_cleanup" and s.hook or target == "native_release_all" and s.engine
					or require("platform.remap.tap_hold_engine")
				local name = target == "hook_cleanup" and "emergency_stop" or target == "native_release_all" and "release_all" or target
				local original = object[name]; local calls = 0
				object[name] = function() calls = calls + 1; return { { code = 99, value = 1 } } end
				restore = function() object[name] = original; helpers.assert_eq(calls, 0, "Cleanup must retain original dispatch and inverse") end
			end
			InputOwnerFixture.with_session(options, function(s)
				arm_input(s); s.edge("a", 30, 1, 200)
				if restore then restore() end
				helpers.assert_eq(input_rows(s), prefix .. " 42:1 42:0")
				assert_false(s.hook.isRunning()); helpers.assert_eq(#s.writer.output_view(s.output).down, 0)
				assert_false(s.reader.is_grabbed("keyboard:" .. s.paths.a)); assert_false(s.reader.is_grabbed("keyboard:" .. s.paths.b))
			end)
		end)
	end
end)

helpers.describe("original output lifetime terminal settlement (controlled ports)", function()
	helpers.it("settles only the old consumed retirement after exact destroy and close ACK", function()
		InputOwnerFixture.with_session(nil, function(s)
			arm_input(s); s.edge("a", 30, 1, 200)
			local current, terminal = s.writer.capture_output_observer(s.output)
			helpers.assert_eq(type(current), "function"); helpers.assert_eq(type(terminal), "function")
			assert_false(terminal(s.output)); assert_false(s.broker.output_retired())
			helpers.assert_true(s.writer.close_owned(s.output)); helpers.assert_true(terminal(s.output))
			helpers.assert_true(s.broker.output_retired()); helpers.assert_true(s.writer.open()); s.successor = assert(s.writer.capture_output())
			assert_false(terminal(s.successor)); assert_false(terminal({})); assert_false(current(s.output, 6, { 30, 42 }))
			s.edge("a", 30, 2, 210); assert_false(s.hook.isRunning())
			helpers.assert_true(s.hook.set_remapper(nil)); helpers.assert_true(s.writer.output_current(s.successor))
			helpers.assert_eq(#s.writer.output_view(s.successor).down, 0)
			helpers.assert_eq(input_rows(s), prefix .. " 42:1 30:1", "Destroyed old channel cannot emit repeat or inverse through successor")
			helpers.assert_true(s.writer.emit_owned(s.successor, 45, 1)); helpers.assert_true(s.writer.emit_owned(s.successor, 45, 0))
			helpers.assert_eq(input_rows(s), prefix .. " 42:1 30:1 45:1 45:0")
		end)
	end)
	for _, phase in ipairs({ "destroy", "close" }) do
		helpers.it("does not report terminal ACK inside the pending " .. phase .. " callback", function()
			local options = {}; local terminal, observed = nil, false
			options["output_" .. phase] = function(s)
				if terminal then observed = true; assert_false(terminal(s.output)); assert_false(s.broker.output_retired()) end
				return true
			end
			InputOwnerFixture.with_session(options, function(s)
				local ignored; ignored, terminal = s.writer.capture_output_observer(s.output)
				helpers.assert_true(s.writer.close_owned(s.output)); helpers.assert_true(observed); helpers.assert_true(terminal(s.output))
			end)
		end)
	end
	for _, verdict in ipairs({ "destroy_only", "close_only", "close_unknown", "close_EINTR", "destroy_throw" }) do
		helpers.it("retains exact retirement refusal for " .. verdict .. " without retry", function()
			local options = {}
			options.output_destroy = function()
				if verdict == "destroy_throw" then error("controlled ioctl uncertainty") end
				return verdict ~= "close_only"
			end
			options.output_close = function()
				if verdict == "close_unknown" then return nil end
				if verdict == "close_EINTR" then error("controlled EINTR") end
				return verdict ~= "destroy_only"
			end
			InputOwnerFixture.with_session(options, function(s)
				arm_input(s); s.edge("a", 30, 1, 200)
				local ignored, terminal = s.writer.capture_output_observer(s.output)
				assert_false(s.writer.close_owned(s.output)); assert_false(terminal(s.output)); assert_false(s.broker.output_retired())
				assert_false(s.writer.close_owned(s.output)); helpers.assert_eq(s.output_closes, 1); helpers.assert_eq(s.output_destroys, 1)
				s.edge("a", 30, 2, 210); assert_false(s.hook.isRunning())
				assert_false(s.hook.set_remapper(nil)); helpers.assert_true(s.writer.has_output_debt())
				helpers.assert_eq(s.output_closes, 1); helpers.assert_eq(s.output_destroys, 1)
			end)
		end)
	end
	helpers.it("old captured terminal proof survives export replacement without borrowing it", function()
		InputOwnerFixture.with_session(nil, function(s)
			arm_input(s); s.edge("a", 30, 1, 200)
			local factory = s.writer.capture_output_observer; local ignored, terminal = factory(s.output)
			local positive_current, positive_terminal = function() return true end, function() return true end
					s.writer.capture_output_observer = function() return positive_current, positive_terminal end
			assert_false(s.broker.output_current()); assert_false(s.broker.output_retired())
			helpers.assert_true(s.writer.close_owned(s.output)); helpers.assert_true(terminal(s.output)); helpers.assert_true(s.broker.output_retired())
			s.writer.capture_output_observer = factory
			helpers.assert_true(s.writer.open()); s.successor = assert(s.writer.capture_output())
			s.edge("a", 30, 2, 210); helpers.assert_true(s.hook.set_remapper(nil)); helpers.assert_true(s.writer.output_current(s.successor))
		end)
	end)
	helpers.it("a destroyed successor cannot settle the still-open original issuer", function()
		InputOwnerFixture.with_session(nil, function(s)
			local ignored, terminal = s.writer.capture_output_observer(s.output)
			assert_false(terminal({})); assert_false(s.broker.output_retired())
			-- A separately issued Writer has its own real private terminal record.
			local old = package.loaded["adapters.uinput_writer"]; package.loaded["adapters.uinput_writer"] = nil
			local other = require("adapters.uinput_writer"); other._set_backend({ open = function() return 7 end,
				close = function() return true end, ioctl = function() return true end, write = function() return true end })
			helpers.assert_true(other.open()); local cap = assert(other.capture_output()); local current, foreign = other.capture_output_observer(cap)
			helpers.assert_true(other.close_owned(cap)); helpers.assert_true(foreign(cap)); assert_false(foreign(s.output)); assert_false(terminal(cap))
			package.loaded["adapters.uinput_writer"] = old
			assert_false(s.broker.output_retired()); helpers.assert_true(s.writer.output_current(s.output))
		end)
	end)
	helpers.it("settlement uses original issuer ACK when the owner export is replaced", function()
		InputOwnerFixture.with_session(nil, function(s)
			arm_input(s); s.edge("a", 30, 1, 200)
			local original = s.engine.ack_retirement; local called = false
			s.engine.ack_retirement = function() called = true; return true end
			helpers.assert_true(s.writer.close_owned(s.output)); helpers.assert_true(s.writer.open()); s.successor = assert(s.writer.capture_output())
			s.edge("a", 30, 2, 210); assert_false(called)
			s.engine.ack_retirement = original; helpers.assert_true(s.hook.set_remapper(nil))
			helpers.assert_true(s.writer.output_current(s.successor))
		end)
	end)
end)

helpers.describe("original output observer constructor provenance (controlled ports)", function()
	for _, mode in ipairs({ "positive_factory", "missing_issuer", "borrowed_factory", "rebound_capture", "borrowed_fresh_capture" }) do
		helpers.it("ordinary controlled output cannot mint input proof through " .. mode, function()
			local options = {}
			options.before_hook = function(s)
				local capture, factory = s.writer.capture_output, s.writer.capture_output_observer
				if mode == "positive_factory" then
					s.writer.capture_output_observer = function() return function() return true end, function() return true end end
				elseif mode == "missing_issuer" then s.writer.capture_output = function() local cap = capture(); return cap end
				elseif mode == "rebound_capture" then s.writer.capture_output = function() return capture() end
				elseif mode == "borrowed_fresh_capture" then
					helpers.assert_true(s.writer.close_owned(s.output)); helpers.assert_true(s.writer.open())
					s.output = assert(capture()); s.writer.capture_output = function() return s.output, factory end
				else
					local other = assert(loadfile("adapters/uinput_writer.lua"))()
					s.writer.capture_output_observer = other.capture_output_observer
				end
				s.restore_factory = function() s.writer.capture_output, s.writer.capture_output_observer = capture, factory end
			end
			InputOwnerFixture.with_session(options, function(s)
				assert_false(s.broker.output_current()); assert_false(s.broker.output_retired())
				s.pair(); helpers.assert_true(not s.armed); helpers.assert_eq(s.base.one_shot_until, nil)
				helpers.assert_eq(input_rows(s), "29:1 29:0 29:1")
				s.restore_factory()
			end)
		end)
	end
	helpers.it("cannot redeem a captured terminal closure using a successor factory result", function()
		InputOwnerFixture.with_session(nil, function(s)
			local cap, factory = s.writer.capture_output(); helpers.assert_eq(cap, s.output); helpers.assert_eq(factory, s.writer.capture_output_observer)
			local ignored, original = factory(cap); assert_false(original({})); assert_false(s.broker.output_retired())
			helpers.assert_true(s.writer.close_owned(s.output)); helpers.assert_true(s.writer.open()); s.successor = assert(s.writer.capture_output())
			local current, fresh = factory(s.successor); assert_false(fresh(s.output)); assert_false(original(s.successor))
			helpers.assert_true(original(s.output)); helpers.assert_true(s.broker.output_retired()); assert_false(fresh(s.successor))
		end)
	end)
end)

helpers.describe("original installed broker observer binding (controlled ports)", function()
	for _, name in ipairs({ "view", "has_debt", "output_current", "output_retired", "retire" }) do
		helpers.it("refuses pre-frame replacement of original broker " .. name, function()
			InputOwnerFixture.with_session(nil, function(s)
				local original = s.broker[name]; s.broker[name] = function() return true end
				local ok, err = pcall(function() s.pair(); helpers.assert_true(not s.armed); helpers.assert_eq(s.base.one_shot_until, nil) end)
				s.broker[name] = original; helpers.assert_true(ok, err)
			end)
		end)
	end
	helpers.it("retains original terminal proof when its public method changes after consumption", function()
		InputOwnerFixture.with_session(nil, function(s)
			arm_input(s); s.edge("a", 30, 1, 200)
			local original = s.broker.output_retired; s.broker.output_retired = function() return true end
			helpers.assert_true(s.writer.close_owned(s.output)); helpers.assert_true(s.writer.open()); s.successor = assert(s.writer.capture_output())
			s.edge("a", 30, 2, 210); s.broker.output_retired = original
			helpers.assert_true(s.hook.set_remapper(nil)); helpers.assert_true(s.writer.output_current(s.successor))
		end)
	end)
end)

helpers.describe("terminal proof refusal after consumed broker export retirement", function()
 helpers.it("a public positive terminal lambda cannot settle a failed original destroy", function()
  local options={output_destroy=function()return false end}
  InputOwnerFixture.with_session(options,function(s)
   arm_input(s);s.edge("a",30,1,200)
   assert_false(s.writer.close_owned(s.output))
   local original=s.broker.output_retired;s.broker.output_retired=function()return true end
   s.edge("a",30,2,210);s.broker.output_retired=original
   assert_false(s.hook.isRunning());assert_false(s.hook.set_remapper(nil))
   helpers.assert_true(s.writer.has_output_debt());helpers.assert_eq(s.output_closes,1);helpers.assert_eq(s.output_destroys,1)
  end)
 end)
end)

helpers.describe("original Reader issuer lineage before Hook construction (controlled ports)", function()
 for _,name in ipairs({"capture_source_owner","source_owner_current","retire_source"}) do
  helpers.it("a replaced original "..name.." cannot become input or cleanup authority",function()
   local options={before_hook=function(s)
    local original=s.reader[name];s.restore_reader=function()s.reader[name]=original end
    s.reader[name]=name=="capture_source_owner" and function(...)return original(...)end or function()return true end
   end}
   InputOwnerFixture.with_session(options,function(s)
    s.pair();helpers.assert_true(not s.armed);helpers.assert_eq(s.base.one_shot_until,nil)
    helpers.assert_eq(input_rows(s),"29:1 29:0 29:1");s.restore_reader()
   end)
  end)
 end
 helpers.it("a source receipt without its original observer retains only ordinary event compatibility",function()
  local options={before_hook=function(s)
   local original=s.reader.capture_source_owner;s.restore_reader=function()s.reader.capture_source_owner=original end
   s.reader.capture_source_owner=function(...)local lease=original(...);return lease end
  end}
  InputOwnerFixture.with_session(options,function(s)
   s.pair();helpers.assert_true(not s.armed);s.edge("a",58,0,150);s.edge("a",30,1,200);s.edge("a",30,0,250)
   helpers.assert_eq(input_rows(s),prefix.." 30:1 30:0");s.restore_reader()
  end)
 end)
 helpers.it("the source issuer rejects copied receipts functions and a borrowed source observer",function()
  InputOwnerFixture.with_session(nil,function(s)
   local lease,observer=s.reader.capture_source_owner("keyboard:"..s.paths.a)
   local foreign,other=s.reader.capture_source_owner("keyboard:"..s.paths.b)
   local capture,current,retire=s.reader.capture_source_owner,s.reader.source_owner_current,s.reader.retire_source
   helpers.assert_true(observer(lease,capture,current,retire));assert_false(observer({},capture,current,retire))
   assert_false(observer(foreign,capture,current,retire));assert_false(other(lease,capture,current,retire))
   assert_false(observer(lease,function(...)return capture(...)end,current,retire))
   assert_false(observer(lease,capture,function()return true end,retire));assert_false(observer(lease,capture,current,function()return true end))
  end)
 end)
 helpers.it("source lineage is not revived by a successor with a recycled descriptor",function()
  InputOwnerFixture.with_session({recycle_descriptor=true},function(s)
   local slot="keyboard:"..s.paths.a;local fd=s.descriptor("a");local lease,observer=s.reader.capture_source_owner(slot)
   helpers.assert_true(s.reader.retire_source(lease));helpers.assert_true(s.reader.open(s.paths.a,slot));helpers.assert_true(s.reader.grab(slot))
   helpers.assert_eq(s.descriptor("a"),fd);local fresh,other=s.reader.capture_source_owner(slot)
   assert_false(observer(lease,s.reader.capture_source_owner,s.reader.source_owner_current,s.reader.retire_source))
   helpers.assert_true(other(fresh,s.reader.capture_source_owner,s.reader.source_owner_current,s.reader.retire_source))
   assert_false(other(lease,s.reader.capture_source_owner,s.reader.source_owner_current,s.reader.retire_source))
   helpers.assert_true(s.reader.retire_source(lease));helpers.assert_true(s.reader.source_owner_current(fresh))
  end)
 end)
 helpers.it("passive event receipt collection cannot mint authority and keeps genuine receipts compatible",function()
  local options={before_hook=function(s)
   local original=s.reader.capture_event;s.observed=0
   s.reader.capture_event=function(...)s.observed=s.observed+1;return original(...)end
  end}
  InputOwnerFixture.with_session(options,function(s)
   arm_input(s);s.edge("a",30,1,200);s.edge("a",30,0,250)
   helpers.assert_true(s.observed>0);helpers.assert_eq(input_rows(s),prefix.." 42:1 30:1 30:0 42:0")
  end)
 end)
 helpers.it("postframe public retirement replacement cannot steal captured original source cleanup",function()
  InputOwnerFixture.with_session(nil,function(s)
   arm_input(s);s.edge("a",30,1,200)
   local original=s.reader.retire_source;local called=false;s.reader.retire_source=function()called=true;return true end
   s.edge("a",30,2,210);s.reader.retire_source=original
   assert_false(called);assert_false(s.hook.isRunning());assert_false(s.reader.is_grabbed("keyboard:"..s.paths.a))
   assert_false(s.reader.is_grabbed("keyboard:"..s.paths.b));helpers.assert_eq(#s.writer.output_view(s.output).down,0)
  end)
 end)
end)

helpers.describe("actual event issuer joins original source observer (controlled ports)", function()
 for _,mode in ipairs({"positive_observer","positive_current_and_observer"}) do
  helpers.it("a rebound getter cannot issue "..mode.." as original input authority",function()
   local options={before_hook=function(s)
    local capture,current=s.reader.capture_source_owner,s.reader.source_owner_current
    s.restore_reader=function()s.reader.capture_source_owner,s.reader.source_owner_current=capture,current end
    s.reader.capture_source_owner=function(...)local lease=capture(...);return lease,function()return true end end
    if mode=="positive_current_and_observer" then s.reader.source_owner_current=function()return true end end
   end}
   InputOwnerFixture.with_session(options,function(s)
    s.pair();helpers.assert_true(not s.armed);helpers.assert_eq(s.base.one_shot_until,nil)
    helpers.assert_eq(input_rows(s),"29:1 29:0 29:1");s.restore_reader()
   end)
  end)
 end
 helpers.it("actual event origin authenticates only its exact registered source observer",function()
  local options={before_hook=function(s)
   local original=s.reader.capture_event
   s.reader.capture_event=function(...)local origin=original(...);s.last_origin=origin;return origin end
  end}
  InputOwnerFixture.with_session(options,function(s)
   s.pair();helpers.assert_true(s.armed)
   local lease,observer=s.reader.capture_source_owner("keyboard:"..s.paths.a)
   local foreign,other=s.reader.capture_source_owner("keyboard:"..s.paths.b)
   local capture,current,retire=s.reader.capture_source_owner,s.reader.source_owner_current,s.reader.retire_source
   helpers.assert_true(s.reader.source_current(s.last_origin))
   helpers.assert_true(s.reader.source_current(s.last_origin,lease,observer,capture,current,retire))
   assert_false(s.reader.source_current({},lease,observer,capture,current,retire))
   assert_false(s.reader.source_current(s.last_origin,{},observer,capture,current,retire))
   assert_false(s.reader.source_current(s.last_origin,foreign,other,capture,current,retire))
   assert_false(s.reader.source_current(s.last_origin,lease,other,capture,current,retire))
   assert_false(s.reader.source_current(s.last_origin,lease,function()return true end,capture,current,retire))
   assert_false(s.reader.source_current(s.last_origin,lease,observer,function(...)return capture(...)end,current,retire))
   assert_false(s.reader.source_current(s.last_origin,lease,observer,capture,function()return true end,retire))
   assert_false(s.reader.source_current(s.last_origin,lease,observer,capture,current,function()return true end))
  end)
 end)
end)

helpers.describe("cold installed input authority bootstrap (controlled ports)", function()
 helpers.it("the genuine Hook and Reader load before programmable backend callbacks",function()
  InputOwnerFixture.with_session({before_hook=function(s)
   helpers.assert_eq(package.loaded["adapters.keyboard_hook"],s.hook)
   helpers.assert_eq(s.bootstrap,"cold-hook-before-backend")
  end},function(s)
   arm_input(s);helpers.assert_eq(s.before_arm_acquisitions,s.after_arm_acquisitions)
   s.edge("a",30,1,200);s.edge("a",30,0,250)
   helpers.assert_eq(input_rows(s),prefix.." 42:1 30:1 30:0 42:0")
  end)
 end)
 for _,mode in ipairs({"genuine_preloaded","all_positive_preloaded","all_positive_after_cold_load"}) do
  helpers.it("cannot certify "..mode.." through mutable public authority ports",function()
   local options={late_reader=mode~="all_positive_after_cold_load"}
   if mode~="genuine_preloaded" then options.before_hook=function(s)
    local capture,source,view=s.reader.capture_source_owner,s.reader.source_current,s.reader.event_view
    s.restore_reader=function()s.reader.capture_source_owner,s.reader.source_current,s.reader.event_view=capture,source,view end
    s.reader.capture_source_owner=function(...)local cap=capture(...);return cap,function()return true end end
    s.reader.source_current=function()return true end
    s.reader.event_view=function(...)return view(...),function()return true end end
   end end
   InputOwnerFixture.with_session(options,function(s)
    s.pair();helpers.assert_true(not s.armed);helpers.assert_eq(s.base.one_shot_until,nil)
    s.edge("a",58,0,150);s.edge("a",30,1,200);s.edge("a",30,0,250)
    helpers.assert_eq(input_rows(s),prefix.." 30:1 30:0")
    helpers.assert_true(s.hook.isRunning());if s.restore_reader then s.restore_reader()end
   end)
  end)
 end
end)

helpers.describe("consumed source withdrawal exact native inverse settlement (controlled transport)", function()
	local Fixture = require("tests.support.input_owner_fixture")
	local function arm(s)
		s.pair(); helpers.assert_true(s.armed); s.edge("a", 58, 0, 110)
	end
	local function wire(s)
		local out = {}; for _, row in ipairs(s.rows) do out[#out + 1] = row[1] .. ":" .. row[2] end
		return table.concat(out, " ")
	end
	local function replace(options, id)
		options.after_sync = function(s, code, value)
			if code == 42 and value == 1 then
				local slot, descriptor = "keyboard:" .. s.paths[id], s.descriptor(id)
				s.old_source = assert(s.reader.capture_source_owner(slot))
				helpers.assert_true(s.reader.close(slot)); helpers.assert_true(s.reader.open(s.paths[id], slot))
				helpers.assert_true(s.reader.grab(slot)); s.new_source = assert(s.reader.capture_source_owner(slot))
				helpers.assert_eq(s.descriptor(id), descriptor)
			end
			if options.inverse_callback and code == 42 and value == 0 then options.inverse_callback(s) end
		end
	end
	for _, id in ipairs({ "a", "b" }) do
		helpers.it("settles acknowledged Shift inverse and cancelled character after actual " .. id .. " FD reuse", function()
			local options = { recycle_descriptor = true }; replace(options, id)
			Fixture.with_session(options, function(s)
				arm(s); s.edge("a", 30, 1, 200)
				helpers.assert_eq(wire(s), "29:1 29:0 29:1 29:0 42:1 42:0")
				helpers.assert_eq(s.hook.isRunning(), false); helpers.assert_true(s.broker.output_current())
				helpers.assert_eq(#s.writer.output_view(s.output).down, 0)
				helpers.assert_eq(s.reader.source_owner_current(s.old_source), false)
				helpers.assert_true(s.reader.retire_source(s.old_source)); helpers.assert_true(s.reader.source_owner_current(s.new_source))
				s.hook.stop(); helpers.assert_true(s.hook.set_remapper(nil))
				helpers.assert_true(s.reader.source_owner_current(s.new_source), "Original remapper cleanup cannot close successor")
				helpers.assert_true(s.writer.output_current(s.output), "Healthy original output remains admitted")
				helpers.assert_eq(wire(s), "29:1 29:0 29:1 29:0 42:1 42:0", "Settlement emits no duplicate inverse or cancelled character")
				helpers.assert_true(s.reader.retire_source(s.new_source))
			end)
		end)
	end
	helpers.it("does not acknowledge a queued inverse before original native commit", function()
		local options = { recycle_descriptor = true }; replace(options, "a")
		options.inverse_callback = function(s)
			helpers.assert_eq(s.hook.set_remapper(nil), false, "Native inverse callback remains inside busy commit")
		end
		Fixture.with_session(options, function(s)
			arm(s); s.edge("a", 30, 1, 200)
			helpers.assert_true(s.hook.set_remapper(nil)); helpers.assert_true(s.reader.source_owner_current(s.new_source))
			helpers.assert_true(s.reader.retire_source(s.new_source))
		end)
	end)
	helpers.it("retains retirement debt after failed inverse SYN and refused original destroy", function()
		local options = { recycle_descriptor = true, output_destroy = function() return false end }
		replace(options, "a"); options.fail_sync = function(_, code, value) return code == 42 and value == 0 end
		Fixture.with_session(options, function(s)
			arm(s); s.edge("a", 30, 1, 200)
			helpers.assert_eq(s.hook.set_remapper(nil), false); local destroys = s.output_destroys
			helpers.assert_eq(s.hook.set_remapper(nil), false); helpers.assert_eq(s.output_destroys, destroys, "Unknown retirement is not retried")
			helpers.assert_true(s.broker.has_debt()); helpers.assert_true(s.reader.source_owner_current(s.new_source))
			helpers.assert_eq(wire(s), "29:1 29:0 29:1 29:0 42:1 42:0")
			helpers.assert_true(s.reader.retire_source(s.new_source))
		end)
	end)
	helpers.it("refuses a rebound producer ACK while preserving original healthy output", function()
		local options = { recycle_descriptor = true }; replace(options, "a")
		options.inverse_callback = function(s)
			s.original_ack = s.engine.ack_retirement; s.fake_ack_called = false
			s.engine.ack_retirement = function() s.fake_ack_called = true; return true end
		end
		Fixture.with_session(options, function(s)
			arm(s); s.edge("a", 30, 1, 200)
			helpers.assert_eq(s.hook.set_remapper(nil), false); helpers.assert_eq(s.fake_ack_called, false)
			helpers.assert_true(s.writer.output_current(s.output)); s.engine.ack_retirement = s.original_ack
			helpers.assert_true(s.hook.set_remapper(nil)); helpers.assert_true(s.reader.source_owner_current(s.new_source))
			helpers.assert_true(s.reader.retire_source(s.new_source))
		end)
	end)
	helpers.it("settles its old opaque holders while preserving an unrelated native Shift owner", function()
		local options = { recycle_descriptor = true }
		options.after_sync = function(s, code, value)
			if code == 30 and value == 1 then
				local slot = "keyboard:" .. s.paths.a
				s.old_source = assert(s.reader.capture_source_owner(slot)); helpers.assert_true(s.reader.close(slot))
				helpers.assert_true(s.reader.open(s.paths.a, slot)); helpers.assert_true(s.reader.grab(slot))
				s.new_source = assert(s.reader.capture_source_owner(slot))
			end
		end
		Fixture.with_session(options, function(s)
			arm(s); local other = {}
			helpers.assert_true(s.broker.edge(other, 42, 1, s.writer.emit).ok)
			s.edge("a", 30, 1, 200)
			helpers.assert_eq(wire(s), "29:1 29:0 29:1 29:0 42:1 30:1 30:0")
			helpers.assert_true(s.hook.set_remapper(nil)); helpers.assert_true(s.broker.output_current())
			helpers.assert_eq(s.broker.view().owners[other].code, 42)
			helpers.assert_eq(s.writer.output_view(s.output).down[1], 42, "Unrelated native Shift must remain held")
			helpers.assert_true(s.reader.source_owner_current(s.new_source)); helpers.assert_true(s.reader.retire_source(s.new_source))
			helpers.assert_true(s.broker.edge(other, 42, 0, s.writer.emit).ok)
			helpers.assert_eq(wire(s), "29:1 29:0 29:1 29:0 42:1 30:1 30:0 42:0")
		end)
	end)

end)
