--- tests/support/infra/scope/key_combinations_scope_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_key_combinations_scope
--- DESCRIPTION:
--- Prelude shared by the test_key_combinations_scope_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local NativeLoop = require("luv")

local helpers = require("tests.helpers")

local Codec = require("toml_codec")

local Scope = require("infra.key_combinations_scope")

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

local function with_owner(body, managed, public_chords)
	local saved = {}; for name, value in pairs(package.loaded) do saved[name] = value end
	local ok, err = pcall(function()
		if public_chords~=true then require("tests.support.key_combination_declaration_fixture").install_unavailable() end
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
		local keys = { {id="caps_lock",key="caps_lock"}, {id="tab",key="tab"} }
		if public_chords==true then
			local file=assert(io.open(require("infra.paths").shared("tap_hold/defaults.toml"),"rb"))
			local defaults=assert(Codec.decode(file:read("*a")));assert(file:close())
			keys=require("tap_hold.key_catalog").for_platform(defaults,"linux")
		end
		state.pairs = PairOwner.new({ keys = keys,
			hold_picker = { modifiers = {"shift","alt"}, layers = {"nav"} }, files = files,
			route = function() return path end, is_paused = function() return state.paused end,
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
		state.scope = Scope.new({path=path,backup_path=backup,files=files,combinations=state.pairs,parameters=gestures,
			manifest=public_chords==true and require("infra.manifest_reader") or {scope_plan=function(scope, mode)
				helpers.assert_eq(scope,"shortcuts");helpers.assert_eq(mode,"clear");return {presets={},operations={}}
			end},is_paused=function() return state.paused end})
		body(state)
	end)
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not ok then error(err,0) end
end

local function failed(value) helpers.assert_eq(value,false) end

local function next_scope(s,expected,manifest,tag)
	return Scope.new({path=path,backup_path=backup..(tag or ".next"),files=s.files,combinations=s.pairs,parameters=s.gestures,
		manifest=manifest or require("infra.manifest_reader"),is_paused=function() return s.paused end,expected_source=expected})
end

local function with_menu(body, public_chords)
	with_owner(function(s)
		package.loaded["adapters.file_system"]=s.files
		package.loaded["infra.config_paths"]={config=function() return path end}
		package.loaded["infra.key_combinations_scope"]=nil
		package.loaded["ui.menu.key_combinations"]=nil
		local renderer=require("infra.manifest_menu")
		local i18n=require("infra.i18n")
		local Holds=require("tap_hold.hold_options")
		local keys={{id="caps_lock",key="caps_lock",hand="left"},{id="tab",key="tab",hand="left"}}
		if public_chords==true then
			local file=assert(io.open(require("infra.paths").shared("tap_hold/defaults.toml"),"rb"))
			local defaults=assert(Codec.decode(file:read("*a")));assert(file:close())
			keys=require("tap_hold.key_catalog").for_platform(defaults,"linux")
		end
		local holds=Holds.build({modifiers={"shift","alt"},layers={"nav"}})
		local PairOwner=require("modules.shortcuts.key_combinations")
		s.pairs=PairOwner.new({keys=keys,hold_picker={modifiers={"shift","alt"},layers={"nav"}},files=s.files,
			route=function() return path end,is_paused=function() return s.paused end,actions=s.gestures,changed=function() return true end})
		helpers.assert_true(PairOwner.set_instance(s.pairs))
		local ctx={gestures=s.gestures,tap_holds={key_catalog=function() return keys end,hold_options=function() return holds end},
			is_paused=function() return s.paused end,on_menu_changed=function() s.refreshes=(s.refreshes or 0)+1 end}
		local ui={manifest=renderer,get=i18n.get,key_label=function(key) return key.id end,
			action_label=function(action) return action end,error=function() s.errors=(s.errors or 0)+1 end,
			parameter=function() error("Program parameter must come from the native picker") end,
			open_hold_picker=function(label,current,items,confirm)
				s.hold_picker={label=label,current=current,items=items,confirm=confirm};return true
			end,
			prompt_delay=function(current,declared)
				s.delay_prompt={current,declared};if s.on_delay then s.on_delay() end;return s.delay_selection
			end,
			open_picker=function(label,current,binding,confirm,items)
				s.picker={label=label,current=current,binding=binding,confirm=confirm,items=items};return true
			end}
		s.build=function() return require("ui.menu.key_combinations").build(ctx,ui) end
		s.translate=i18n.get;s.context=ctx
		body(s)
	end,false,public_chords)
end

local function find_menu(rows,title,exact)
	for _,row in ipairs(rows) do
		if type(row.title)=="string" and ((exact==true and row.title==title) or (exact~=true and row.title:find(title,1,true))) then return row end
		if row.menu then local found=find_menu(row.menu,title,exact);if found then return found end end
	end
end

-- Public simultaneous source/publisher controls use the actual newly generated
-- Linux declaration. They are separate from the unchanged predecessor fixtures.
local function with_public_owner(body)
 return with_owner(body,false,true)
end

local function seed_public(s,text)
 local token={}
 helpers.assert_true(s.pairs.acquire_configuration(token))
 s.bytes[path]=text
 helpers.assert_true(s.pairs.apply_configuration(token,s.pairs.configuration_candidate(Codec.decode(text),true)))
 helpers.assert_true(s.pairs.release_configuration(token))
end

return {
	NativeLoop = NativeLoop,
	helpers = helpers,
	Codec = Codec,
	Scope = Scope,
	path = path,
	backup = backup,
	pair = pair,
	binding = binding,
	parameter = parameter,
	source = source,
	edits = edits,
	with_owner = with_owner,
	failed = failed,
	next_scope = next_scope,
	with_menu = with_menu,
	find_menu = find_menu,
	with_public_owner = with_public_owner,
	seed_public = seed_public,
}
