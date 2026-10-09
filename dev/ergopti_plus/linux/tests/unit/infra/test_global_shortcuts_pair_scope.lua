--- tests/unit/infra/test_global_shortcuts_pair_scope.lua

--- Actual canonical pair and parameter owners through the shared publisher.
--- File and native delivery ports are controlled; no physical input is claimed.
-- Preserve the process-wide C issuer before any whole-cache fixture snapshot.
-- Requiring it inside a fixture and erasing it on teardown reopens libuv state.
local NativeLoop = require("luv")
local helpers = require("tests.helpers")
local Codec = require("toml_codec")
local Scope = require("infra.shortcuts_scope")
local path, backup = "/controlled/config.toml", "/controlled/combination.bak"
local pair, binding = "caps_lock_then_tab", "combination__caps_lock_then_tab"
local parameter = binding .. "__open_url"
local source = '[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "open_url"\nfuture_then_tab = "future"\n'
	.. '[shortcuts.key_combination_holds]\ncaps_lock_then_tab = "shift"\n'
	.. '[gesture_parameters]\ncombination__caps_lock_then_tab__open_url = "https://old.example"\n'
	.. '[unrelated]\nkeep = 42\n'
local edits = {
	{ section = "shortcuts.key_combination_taps", key = pair, value = "open_url" },
	{ section = "shortcuts.key_combination_holds", key = pair, value = "alt" },
	{ section = "gesture_parameters", key = parameter, value = "https://new.example" },
}
local function with_owner(body, managed, prepare)
	local saved = {}; for name, value in pairs(package.loaded) do saved[name] = value end
	local ok, err = pcall(function()
		package.loaded["modules.shortcuts.key_combinations"] = nil
		local PairOwner = require("modules.shortcuts.key_combinations")
		package.loaded["modules.gestures.manager"] = nil
		local gestures = require("modules.gestures.manager")
		local state = { bytes = { [path] = source }, paused = false, publications = 0, changes = 0 }
		local files = {
			read_with_status = function(target)
				local content = state.bytes[target]; return content, content and "ok" or "absent"
			end,
			write = function() error("Unconditional publication is forbidden") end,
			write_if_unchanged = function(target, content, expected)
				if state.before_publish then state.before_publish(target, content) end
				if state.refuse_path == target then return false, "Controlled publication refusal" end
				local current = state.bytes[target]
				if (current and expected.status ~= "ok") or (not current and expected.status ~= "absent")
					or (current and current ~= expected.content) then return false, "Controlled source conflict" end
				state.bytes[target] = content
				if target == path then state.publications = state.publications + 1 end
				return true
			end,
		}
		if managed then
			local Loader=require("platform.remap.tap_hold_loader")
			local defaults=require("infra.paths").shared("tap_hold/defaults.toml")
			local loaded=Loader.load_document(defaults,{tap_hold={enabled=false,inherit_defaults=true}},nil,"/controlled/tap_hold.toml")
			package.loaded["platform.remap.tap_hold_manager"]=nil
			package.loaded["platform.remap.tap_hold_loader"]={FALLBACK_THRESHOLD_SECONDS=Loader.FALLBACK_THRESHOLD_SECONDS,load=function() return loaded end}
			package.loaded["platform.remap.nav_layer"]={load=function() return {} end}
			package.loaded["adapters.file_system"]=files
			package.loaded["infra.config_paths"]={config=function() return path end}
			local hook={set_remapper=function(engine,callback)
				if state.refuse_native then return false end
				if state.native then
					state.retired=state.native:release_all()
					if state.native.ack_retirement and state.native:ack_retirement(true)~=true then return false end
				end
				if engine and engine.activate and engine:activate()~=true then return false end
				state.native,state.on_tap=engine,callback;return true
			end}
			for _,name in ipairs({"key_text","held_modifiers","held_text_modifier_codes","held_shortcut_modifier_codes"}) do hook[name]=function() return {} end end
			package.loaded["modules.shortcuts.key_combinations"]=nil
			state.manager=require("platform.remap.tap_hold_manager")
			helpers.assert_true(state.manager.init({keyboard_hook=hook,execute_action=function(action,slot) state.executed={action,slot} end,action_names=function() return {"open_url","copy"} end,on_text_injected=function() end,defaults_path=defaults,user_path="/controlled/tap_hold.toml"}))
			state.pairs=require("modules.shortcuts.key_combinations")
		else
		state.pairs = PairOwner.new({ keys = { {id="caps_lock",key="caps_lock"}, {id="tab",key="tab"} },
			hold_picker = { modifiers = {"shift","alt"}, layers = {"nav"} }, files = files,
			route = function() return state.route_path or path end, is_paused = function() return state.paused end,
			actions = {is_assignable=function(action) return action == "open_url" or action == "copy" end},
			changed = function()
				state.changes = state.changes + 1
				if state.changed then return state.changed() end
				return true
			end })
		PairOwner.set_instance(state.pairs)
		end
		local initial = {}; helpers.assert_true(gestures.acquire_parameter_configuration(initial))
		helpers.assert_true(gestures.apply_parameter_configuration(initial,{[parameter]="https://old.example"}))
		helpers.assert_true(gestures.release_parameter_configuration(initial))
		state.gestures, state.files = gestures, files
		local function ordinary(initial)
			local token, current = nil, initial
			return {
				acquire_configuration=function(value) if token then return false end; token=value; return true end,
				release_configuration=function(value) if token~=value then return false end; token=nil; return true end,
				configuration_snapshot=function(value) if token~=value then return nil end; return current end,
				configuration_candidate=function() return current end,
				apply_configuration=function(value,candidate) if token~=value then return false end; current=candidate; return true end,
				configuration_domain=function() return nil end, configuration_paths=function() return {} end,
			}
		end
		if prepare then prepare(state) end
		state.scope = Scope.new({path=path,backup_path=backup,files=files,combinations=state.pairs,parameters=gestures,
			manager=ordinary({enabled=true,wrap=false,caps_word_active=false,caps_word_triggered=false}),
			keyboard=ordinary({assignments={},explicit_assignments={}}), taps=ordinary({}), chords=ordinary({}), url=ordinary({}),
			is_paused=function() return state.paused end})
		body(state)
	end)
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not ok then error(err,0) end
end

