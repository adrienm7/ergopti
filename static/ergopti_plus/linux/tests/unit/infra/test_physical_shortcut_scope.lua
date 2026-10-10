--- tests/unit/infra/test_physical_shortcut_scope.lua

--- Scratch independent physical edit scope controls

--- Exercises the actual shortcut readers, dispatchers and parameter owner.
-- Preserve the process-wide C issuer before any whole-cache fixture snapshot.
-- Requiring it inside a fixture and erasing it on teardown reopens libuv state.
local NativeLoop = require("luv")
local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")
local Manifest = require("infra.manifest_reader")

local SOURCE = '[shortcuts]\nenabled = true\nwrap_text_if_selected = true\nchatgpt_url = "https://old.example"\nunknown = "keep"\n'
	.. '[shortcuts.keyboard]\nctrl_j = "open_url"\nctrl_k = "enter"\nctrl_p = "script_reload"\nforeign_slot = "keep"\n'
	.. '[shortcuts.tap_keys]\nnumber_row_left = "send_text"\nunknown = "keep"\n'
	.. '[gesture_parameters]\nkeyboard__ctrl_j__open_url = "https://old.example"\ntap_key__number_row_left__send_text = "typed"\n'
	.. 'tap_3__open_url = "https://gesture.example"\ntap_hold__caps_lock__open_url = "https://hold.example"\nunknown = "keep"\n'
	.. '[linux.action_parameters]\nkeyboard__ctrl_k__open_url = "https://legacy.example"\nunknown = "keep"\n'
	.. '[gestures]\nenabled = false\ntap_3 = "enter"\n[metrics]\nenabled = true\n[llm]\nenabled = true\n[other]\nvalue = 42\n'