helpers.describe("global shortcut scope exact pair composition",function()
 helpers.it("clear owns dynamic pairs, removes only owned parameters and can revert",function()
  with_owner(function(s)
   local committed,detail=s.scope.apply('clear');helpers.assert_eq(committed,true,detail)
   local doc=Codec.decode(s.bytes[path]);helpers.assert_eq(doc.shortcuts.key_combination_taps.caps_lock_then_tab,nil)
   helpers.assert_eq(doc.shortcuts.key_combination_taps.future_then_tab,'future')
   helpers.assert_eq(doc.gesture_parameters[parameter],nil)
   helpers.assert_eq(s.pairs.get_action(pair),'none')
   helpers.assert_eq(s.scope.pending(),false)
   helpers.assert_true(s.scope.revert());helpers.assert_eq(s.bytes[path],source)
   helpers.assert_eq(s.pairs.get_action(pair),'open_url')
  end)
 end)
 helpers.it("recommended imports pair defaults without touching future records",function()
  with_owner(function(s)
   helpers.assert_true(s.scope.apply('recommended'))
   helpers.assert_eq(s.pairs.get_action(pair),'none')
   helpers.assert_eq(Codec.decode(s.bytes[path]).shortcuts.key_combination_taps.future_then_tab,'future')
   helpers.assert_eq(Codec.decode(s.bytes[path]).gesture_parameters[parameter],nil)
  end)
 end)
 helpers.it("retains refused program stop before any publication",function()
  with_owner(function(s)
   local stop=s.gestures.stop_programs;s.gestures.stop_programs=function() return false end
   helpers.assert_eq(s.scope.apply('clear'),false);helpers.assert_true(s.scope.pending())
   helpers.assert_eq(s.publications,0);helpers.assert_eq(s.pairs.configuration_pending(),true)
   helpers.assert_eq(s.scope.retry_restore(),false);helpers.assert_eq(s.publications,0)
   s.gestures.stop_programs=stop;helpers.assert_true(s.scope.retry_restore());helpers.assert_eq(s.scope.pending(),false)
   helpers.assert_eq(s.bytes[path],source);helpers.assert_eq(s.pairs.get_action(pair),'open_url')
  end)
 end)
 helpers.it("contains throwing program retirement and retries the exact owner",function()
  with_owner(function(s)
   local stop=s.gestures.stop_programs;s.gestures.stop_programs=function() error('Controlled retirement refusal') end
   helpers.assert_eq(s.scope.apply('clear'),false);helpers.assert_true(s.scope.pending());helpers.assert_eq(s.publications,0)
   s.gestures.stop_programs=stop;helpers.assert_true(s.scope.retry_restore());helpers.assert_eq(s.scope.pending(),false)
  end)
 end)
 helpers.it("installed Shift is retired before global clear and no candidate emits inside publication",function()
  with_owner(function(s)
   local physical={ready=true,physical=true,source='controlled-owned-keyboard',generation=7}
   s.native:process(58,1,0,physical)
   local outputs,_,_,frame=s.native:process(15,1,10,physical)
   helpers.assert_eq(outputs[1].code,42);helpers.assert_true(frame.ack(true))
   s.before_publish=function(target)
    if target==path then helpers.assert_eq(s.native,nil,'No pair engine is open during publication');helpers.assert_eq(s.pairs.configuration_pending(),true) end
   end
   helpers.assert_true(s.scope.apply('clear'))
   local retired=false;for _,event in ipairs(s.retired or {}) do if event.code==42 and event.value==0 then retired=true end end
   helpers.assert_true(retired,'The actual previous Shift frame acknowledged retirement')
   helpers.assert_eq(s.pairs.get_action(pair),'none');helpers.assert_eq(s.scope.pending(),false)
  end,true)
 end)
 helpers.it("failed installed Shift retirement retains pair lease and forbids publication",function()
  with_owner(function(s)
   local physical={ready=true,physical=true,source='controlled-owned-keyboard',generation=7}
   s.native:process(58,1,0,physical);local outputs,_,_,frame=s.native:process(15,1,10,physical);helpers.assert_true(frame.ack(true))
   s.refuse_native=true
   helpers.assert_eq(s.scope.apply('clear'),false);helpers.assert_true(s.scope.pending());helpers.assert_eq(s.publications,0)
   helpers.assert_eq(s.pairs.configuration_pending(),true)
   helpers.assert_eq(s.scope.retry_restore(),false)
   s.refuse_native=false;helpers.assert_true(s.scope.retry_restore());helpers.assert_eq(s.scope.pending(),false)
   helpers.assert_eq(s.bytes[path],source)
  end,true)
 end)
 helpers.it("refuses canonical tap and hold changes not installed in the runtime before backup",function()
  for _,kind in ipairs({'taps','holds'}) do
   with_owner(function(s)
    local changed=kind=='taps' and source:gsub('caps_lock_then_tab = "open_url"','caps_lock_then_tab = "copy"',1)
      or source:gsub('caps_lock_then_tab = "shift"','caps_lock_then_tab = "alt"',1)
    s.bytes[path]=changed
    helpers.assert_eq(s.scope.apply('clear'),false);helpers.assert_eq(s.publications,0)
    helpers.assert_eq(s.bytes[backup],nil);helpers.assert_eq(s.bytes[path],changed)
    helpers.assert_eq(s.pairs.get_action(pair),'open_url');helpers.assert_eq(s.pairs.get_hold(pair),'shift')
    helpers.assert_eq(s.scope.pending(),false,'No native mutation started, so all acquired leases settle')
    helpers.assert_eq(s.pairs.capture_edit_source(),nil,'The stale runtime cannot admit an editor source')
    s.bytes[path]=source;helpers.assert_true(s.scope.apply('clear'));helpers.assert_eq(s.scope.pending(),false)
   end)
  end
 end)
 helpers.it("compensates a final pair installation refusal after conditional publication",function()
  with_owner(function(s)
   local refused=false
   s.changed=function()
    if s.publications==1 and s.pairs.configuration_pending()==false and not refused then refused=true;return false end
    return true
   end
   helpers.assert_eq(s.scope.apply('clear'),false);helpers.assert_true(refused)
   helpers.assert_eq(s.bytes[path],source);helpers.assert_eq(s.pairs.get_action(pair),'open_url')
   helpers.assert_eq(s.scope.pending(),false);helpers.assert_eq(s.publications,2)
  end)
 end)
 helpers.it("retains postpublication installation debt until the exact native owner acknowledges inverse",function()
  with_owner(function(s)
   local refuse=true;s.changed=function() return not (refuse and s.publications>0) end
   helpers.assert_eq(s.scope.apply('clear'),false);helpers.assert_true(s.scope.pending())
   helpers.assert_eq(s.pairs.configuration_pending(),true)
   helpers.assert_eq(s.scope.retry_restore(),false)
   refuse=false;helpers.assert_true(s.scope.retry_restore());helpers.assert_eq(s.scope.pending(),false)
   helpers.assert_eq(s.bytes[path],source);helpers.assert_eq(s.pairs.get_action(pair),'open_url')
  end)
 end)
 helpers.it("refuses a source callback substitution after native candidate application",function()
  with_owner(function(s)
   local replaced=false;s.changed=function()
    if s.pairs.get_action(pair)=='none' and not replaced then replaced=true;s.bytes[path]=source..'# foreign source frame\n' end
    return true
   end
   helpers.assert_eq(s.scope.apply('clear'),false);helpers.assert_true(replaced);helpers.assert_eq(s.publications,0)
   helpers.assert_eq(s.bytes[path],source..'# foreign source frame\n');helpers.assert_eq(s.pairs.get_action(pair),'open_url')
   helpers.assert_eq(s.scope.pending(),false)
  end)
 end)
 helpers.it("reentrant changed callback cannot acquire a second global operation",function()
  with_owner(function(s)
   local called=false;s.changed=function() if not called then called=true;helpers.assert_eq(s.scope.apply('clear'),false) end;return true end
   helpers.assert_true(s.scope.apply('clear'));helpers.assert_true(called);helpers.assert_eq(s.scope.pending(),false)
  end)
 end)
end)
helpers.describe('global terminal parameter source acknowledgment',function()
 helpers.it('keeps actual parameter ownership throughout final Pair native installation',function()
  with_owner(function(s)
   local attempted,acquired=false,nil
   s.changed=function()
    if s.publications==1 and not s.pairs.configuration_pending() and not attempted then
     attempted=true;acquired=s.gestures.acquire_parameter_configuration({})
    end
    return true
   end
   helpers.assert_true(s.scope.apply('clear'));helpers.assert_true(attempted);helpers.assert_eq(acquired,false)
   helpers.assert_eq(s.bytes[path],s.files.read_with_status(path));helpers.assert_eq(s.scope.pending(),false)
  end)
 end)
 helpers.it('refuses private parameter mutation inside terminal detached source guard',function()
  with_owner(function(s)
   local capture=s.pairs.capture_edit_source;local once=true
   s.pairs.capture_edit_source=function(token)
    local receipt=capture(token)
    if receipt and s.publications==1 and s.gestures.parameter_configuration_snapshot(s.scope)==nil and once then
     local guard=receipt.guard;receipt.guard=function()
      local current=guard();if once then once=false;helpers.assert_true(s.gestures.set_action_parameter(binding,'open_url','https://unpublished.example')) end
      return current
     end
    end
    return receipt
   end
   helpers.assert_eq(s.scope.apply('clear'),false);helpers.assert_eq(once,false)
   helpers.assert_eq(s.bytes[path],source);helpers.assert_eq(s.scope.pending(),false)
   helpers.assert_eq(s.gestures.get_action_parameter(binding,'open_url'),'https://old.example')
  end)
 end)
end)
helpers.describe('global acknowledged source route inverse',function()
 for _,stage in ipairs({'publication','parameter_release','pair_release'}) do
  helpers.it('retains the original published frame after '..stage..' handoff until exact route recovery',function()
   with_owner(function(s)
    local other='/controlled/foreign.toml';local handed=false
    local function handoff(candidate)
     if not handed then handed=true;s.route_path=other;s.bytes[other]=candidate or s.bytes[path] end
    end
    if stage=='publication' then s.before_publish=function(target,candidate) if target==path then handoff(candidate) end end
    elseif stage=='parameter_release' then s.after_parameter_release=handoff
    else s.changed=function() if s.publications==1 and not s.pairs.configuration_pending() then handoff() end;return true end end
    helpers.assert_eq(s.scope.apply('clear'),false);helpers.assert_true(handed);helpers.assert_eq(s.bytes[path],source)
    helpers.assert_true(s.scope.pending());helpers.assert_true(s.pairs.owns_configuration(s.scope))
    local foreign=s.bytes[other];helpers.assert_eq(s.scope.retry_restore(),false);helpers.assert_eq(s.bytes[other],foreign)
    s.route_path=nil;helpers.assert_true(s.scope.retry_restore());helpers.assert_eq(s.scope.pending(),false)
    helpers.assert_eq(s.bytes[other],foreign);helpers.assert_eq(s.pairs.get_action(pair),'open_url')
   end,nil,function(s)
    if stage=='parameter_release' then
     local release=s.gestures.release_parameter_configuration
     s.gestures.release_parameter_configuration=function(token)
      local accepted=release(token)
      if accepted and s.publications==1 and s.after_parameter_release then s.after_parameter_release() end
      return accepted
     end
    end
   end)
  end)
 end
end)

helpers.describe("independent global terminal parameter debt fence",function()
 helpers.it("retains installed pair input fence while final parameter release is refused",function()
  with_owner(function(s)
   helpers.assert_eq(s.scope.apply('clear'),false);helpers.assert_true(s.scope.pending())
   local guard=s.pairs.capture_runtime()
   print('GLOBAL_PARAMETER_TERMINAL_DEBT pair_pending='..tostring(s.pairs.configuration_pending())..' runtime_admitted='..tostring(type(guard)=='function' and guard()==true)..' installed='..tostring(s.native~=nil))
   helpers.assert_eq(s.pairs.configuration_pending(),true,'Unsettled exact global inverse must keep pair delivery fenced')
  end,true,function(s) s.gestures.release_parameter_configuration=function() return false end end)
 end)
end)

helpers.describe("global terminal parameter refusal recovery",function()
 for _,mode in ipairs({"false","throw"}) do
  helpers.it("keeps exact native pair fence until "..mode.." terminal release acknowledges recovery",function()
   local accepted=false
   with_owner(function(s)
    helpers.assert_eq(s.scope.apply('clear'),false);helpers.assert_true(s.scope.pending())
    helpers.assert_true(s.pairs.owns_configuration(s.scope));helpers.assert_true(s.pairs.configuration_pending())
    helpers.assert_eq(s.pairs.capture_runtime(),nil);helpers.assert_eq(s.native,nil)
    helpers.assert_eq(s.bytes[path],source);helpers.assert_eq(s.scope.retry_restore(),false)
    helpers.assert_true(s.pairs.configuration_pending());helpers.assert_eq(s.pairs.capture_runtime(),nil)
    accepted=true;helpers.assert_true(s.scope.retry_restore());helpers.assert_eq(s.scope.pending(),false)
    helpers.assert_eq(s.pairs.configuration_pending(),false);helpers.assert_true(s.native~=nil)
    helpers.assert_eq(s.pairs.get_action(pair),'open_url');helpers.assert_eq(s.bytes[path],source)
   end,true,function(s)
    local release=s.gestures.release_parameter_configuration
    s.gestures.release_parameter_configuration=function(token)
     if not accepted then if mode=='throw' then error('Controlled terminal release failure') end;return false end
     return release(token)
    end
   end)
  end)
 end
end)
helpers.describe("global staged delivery fence ownership",function()
 helpers.it("refuses foreign configuration acquisition within the final parameter callback",function()
  local foreign, ready, observed = {}, false, false
  with_owner(function(s)
   helpers.assert_eq(s.scope.apply('clear'),false);helpers.assert_true(observed)
   helpers.assert_true(s.pairs.owns_configuration(s.scope));helpers.assert_true(s.scope.pending())
   helpers.assert_eq(s.pairs.owns_configuration(foreign),false)
   ready=true;helpers.assert_true(s.scope.retry_restore());helpers.assert_eq(s.scope.pending(),false)
  end,true,function(s)
   local release=s.gestures.release_parameter_configuration
   s.gestures.release_parameter_configuration=function(token)
    if not ready then
     observed=true;helpers.assert_true(s.pairs.owns_delivery_fence(s.scope))
     helpers.assert_eq(s.pairs.acquire_configuration(foreign),false);return false
    end
    return release(token)
   end
  end)
 end)
 helpers.it("preserves an existing foreign native configuration owner",function()
  local foreign={}
  with_owner(function(s)
   helpers.assert_eq(s.scope.apply('clear'),false);helpers.assert_true(s.pairs.owns_configuration(foreign))
   helpers.assert_eq(s.scope.pending(),false);helpers.assert_eq(s.publications,0)
   helpers.assert_true(s.pairs.release_configuration(foreign));helpers.assert_true(s.scope.apply('clear'))
  end,true,function(s) helpers.assert_true(s.pairs.acquire_configuration(foreign)) end)
 end)
end)
helpers.describe("independent terminal callback native Shift fence",function()
 helpers.it("keeps native Shift fenced within the later terminal parameter callback",function()
  local tested, shift, admitted = false, false, false
  with_owner(function(s)
   helpers.assert_eq(s.scope.apply('clear'),false);helpers.assert_true(tested)
   print('TERMINAL_WINDOW native_shift='..tostring(shift)..' runtime_admitted='..tostring(admitted))
   helpers.assert_eq(shift,false,'Native pair Shift cannot emit before final parameter acknowledgement')
   helpers.assert_eq(admitted,false)
  end,true,function(s)
   s.gestures.release_parameter_configuration=function()
    if s.publications>=2 and not tested then
     tested=true;local guard=s.pairs.capture_runtime();admitted=type(guard)=='function' and guard()==true
     if s.native then
      local physical={ready=true,physical=true,source='controlled-owned-keyboard',generation=7}
      s.native:process(58,1,0,physical)
      local rows,_,_,frame=s.native:process(15,1,10,physical)
      for _,row in ipairs(rows or {}) do if row.code==42 and row.value==1 then shift=true end end
      if frame and frame.ack then frame.ack(true) end
     end
    end
    return false
   end
  end)
 end)
end)