--- Uses real state owners and only controlled native/file publication ports.
--- @param body function Test body.
--- @param source string|nil config.toml content; SOURCE by default.
local function with_scope(body, source)
	local loaded = {}
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local ok, err = pcall(function()
		Sandbox.with_config(source or SOURCE, function(path)
			for _, name in ipairs({ "modules.shortcuts.manager", "modules.shortcuts.keyboard_shortcuts", "modules.shortcuts.tap_keys",
				"modules.shortcuts.chatgpt", "modules.shortcuts.script_chords", "modules.gestures.manager",
				"infra.shortcuts_scope", "ui.menu.menu_builder" }) do
				package.loaded[name] = nil
			end
			local controls = { backups = {}, queued = {}, executed = {}, paused = false, device_calls = 0, runtime_calls = 0 }
			package.loaded["infra.config_paths"] = { config = function() return path end }
			package.loaded["adapters.storage"] = {
				get = function(_, default) return default end,
				set = function() error("shortcut scope must not write legacy storage") end,
			}
			package.loaded["adapters.evdev_reader"] = {
				TOUCHPAD = "touchpad", close = function() controls.device_calls = controls.device_calls + 1; return false end,
				open = function() controls.device_calls = controls.device_calls + 1; return false end,
			}
			package.loaded["ui.gesture_conflicts"] = { notify_boot = function() end }
			package.loaded["adapters.shell_runner"] = {
				has_command = function() return true end,
				quote = function(value) return "'" .. value .. "'" end,
				run = function(command) controls.executed[#controls.executed + 1] = command; return true end,
			}
			local ActualProgramOwner = require("modules.gestures.program_owner")
			controls.worker_observers, controls.worker_timers = {}, {}
			package.loaded["modules.gestures.program_owner"] = { new = function(capture)
				return ActualProgramOwner.new(capture, { runner = { spawn = function(_,_,_,admission)
					return {
						start = function() controls.worker_starts = (controls.worker_starts or 0) + 1; return admission() end,
						isSettled = function() return controls.worker_settled == true end,
						terminate = function() controls.worker_kills = (controls.worker_kills or 0) + 1; return true end,
						onSettled = function(callback) controls.worker_observers[#controls.worker_observers + 1] = callback; return true end,
					}
				end }, native = {
					new_timer = function() local timer = {}; controls.worker_timers[#controls.worker_timers + 1] = timer; return timer end,
					timer_start = function(timer, _, _, callback) timer.callback = callback; return 0 end,
					timer_stop = function(timer) timer.stopped = true; return 0 end,
					close = function(timer, callback) timer.closed = true; if callback then callback() end end,
				} })
			end }
			controls.finish_worker = function()
				controls.worker_settled = true
				for _, callback in ipairs(controls.worker_observers) do callback() end
			end
			local gestures = require("modules.gestures.manager")
			gestures.init({ persist = true, config_path = path, enabled = false })
			gestures.execute_action = function(action, binding)
				controls.executed[#controls.executed + 1] = action .. "@" .. binding
			end
			local manager = require("modules.shortcuts.manager")
			manager.init({ persist = true, config_path = path })
			local keyboard, taps = require("modules.shortcuts.keyboard_shortcuts"), require("modules.shortcuts.tap_keys")
			-- This fixture exercises the acknowledged software model, not native readiness.
			controls.native_delivery_available = keyboard.physical_delivery_available
			controls.delivery_available = true
			keyboard.physical_delivery_available = function() return controls.delivery_available end
			keyboard.get_assignments()
			taps.init({ is_active = function() return manager.is_enabled() and not controls.paused end,
				defer = function(callback) controls.queued[#controls.queued + 1] = callback; return true end })
			taps.get_action("number_row_left")
			local url = require("modules.shortcuts.chatgpt")
			local files = {
				read_with_status = function(target) return Writer.read_classified(target) end,
				write = function() error("unconditional configuration publication") end,
				write_if_unchanged = function(target, content, expected)
					if target ~= path then controls.backups[#controls.backups + 1] = target end
					if controls.before_publish then controls.before_publish(target) end
					if controls.refuse == target then return false, "injected publication refusal" end
					return Writer.publish_if_unchanged(target, content, nil, expected)
				end,
			}
			package.loaded["adapters.file_system"] = files
			local apply_keyboard = keyboard.apply_configuration
			keyboard.apply_configuration = function(token, state)
				controls.runtime_calls = controls.runtime_calls + 1
				local accepted = apply_keyboard(token, state)
				if controls.refuse_runtime then controls.refuse_runtime = false; return false end
				return accepted
			end
			local apply_parameters = gestures.apply_parameter_configuration
			gestures.apply_parameter_configuration = function(token, state)
				if controls.refuse_restore and state.keyboard__ctrl_j__open_url then return false end
				return apply_parameters(token, state)
			end
			local chords = require("modules.shortcuts.script_chords")
			chords.init({ is_paused = function() return controls.paused end,
				defer = function(callback) controls.queued[#controls.queued + 1] = callback; return true end })
			-- The now-supported ordered-pair owner is initialized under this exact source.
			package.loaded["modules.shortcuts.key_combinations"] = nil
			local Pair = require("modules.shortcuts.key_combinations")
			local pair_owner = Pair.new({ keys = {{id="caps_lock",key="caps_lock"},{id="tab",key="tab"}},
				hold_picker={modifiers={"shift","alt"},layers={"nav"}}, files=files, route=function() return path end,
				is_paused=function() return controls.paused end, actions={is_assignable=gestures.is_assignable},
				changed=function() return true end })
			assert(Pair.set_instance(pair_owner))
			local backup = path .. ".shortcuts-test-backup"
			local scope = require("infra.shortcuts_scope").new({ path = path, backup_path = backup,
				files = files, is_paused = function() return controls.paused end })
			controls.files = files
			local owners = { manager = manager, keyboard = keyboard, taps = taps, url = url, gestures = gestures,
				chords = chords }
			local passed, failure = pcall(body, scope, owners, controls, path, backup)
			for _, created in ipairs(controls.backups) do os.remove(created); os.remove(created .. ".tmp") end
			os.remove(backup)
			if not passed then error(failure, 0) end
		end)
	end)
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	if not ok then error(err, 0) end
end


helpers.describe("Linux actual physical edit scope", function()
	local source = '[shortcuts]\nenabled = true\n[shortcuts.keyboard]\nctrl_j = "open_url"\nforeign_slot = "keep"\n[gesture_parameters]\nkeyboard__ctrl_j__open_url = "https://prior.example"\nother_owner__send_text = "retain"\n[other]\nvalue = 42\n'
	local rows = {
		{section="shortcuts.keyboard",key="physical_none_KeyJ",value="send_text"},
		{section="gesture_parameters",key="keyboard__physical_none_KeyJ__send_text",value="★"},
	}
	local function event() return {physical=true,code=36,key="logical-x",mods={}} end
	local function ports(owners,controls)
		package.loaded["adapters.xkb_capture"]={source_generation=function() return 1 end}
		return {defer=function(fn) controls.queued[#controls.queued+1]=fn;return true end,
			admission=function() return {master=owners.manager.is_enabled(),paused=controls.paused,inhibited=false} end}
	end
	helpers.it("(physical-entry-scope) actual owner admits Unicode edits only after publication", function()
		with_scope(function(scope,owners,controls,path)
			local options=ports(owners,controls)
			controls.before_publish=function(target)
				if target==path then
					helpers.assert_eq(owners.gestures.get_action_parameter("keyboard__physical_none_KeyJ","send_text"),"★")
					helpers.assert_eq(owners.keyboard.consume(event(),options),false,"candidate input remains native during publication")
				end
			end
			helpers.assert_true(scope.edit(rows))
			local decoded=Codec.decode(Sandbox.read_bytes(path))
			helpers.assert_eq(decoded.shortcuts.keyboard.physical_none_KeyJ,"send_text")
			helpers.assert_eq(decoded.gesture_parameters.keyboard__physical_none_KeyJ__send_text,"★")
			helpers.assert_eq(decoded.gesture_parameters.keyboard__ctrl_j__open_url,"https://prior.example")
			helpers.assert_eq(decoded.gesture_parameters.other_owner__send_text,"retain")
			helpers.assert_eq(decoded.shortcuts.keyboard.foreign_slot,"keep")
			helpers.assert_true(owners.keyboard.consume(event(),options))
			helpers.assert_eq(#controls.executed,0,"hook execution remains deferred")
			for _,callback in ipairs(controls.queued) do callback() end
			helpers.assert_eq(controls.executed,{"send_text@keyboard__physical_none_KeyJ"})
			helpers.assert_eq(controls.device_calls,0,"scope edits never open/close native devices")
		end,source)
	end)
	helpers.it("(physical-entry-scope) publication refusal compensates actual action and parameters", function()
		with_scope(function(scope,owners,controls,path)
			local options=ports(owners,controls);controls.refuse=path
			controls.before_publish=function(target) if target==path then helpers.assert_eq(owners.keyboard.consume(event(),options),false) end end
			helpers.assert_eq(scope.edit(rows),false)
			helpers.assert_eq(Sandbox.read_bytes(path),source)
			helpers.assert_eq(owners.keyboard.get_action("physical_none_KeyJ"),"none")
			helpers.assert_eq(owners.gestures.get_action_parameter("keyboard__physical_none_KeyJ","send_text"),"")
			helpers.assert_eq(owners.gestures.get_action_parameter("keyboard__ctrl_j","open_url"),"https://prior.example")
			helpers.assert_eq(#controls.executed,0)
			helpers.assert_eq(scope.pending(),false)
		end,source)
	end)
	helpers.it("(physical-entry-scope) Remove deletes actual None and only its owned parameter", function()
		local existing=source..'[shortcuts.keyboard]\nphysical_none_KeyJ = "none"\n'
		-- Replace the existing table rows in one valid source, keeping an old parameter.
		existing=source:gsub('foreign_slot = "keep"','foreign_slot = "keep"\nphysical_none_KeyJ = "none"')
		existing=existing:gsub('other_owner__send_text = "retain"','other_owner__send_text = "retain"\nkeyboard__physical_none_KeyJ__send_text = "★"')
		with_scope(function(scope,owners,controls,path)
			helpers.assert_true(scope.edit({{section="shortcuts.keyboard",key="physical_none_KeyJ",delete=true},
				{section="gesture_parameters",key="keyboard__physical_none_KeyJ__send_text",delete=true}}))
			local decoded=Codec.decode(Sandbox.read_bytes(path))
			helpers.assert_eq(decoded.shortcuts.keyboard.physical_none_KeyJ,nil)
			helpers.assert_eq(decoded.gesture_parameters.keyboard__physical_none_KeyJ__send_text,nil)
			helpers.assert_eq(decoded.gesture_parameters.keyboard__ctrl_j__open_url,"https://prior.example")
			helpers.assert_eq(decoded.gesture_parameters.other_owner__send_text,"retain")
			helpers.assert_eq(owners.keyboard.physical_assignments(),{})
		end,existing)
	end)
	helpers.it("(physical-entry-scope) explicit None remains durable personal intent", function()
		with_scope(function(scope,owners,controls,path)
			helpers.assert_true(scope.edit({{section="shortcuts.keyboard",key="physical_none_KeyJ",value="none",intent="keyboard_assignment"}}))
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).shortcuts.keyboard.physical_none_KeyJ,"none")
			helpers.assert_eq(#owners.keyboard.physical_assignments(),1)
			helpers.assert_eq(owners.keyboard.consume(event(),ports(owners,controls)),false)
		end,source)
	end)

	for _, seam in ipairs({"admission_lease","source_lease","transient_lease","parameter_lease","parameter_change"}) do
		helpers.it("(physical-reentry) actual consumer cancels after "..seam,function()
			with_scope(function(scope,owners,controls,path)
				helpers.assert_true(scope.edit(rows));local options=ports(owners,controls)
				helpers.assert_true(owners.keyboard.consume(event(),options))
				local entered,token=false,{}
				local function reenter()
					if entered then return end;entered=true
					if seam=="parameter_lease" then
						helpers.assert_true(owners.gestures.acquire_parameter_configuration(token))
						helpers.assert_true(owners.gestures.release_parameter_configuration(token))
					elseif seam=="parameter_change" then helpers.assert_true(owners.gestures.set_action_parameter("keyboard__physical_none_KeyJ","send_text","changed"))
					else
						helpers.assert_true(owners.keyboard.acquire_configuration(token))
						if seam=="transient_lease" then helpers.assert_true(owners.keyboard.release_configuration(token)) end
					end
				end
				if seam=="admission_lease" then options.admission=function() reenter();return {master=true,paused=false,inhibited=false} end
				else package.loaded["adapters.xkb_capture"].source_generation=function() reenter();return 1 end end
				for _,callback in ipairs(controls.queued) do callback() end
				helpers.assert_true(entered,"controlled callback ran")
				helpers.assert_eq(controls.executed,{},"old frame cannot execute after callback reentry")
				if seam=="admission_lease" or seam=="source_lease" then helpers.assert_true(owners.keyboard.release_configuration(token)) end
			end,source)
		end)
	end
	helpers.it("(physical-reentry) physical None preserves an older nonneutral logical action",function()
		with_scope(function(scope,owners,controls,path)
			helpers.assert_true(scope.edit({{section="shortcuts.keyboard",key="physical_ctrl_KeyJ",value="none",intent="keyboard_assignment"}}))
			local options=ports(owners,controls)
			local consumed,slot=owners.keyboard.consume({physical=true,code=36,key="j",mods={ctrl=true}},options)
			helpers.assert_true(consumed);helpers.assert_eq(slot,"ctrl_j")
			for _,callback in ipairs(controls.queued) do callback() end
			helpers.assert_eq(controls.executed,{"open_url@keyboard__ctrl_j"})
		end,source)
	end)

 helpers.it('(physical-program-scope) actual retained child blocks edit and inverse until settlement',function()
  local scalar='{"version":1,"executable":"/bin/sh","arguments":[]}'
  local source='[shortcuts]\nenabled=true\n[shortcuts.keyboard]\nphysical_none_KeyJ="run_program"\n[gesture_parameters]\nkeyboard__physical_none_KeyJ__run_program=\''..scalar..'\'\n'
  with_scope(function(scope, owners, controls, path)
   helpers.assert_eq(owners.gestures.run_program('keyboard__physical_none_KeyJ'),true,'Actual parameter/action owner starts controlled child')
   helpers.assert_eq(controls.worker_starts,1)
   local rows={{section='shortcuts.keyboard',key='physical_none_KeyJ',value='send_text',intent='keyboard_assignment'},
    {section='gesture_parameters',key='keyboard__physical_none_KeyJ__send_text',value='★'}}
   helpers.assert_eq(scope.edit(rows),false,'Signal acceptance is not child retirement')
   helpers.assert_eq(scope.pending(),true,'Exact global scope retains parameter/input leases')
   helpers.assert_eq(controls.worker_kills,1)
   helpers.assert_eq(#controls.backups,0,'No backup or native candidate before actual child retirement')
   helpers.assert_eq(Writer.read_classified(path),source,'Source unchanged during retirement debt')
   helpers.assert_eq(scope.retry_restore(),false,'Same unsettled native child keeps scope blocked')
   helpers.assert_eq(owners.gestures.run_program('keyboard__physical_none_KeyJ'),false,'Lease refuses replacement child')
   controls.finish_worker()
   helpers.assert_eq(scope.retry_restore(),true)
   helpers.assert_eq(scope.pending(),false)
   helpers.assert_eq(scope.edit(rows),true,'Explicit retry can publish after native child ACK')
   helpers.assert_eq(owners.keyboard.get_action('physical_none_KeyJ'),'send_text')
  end,source)
 end)
 helpers.it('(physical-source-frame) mismatched actual parameter value refuses before backup and candidate apply',function()
  with_scope(function(scope,owners,controls,path)
   local token={};helpers.assert_true(owners.gestures.acquire_parameter_configuration(token))
   local params=owners.gestures.parameter_configuration_snapshot(token);params.keyboard__ctrl_j__open_url='https://runtime-different.example'
   helpers.assert_true(owners.gestures.apply_parameter_configuration(token,params));helpers.assert_true(owners.gestures.release_parameter_configuration(token))
   helpers.assert_eq(scope.edit({{section='shortcuts.keyboard',key='physical_none_KeyJ',value='none',intent='keyboard_assignment'}}),false)
   helpers.assert_eq(#controls.backups,0);helpers.assert_eq(controls.runtime_calls,0)
   helpers.assert_eq(Writer.read_classified(path),SOURCE)
   helpers.assert_eq(scope.pending(),false)
   helpers.assert_eq(owners.gestures.get_action_parameter('keyboard__ctrl_j','open_url'),'https://runtime-different.example','Refusal preserves foreign runtime intent')
  end)
 end)
 helpers.it('(physical-source-frame) deleted actual parameter refuses before backup and candidate apply',function()
  with_scope(function(scope,owners,controls,path)
   local token={};helpers.assert_true(owners.gestures.acquire_parameter_configuration(token))
   local params=owners.gestures.parameter_configuration_snapshot(token);params.keyboard__ctrl_j__open_url=nil
   helpers.assert_true(owners.gestures.apply_parameter_configuration(token,params));helpers.assert_true(owners.gestures.release_parameter_configuration(token))
   helpers.assert_eq(scope.edit({{section='shortcuts.keyboard',key='physical_none_KeyJ',value='none',intent='keyboard_assignment'}}),false)
   helpers.assert_eq(#controls.backups,0);helpers.assert_eq(controls.runtime_calls,0);helpers.assert_eq(Writer.read_classified(path),SOURCE)
   helpers.assert_eq(scope.pending(),false)
  end)
 end)

 helpers.it('(physical-editor-frame) exact native snapshot commits under its opaque receipt',function()
  with_scope(function(scope,owners,controls,path)
   local inventory,receipt=scope.capture_editor_inventory();helpers.assert_true(type(inventory)=='table',tostring(receipt))
   helpers.assert_eq(inventory.assignments,{})
   helpers.assert_eq(scope.editor_source_current(receipt),true)
   inventory.assignments.physical_none_KeyA='send_text';helpers.assert_eq(owners.keyboard.get_action('physical_none_KeyA'),'none')
   helpers.assert_eq(scope.edit({{section='shortcuts.keyboard',key='physical_none_KeyJ',value='send_text',intent='keyboard_assignment'},
    {section='gesture_parameters',key='keyboard__physical_none_KeyJ__send_text',value='★'}},receipt),true)
   helpers.assert_eq(scope.editor_source_current(receipt),false)
   local current=scope.capture_editor_inventory();helpers.assert_eq(current.assignments.physical_none_KeyJ,'send_text')
   helpers.assert_eq(current.parameters.keyboard__physical_none_KeyJ__send_text,'★')
  end)
 end)
 for _, mode in ipairs({'canonical_file','runtime_parameter','forged_receipt'}) do
  helpers.it('(physical-editor-frame) refuses '..mode..' with no backup',function()
   with_scope(function(scope,owners,controls,path)
    local inventory,receipt=scope.capture_editor_inventory();helpers.assert_true(type(inventory)=='table',tostring(receipt))
    if mode=='canonical_file' then
     helpers.assert_true(Writer.publish_if_unchanged(path,SOURCE..'# foreign publisher\n',nil,{status='ok',content=SOURCE}))
    elseif mode=='runtime_parameter' then
     helpers.assert_true(owners.gestures.set_action_parameter('keyboard__ctrl_j','open_url','https://unpublished.example'))
    else receipt={} end
    local before=Writer.read_classified(path)
    helpers.assert_eq(scope.editor_source_current(receipt),false)
    local committed,reason=scope.edit({{section='shortcuts.keyboard',key='physical_none_KeyJ',value='none',intent='keyboard_assignment'}},receipt)
    helpers.assert_eq(committed,false);helpers.assert_eq(reason,'source_changed')
    helpers.assert_eq(#controls.backups,0);helpers.assert_eq(controls.runtime_calls,0);helpers.assert_eq(Writer.read_classified(path),before)
   end)
  end)
 end

end)
helpers.describe('successive physical editor operations under one native issuer',function()
 helpers.it('acknowledges Unicode Add, Edit, Remove and latest inverse with distinct backups',function()
  with_scope(function(scope,owners,controls,path)
   local _,receipt=scope.capture_editor_inventory()
   helpers.assert_true(scope.edit({{section='shortcuts.keyboard',key='physical_none_KeyJ',value='send_text',intent='keyboard_assignment'},{section='gesture_parameters',key='keyboard__physical_none_KeyJ__send_text',value='★'}},receipt))
   local added=Writer.read_classified(path)
   _,receipt=scope.capture_editor_inventory()
   helpers.assert_true(scope.edit({{section='shortcuts.keyboard',key='physical_none_KeyJ',value='send_text',intent='keyboard_assignment'},{section='gesture_parameters',key='keyboard__physical_none_KeyJ__send_text',value='☆'}},receipt))
   local edited=Writer.read_classified(path);helpers.assert_true(added~=edited)
   helpers.assert_eq(owners.gestures.get_action_parameter('keyboard__physical_none_KeyJ','send_text'),'☆')
   _,receipt=scope.capture_editor_inventory()
   helpers.assert_true(scope.edit({{section='shortcuts.keyboard',key='physical_none_KeyJ',delete=true},{section='gesture_parameters',key='keyboard__physical_none_KeyJ__send_text',delete=true}},receipt))
   local removed=Codec.decode(Writer.read_classified(path));helpers.assert_eq(removed.shortcuts.keyboard.physical_none_KeyJ,nil);helpers.assert_eq(removed.gesture_parameters.keyboard__physical_none_KeyJ__send_text,nil)
   helpers.assert_eq(#controls.backups,3);helpers.assert_true(controls.backups[1]~=controls.backups[2]);helpers.assert_true(controls.backups[2]~=controls.backups[3])
   helpers.assert_eq(scope.pending(),false);helpers.assert_true(scope.revert());helpers.assert_eq(Writer.read_classified(path),edited)
   helpers.assert_eq(owners.gestures.get_action_parameter('keyboard__physical_none_KeyJ','send_text'),'☆')
  end)
 end)
end)

helpers.describe('Actual shared physical editor to Linux native scope',function()
 helpers.it('(physical-editor-ui) Unicode Add publishes through exact actual source-return ACK',function()
  with_scope(function(scope,owners,controls,path)
   local Json=require('json');local file=assert(io.open(helpers.driver_root() .. "/../_shared/data/keycodes/physical_keys.json"));local model=require('shortcuts.physical_slots').new(Json.decode(file:read('*a')));file:close()
   local callback,selected
   local editor=require('shortcuts.physical_editor').new({model=model,catalogue=owners.gestures,parameter_section='gesture_parameters',positions={},capture=scope.capture_editor_inventory,current=scope.editor_source_current,commit=scope.edit,label=owners.gestures.get_action_label,picker=function(_,_,confirm)callback=confirm;return true end,emit=function(value)selected=value;return true end})
   helpers.assert_eq(#editor.open().entries,0)
   helpers.assert_eq(editor.choose({code='KeyJ',mods={ctrl=true},request_id=1}),true);helpers.assert_eq(callback('send_text','★'),true)
   helpers.assert_eq(#controls.backups,0,'Draft never publishes scalar/assignment')
   local outcome=editor.save(selected.token);helpers.assert_eq(outcome.committed,true);helpers.assert_eq(outcome.refreshed,true)
   local config=Codec.decode(Writer.read_classified(path));helpers.assert_eq(config.shortcuts.keyboard.physical_ctrl_KeyJ,'send_text');helpers.assert_eq(config.gesture_parameters.keyboard__physical_ctrl_KeyJ__send_text,'★');helpers.assert_eq(config.shortcuts.keyboard.foreign_slot,'keep');helpers.assert_eq(config.gesture_parameters.unknown,'keep')
   helpers.assert_eq(editor.remove('physical_ctrl_KeyJ').committed,true);config=Codec.decode(Writer.read_classified(path));helpers.assert_eq(config.shortcuts.keyboard.physical_ctrl_KeyJ,nil);helpers.assert_eq(config.gesture_parameters.keyboard__physical_ctrl_KeyJ__send_text,nil);helpers.assert_eq(config.gesture_parameters.unknown,'keep')
  end)
 end)
 helpers.it('(physical-editor-ui) foreign canonical source refuses retained draft without backup',function()
  with_scope(function(scope,owners,controls,path)
   local Json=require('json');local file=assert(io.open(helpers.driver_root() .. "/../_shared/data/keycodes/physical_keys.json"));local model=require('shortcuts.physical_slots').new(Json.decode(file:read('*a')));file:close()
   local callback,selected
   local editor=require('shortcuts.physical_editor').new({model=model,catalogue=owners.gestures,parameter_section='gesture_parameters',positions={},capture=scope.capture_editor_inventory,current=scope.editor_source_current,commit=scope.edit,label=owners.gestures.get_action_label,picker=function(_,_,confirm)callback=confirm;return true end,emit=function(value)selected=value;return true end})
   editor.open();editor.choose({code='KeyJ',mods={},request_id=1});helpers.assert_eq(callback('send_text','★'),true)
   local foreign=SOURCE..'# foreign editor\n';helpers.assert_true(Writer.publish_if_unchanged(path,foreign,nil,{status='ok',content=SOURCE}))
   helpers.assert_eq(editor.save(selected.token).committed,false);helpers.assert_eq(#controls.backups,0);helpers.assert_eq(Writer.read_classified(path),foreign)
  end)
 end)
end)

helpers.describe('Retained Linux physical editor issuer factory',function()
 helpers.it('(physical-editor-ui) pure readiness never captures or retries the source owner',function()
  local created,opened,refused=0,0,0
  local paused,ready=false,true
  local host={physical_delivery_available=function()return true end,native_available=function()return ready end,available=function(owner)return owner~=nil end,open=function(options)helpers.assert_eq(options.scope.marker,'native');opened=opened+1;return true end}
  local ports=require('shortcuts.physical_editor_menu').new({scope=function()created=created+1;return{marker='native'}end,host=function()return host end,paused=function()return paused end,refused=function()refused=refused+1 end})
  helpers.assert_eq(ports.ready(),true);helpers.assert_eq(created,0);helpers.assert_eq(opened,0)
  paused=true;helpers.assert_eq(ports.open(),false);helpers.assert_eq(created,0);helpers.assert_eq(refused,1)
  paused=false;ready=false;helpers.assert_eq(ports.ready(),false);helpers.assert_eq(ports.open(),false);helpers.assert_eq(created,0)
  ready=true;helpers.assert_eq(ports.open(),true);helpers.assert_eq(created,1);helpers.assert_eq(opened,1)
 end)
 helpers.it('(physical-editor-ui) same native issuer survives window reopen and canonical edits',function()
  with_scope(function(_,owners,controls,path)
   local Scope=require('infra.shortcuts_scope');local paused=function()return controls.paused end
   local owner=Scope.editor_owner(paused);helpers.assert_true(type(owner)=='table')
   helpers.assert_eq(Scope.editor_owner(paused),owner,'Reopen retains exact receipt issuer')
   local inventory,receipt=owner.capture_editor_inventory();helpers.assert_true(type(inventory)=='table')
   helpers.assert_eq(owner.edit({{section='shortcuts.keyboard',key='physical_none_KeyJ',value='none',intent='keyboard_assignment'}},receipt),true)
   helpers.assert_eq(Scope.editor_owner(paused),owner)
   local _,current=owner.capture_editor_inventory();helpers.assert_eq(owner.edit({{section='shortcuts.keyboard',key='physical_none_KeyJ',delete=true}},current),true)
   helpers.assert_eq(Codec.decode(Writer.read_classified(path)).shortcuts.keyboard.physical_none_KeyJ,nil)
   local entered=false;helpers.assert_eq(Scope.editor_owner(function()if not entered then entered=true;helpers.assert_eq(Scope.editor_owner(paused),nil,'Reentrant factory cannot replace owner')end;return false end),owner)
   controls.paused=true;helpers.assert_eq(Scope.editor_owner(paused),nil);controls.paused=false;helpers.assert_eq(Scope.editor_owner(paused),owner)
  end)
 end)
 helpers.it('(physical-editor-ui) reopen cannot replace an owner whose actual child retirement is pending',function()
  local scalar='{"version":1,"executable":"/bin/sh","arguments":[]}'
  local initial='[shortcuts]\nenabled=true\n[shortcuts.keyboard]\nphysical_none_KeyJ="run_program"\n[gesture_parameters]\nkeyboard__physical_none_KeyJ__run_program=\''..scalar..'\'\n'
  with_scope(function(_,owners,controls,path)
   local Scope=require('infra.shortcuts_scope');local paused=function()return controls.paused end;local owner=Scope.editor_owner(paused)
   helpers.assert_eq(owners.gestures.run_program('keyboard__physical_none_KeyJ'),true)
   local _,receipt=owner.capture_editor_inventory();helpers.assert_eq(owner.edit({{section='shortcuts.keyboard',key='physical_none_KeyJ',value='none',intent='keyboard_assignment'}},receipt),false)
   helpers.assert_eq(owner.pending(),true);helpers.assert_eq(Scope.editor_owner(paused),nil);helpers.assert_eq(owner.pending(),true);helpers.assert_eq(#controls.backups,0);helpers.assert_eq(Writer.read_classified(path),initial)
   controls.finish_worker();helpers.assert_eq(Scope.editor_owner(paused),owner);helpers.assert_eq(owner.pending(),false)
  end,initial)
 end)
 helpers.it('(physical-editor-ui) terminal pause callback cannot return a stale route owner',function()
  with_scope(function(_,owners,controls,path)
   local Scope=require('infra.shortcuts_scope');local paused=function()return false end;local owner=Scope.editor_owner(paused)
   local route,reads=path,0;package.loaded['infra.config_paths'].config=function()return route end
   local result=Scope.editor_owner(function()reads=reads+1;if reads==2 then route=path..'.foreign' end;return false end)
   helpers.assert_eq(reads,2);helpers.assert_eq(result,nil);helpers.assert_eq(#controls.backups,0);helpers.assert_eq(Writer.read_classified(path),SOURCE)
   route=path;helpers.assert_eq(Scope.editor_owner(paused),owner,'Refused final callback never discards exact issuer')
  end)
 end)
end)


-- Legacy values are author-written independent expectations, not converted effects.
local preserved_source=SOURCE..'[shortcuts.a_grave]\nenabled=true\nletter="c"\n[shortcuts.e_acute]\nenabled=false\nletter="z"\n[shortcuts.e_circ]\nenabled=true\nletter="f"\n[shortcuts.e_grave]\nenabled=true\nletter="w"\n[shortcuts.keys]\ncmd_star=true\n[hotstrings]\nmagic_key_source_char="j"\nmagic_key_source="KeyQ"\ntrigger_char="★"\n[hotstrings.magic_key.replace]\nenabled=true\n[legacy_future]\nkeep={nested="untouched"}\n'
local function assert_legacy(document)
 helpers.assert_eq(document.shortcuts.a_grave,{enabled=true,letter="c"})
 helpers.assert_eq(document.shortcuts.e_acute,{enabled=false,letter="z"})
 helpers.assert_eq(document.shortcuts.e_circ,{enabled=true,letter="f"})
 helpers.assert_eq(document.shortcuts.e_grave,{enabled=true,letter="w"})
 helpers.assert_eq(document.shortcuts.keys,{cmd_star=true})
 helpers.assert_eq(document.hotstrings,{magic_key_source_char="j",magic_key_source="KeyQ",trigger_char="★",magic_key={replace={enabled=true}}})
 helpers.assert_eq(document.legacy_future,{keep={nested="untouched"}})
 helpers.assert_eq(document.shortcuts.keyboard.foreign_slot,"keep")
 helpers.assert_eq(document.gesture_parameters.unknown,"keep")
end
local function planner_for(actions)
 local root=helpers.driver_root():gsub('/$','')..'/../_shared/'
 local file=assert(io.open(root..'data/keycodes/physical_keys.json','rb'));local registry=require('json').decode(file:read('*a'));assert(file:close())
 return require('shortcuts.physical_entries').new(require('shortcuts.physical_slots').new(registry),actions,{parameter_section='gesture_parameters'})
end
helpers.describe('Linux explicit physical entries preserve unrelated legacy semantics',function()
 helpers.it('does not invent a Unicode/J entry from accent letters or legacy magic defaults',function()
  with_scope(function(scope,owners,controls,path)
   local inventory=assert(scope.capture_editor_inventory())
   helpers.assert_eq(owners.keyboard.physical_assignments(),{})
   helpers.assert_eq(#controls.backups,0);helpers.assert_eq(Writer.read_classified(path),preserved_source)
   assert_legacy(Codec.decode(Writer.read_classified(path)))
   local rows,reason=planner_for(owners.gestures).plan({operation='remove',slot='physical_none_KeyJ'},inventory)
   helpers.assert_eq(rows,nil);helpers.assert_eq(reason,'entry_absent')
  end,preserved_source)
 end)
 helpers.it('Add/Edit/None/Remove and acknowledged latest inverse preserve every legacy field',function()
  with_scope(function(scope,owners,controls,path)
   local planner=planner_for(owners.gestures)
   for _,request in ipairs({
    {operation='add',slot='physical_none_KeyJ',action='send_text',parameter='é★💫é'},
    {operation='edit',slot='physical_none_KeyJ',action='send_text',parameter='àèçù,:.'},
    {operation='edit',slot='physical_none_KeyJ',action='none'},
    {operation='remove',slot='physical_none_KeyJ'},
   }) do
    local inventory,receipt=scope.capture_editor_inventory();helpers.assert_true(type(inventory)=='table')
    helpers.assert_true(scope.edit(assert(planner.plan(request,inventory)),receipt))
    local decoded=Codec.decode(Writer.read_classified(path));assert_legacy(decoded)
    helpers.assert_eq(decoded.shortcuts.keyboard.physical_none_KeyJ,request.operation=='remove' and nil or request.action)
    if request.action=='send_text' then
     helpers.assert_eq(decoded.gesture_parameters.keyboard__physical_none_KeyJ__send_text,request.parameter)
     helpers.assert_eq(owners.gestures.get_action_parameter('keyboard__physical_none_KeyJ','send_text'),request.parameter)
    end
   end
   helpers.assert_true(scope.revert());local reverted=Codec.decode(Writer.read_classified(path));assert_legacy(reverted)
   helpers.assert_eq(reverted.shortcuts.keyboard.physical_none_KeyJ,'none')
   helpers.assert_eq(reverted.gesture_parameters.keyboard__physical_none_KeyJ__send_text,'àèçù,:.')
  end,preserved_source)
 end)
 helpers.it('refused explicit Unicode publication preserves the exact old canonical bytes',function()
  with_scope(function(scope,owners,controls,path)
   local inventory,receipt=scope.capture_editor_inventory()
   local rows=assert(planner_for(owners.gestures).plan({operation='add',slot='physical_none_KeyJ',action='send_text',parameter='★'},inventory))
   controls.refuse=path;helpers.assert_eq(scope.edit(rows,receipt),false)
   helpers.assert_eq(Writer.read_classified(path),preserved_source);assert_legacy(Codec.decode(Writer.read_classified(path)))
   helpers.assert_eq(owners.keyboard.physical_assignments(),{});helpers.assert_eq(scope.pending(),false)
  end,preserved_source)
 end)
end)

helpers.describe("Linux unqualified physical delivery admission", function()
	local source = '[shortcuts]\nenabled=true\n[shortcuts.keyboard]\nctrl_k="enter"\nforeign_slot="keep"\nphysical_none_KeyJ="send_text"\n[gesture_parameters]\nkeyboard__physical_none_KeyJ__send_text="owned"\nother_owner__send_text="keep"\n'
	local function options(owners, controls)
		package.loaded["adapters.xkb_capture"] = {source_generation=function() return 1 end}
		return {defer=function(fn) controls.queued[#controls.queued+1]=fn;return true end,
			admission=function() return {master=owners.manager.is_enabled(),paused=false,inhibited=false} end}
	end
	helpers.it("(partial-physical-admission) refuses native physical dispatch without a qualified output owner", function()
		with_scope(function(scope, owners, controls)
			helpers.assert_eq(controls.native_delivery_available(), false)
			controls.delivery_available=false
			helpers.assert_eq(scope.physical_delivery_available(), false)
			helpers.assert_eq(owners.keyboard.consume({physical=true,code=36,key="x",mods={}}, options(owners,controls)), false)
			helpers.assert_eq(#controls.queued, 0)
			helpers.assert_eq(#controls.executed, 0)
		end, source)
	end)
	helpers.it("(partial-physical-admission) refuses manual Save and parameters before backup or runtime application", function()
		with_scope(function(scope, owners, controls, path)
			controls.delivery_available=false
			for _, rows in ipairs({
				{{section="shortcuts.keyboard",key="physical_none_KeyK",value="send_text"}},
				{{section="gesture_parameters",key="keyboard__physical_none_KeyJ__send_text",value="changed"}},
			}) do
				local accepted, reason=scope.edit(rows)
				helpers.assert_eq(accepted,false);helpers.assert_eq(reason,"unavailable")
			end
			helpers.assert_eq(Sandbox.read_bytes(path), source)
			helpers.assert_eq(#controls.backups, 0)
			helpers.assert_eq(controls.runtime_calls, 0)
			helpers.assert_eq(scope.pending(), false)
		end, source)
	end)
	helpers.it("(partial-physical-admission) preserves None and Delete through acknowledged source publication", function()
		with_scope(function(scope, owners, controls, path)
			controls.delivery_available=false
			helpers.assert_true(scope.edit({{section="shortcuts.keyboard",key="physical_none_KeyJ",value="none"}}))
			local consumed,slot=owners.keyboard.consume({physical=true,code=36,key="x",mods={}},options(owners,controls))
			helpers.assert_eq(consumed,false);helpers.assert_eq(slot,"physical_none_KeyJ")
			helpers.assert_true(scope.edit({{section="shortcuts.keyboard",key="physical_none_KeyJ",delete=true},
				{section="gesture_parameters",key="keyboard__physical_none_KeyJ__send_text",delete=true}}))
			local document=Codec.decode(Sandbox.read_bytes(path))
			helpers.assert_eq(document.shortcuts.keyboard.physical_none_KeyJ,nil)
			helpers.assert_eq(document.shortcuts.keyboard.ctrl_k,"enter")
			helpers.assert_eq(document.shortcuts.keyboard.foreign_slot,"keep")
			helpers.assert_eq(document.gesture_parameters.other_owner__send_text,"keep")
		end, source)
	end)
	helpers.it("(partial-physical-admission) revokes queued modeled delivery if availability is lost", function()
		with_scope(function(_, owners, controls)
			local opts=options(owners,controls)
			helpers.assert_true(owners.keyboard.consume({physical=true,code=36,key="x",mods={}},opts))
			controls.delivery_available=false
			for _,callback in ipairs(controls.queued) do callback() end
			helpers.assert_eq(#controls.executed,0)
		end, source)
	end)
end)

helpers.describe("Physical native host and menu capability admission", function()
	helpers.it("(partial-physical-admission) never equates acknowledged GUI readiness with physical output custody", function()
		with_scope(function(scope, _, controls)
			controls.delivery_available=false
			local native_queries, opened, captures=0,0,0
			package.loaded["ui.webview_manager"]={native_available=function() native_queries=native_queries+1;return true end}
			package.loaded["ui.physical_shortcuts.bridge"]=nil
			local host=require("ui.physical_shortcuts.bridge")
			helpers.assert_eq(host.physical_delivery_available(),false)
			helpers.assert_eq(host.available(scope),false)
			local menu=require("shortcuts.physical_editor_menu").new({host=function()return host end,
				scope=function()captures=captures+1;return scope end,paused=function()return false end,
				refused=function()opened=opened+1 end})
			helpers.assert_eq(menu.ready(),false)
			helpers.assert_eq(menu.open(),false)
			helpers.assert_eq(captures,0);helpers.assert_eq(native_queries,0);helpers.assert_eq(opened,1)
		end)
	end)
end)

helpers.describe("Strict closed physical capability results", function()
	helpers.it("(partial-physical-admission) refuses missing unknown and throwing capability receipts", function()
		with_scope(function(scope, owners, controls, path)
			for _, value in ipairs({false, 0, "true", {}}) do
				controls.delivery_available=value
				helpers.assert_eq(scope.physical_delivery_available(),false)
				local accepted,reason=scope.edit({{section="shortcuts.keyboard",key="physical_none_KeyJ",value="send_text"}})
				helpers.assert_eq(accepted,false);helpers.assert_eq(reason,"unavailable")
			end
			for _, query in ipairs({function()return nil end,function()error("private capability detail")end}) do
				owners.keyboard.physical_delivery_available=query
				helpers.assert_eq(scope.physical_delivery_available(),false)
				local accepted,reason=scope.edit({{section="shortcuts.keyboard",key="physical_none_KeyJ",value="send_text"}})
				helpers.assert_eq(accepted,false);helpers.assert_eq(reason,"unavailable")
			end
			owners.keyboard.physical_delivery_available=nil
			helpers.assert_eq(scope.physical_delivery_available(),false)
			helpers.assert_eq(#controls.backups,0);helpers.assert_eq(controls.runtime_calls,0)
			helpers.assert_true(type(Sandbox.read_bytes(path))=="string")
		end)
	end)
end)

helpers.describe("Detached physical admission rows", function()
	helpers.it("(physical-row-custody) admitted None cannot become an active mapping inside program retirement", function()
		with_scope(function(scope, owners, controls, path)
			controls.delivery_available=false
			local updates={{section="shortcuts.keyboard",key="physical_none_KeyJ",value="none"}}
			local original=owners.gestures.stop_programs
			owners.gestures.stop_programs=function() updates[1].value="send_text";return original() end
			helpers.assert_true(scope.edit(updates))
			helpers.assert_eq(updates[1].value,"send_text","native callback actually mutated the caller's rows")
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).shortcuts.keyboard.physical_none_KeyJ,"none")
			helpers.assert_eq(owners.keyboard.get_action("physical_none_KeyJ"),"none")
		end)
	end)
end)

-- Actual native ownership survives controlled fixtures and garbage collection.
helpers.describe("scope fixture native loop custody", function()
	helpers.it("test_physical_shortcut_scope preserves its issuer and a real timer close receipt", function()
		local native = NativeLoop
		local detached = {}; for key, value in pairs(native) do detached[key] = value end
		helpers.assert_true(not rawequal(detached, native), "a detached lookalike is not the native issuer")
		with_scope(function()
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