-- Actual native ownership survives controlled fixtures and garbage collection.
helpers.describe("scope fixture native loop custody", function()
	helpers.it("test_global_shortcuts_pair_scope preserves its issuer and a real timer close receipt", function()
		local native = NativeLoop
		local detached = {}; for key, value in pairs(native) do detached[key] = value end
		helpers.assert_true(not rawequal(detached, native), "a detached lookalike is not the native issuer")
		with_owner(function()
			helpers.assert_true(rawequal(package.loaded.luv, native), "fixture uses the actual process-wide issuer")
			collectgarbage("collect")
		end)
		helpers.assert_true(rawequal(package.loaded.luv, native), "whole-cache restoration retains native issuer custody")
		collectgarbage("collect")
		local timer = assert(native.new_timer())
		local fired, settled = false, false
		native.timer_start(timer, 0, 0, function()
			fired = true
			native.timer_stop(timer)
			native.close(timer, function() settled = true end)
		end)
		for _ = 1, 20 do
			if settled then break end
			native.run("nowait")
		end
		helpers.assert_true(fired, "the actual native timer callback must run")
		helpers.assert_true(settled, "the exact native timer must physically close")
	end)
end)
local result=helpers.get_results();print('GLOBAL_PAIR_SUMMARY '..result.passed..'/'..result.failed);if result.failed~=0 then os.exit(1) end

-- These additive controls use actual declared Linux data, pair source leases,
-- parameter owners and conditional publication. Device/file edges are controlled.
local public_source = source .. '[mod_combos]\nenabled=false\nsimultaneous_threshold_ms=75\nsymmetric=true\n'
 .. '[mod_combos.config.caps_lock_then_tab]\ncombo="copy"\nfuture=17\n'
 .. '[mod_combos.config.future_then_tab]\ncombo="foreign_action"\n'
 .. '[category_enabled]\nkey_combinations=false\n'
local function seed_public_global(s)
 local token={}
 helpers.assert_true(s.pairs.acquire_configuration(token))
 s.bytes[path]=public_source
 helpers.assert_true(s.pairs.apply_configuration(token,s.pairs.configuration_candidate(Codec.decode(public_source),true)))
 helpers.assert_true(s.pairs.release_configuration(token))
end
helpers.describe("global scope includes only original known simultaneous leaves",function()
 for _,mode in ipairs({"clear","recommended"}) do
  helpers.it(mode.." retires known third slots while preserving foreign records and disabled switches",function()
   with_owner(function(s)
    helpers.assert_eq(s.pairs.get_chord(pair),"copy")
    helpers.assert_true(s.scope.apply(mode))
    local doc=Codec.decode(s.bytes[path])
    helpers.assert_eq(doc.mod_combos.config[pair].combo,nil)
    helpers.assert_eq(doc.mod_combos.config[pair].future,17)
    helpers.assert_eq(doc.mod_combos.config.future_then_tab.combo,"foreign_action")
    helpers.assert_eq(doc.mod_combos.enabled,false)
    if mode=="clear" then helpers.assert_eq(doc.category_enabled.key_combinations,false)
    else helpers.assert_eq(doc.category_enabled.key_combinations,nil) end
    helpers.assert_eq(doc.mod_combos.simultaneous_threshold_ms,nil)
    helpers.assert_eq(doc.mod_combos.symmetric,nil)
    helpers.assert_eq(doc.shortcuts.key_combination_taps.future_then_tab,"future")
    helpers.assert_eq(doc.gesture_parameters[parameter],nil)
    helpers.assert_eq(doc.unrelated.keep,42)
    helpers.assert_eq(s.pairs.get_chord(pair),"none")
    helpers.assert_eq(s.pairs.chord_settings(),{simultaneous_threshold_ms=100,combo_symmetric=false})
    helpers.assert_eq(s.scope.pending(),false)
    helpers.assert_true(s.scope.revert());helpers.assert_eq(s.bytes[path],public_source)
    helpers.assert_eq(s.pairs.get_chord(pair),"copy")
    helpers.assert_eq(s.pairs.chord_settings(),{simultaneous_threshold_ms=75,combo_symmetric=true})
   end,false,seed_public_global)
  end)
 end
 helpers.it("retains a foreign parameter owner without publishing or erasing third slots",function()
  with_owner(function(s)
   local foreign={};helpers.assert_true(s.gestures.acquire_parameter_configuration(foreign))
   helpers.assert_eq(s.scope.apply("clear"),false)
   helpers.assert_eq(s.publications,0);helpers.assert_eq(s.bytes[path],public_source)
   helpers.assert_eq(s.pairs.get_chord(pair),"copy");helpers.assert_eq(s.scope.pending(),false)
   helpers.assert_eq(s.pairs.configuration_pending(),false)
   helpers.assert_eq(s.gestures.acquire_parameter_configuration({}),false)
   helpers.assert_true(s.gestures.release_parameter_configuration(foreign))
   helpers.assert_true(s.scope.retry_restore());helpers.assert_eq(s.bytes[path],public_source)
   helpers.assert_eq(s.scope.pending(),false)
  end,false,seed_public_global)
 end)
 helpers.it("refuses stale third-source ownership before backup and restores no foreign bytes",function()
  with_owner(function(s)
   local foreign=public_source:gsub('combo="copy"','combo="open_url"',1)
   s.bytes[path]=foreign
   helpers.assert_eq(s.scope.apply("clear"),false)
   helpers.assert_eq(s.publications,0);helpers.assert_eq(s.bytes[backup],nil)
   helpers.assert_eq(s.bytes[path],foreign)
   s.bytes[path]=public_source;helpers.assert_true(s.scope.retry_restore())
   helpers.assert_eq(s.bytes[path],public_source);helpers.assert_eq(s.pairs.get_chord(pair),"copy")
  end,false,seed_public_global)
 end)
end)
