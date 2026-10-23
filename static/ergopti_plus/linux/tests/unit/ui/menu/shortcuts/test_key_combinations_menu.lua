--- tests/unit/ui/menu/shortcuts/test_key_combinations_menu.lua

--- Actual ordered-pair menu and canonical source owner. Modal/native delivery
--- ports are controlled; no grabbed input or GUI process is exercised here.
-- Retain the native loop issuer before the fixture snapshots package.loaded.
local NativeLoop = require("luv")
local helpers = require("tests.helpers")
local Codec = require("toml_codec")
local Shared = require("tap_hold.key_combinations")
local KeyCatalog = require("tap_hold.key_catalog")
local HoldOptions = require("tap_hold.hold_options")
local function with_menu(body)
	local saved = {}; for name,value in pairs(package.loaded) do saved[name]=value end
	local ok,err=pcall(function()
		require("tests.support.key_combination_declaration_fixture").install_unavailable()
		local Paths=require("infra.paths")
		local file=assert(io.open(Paths.shared("tap_hold/defaults.toml"),"rb"));local defaults=assert(Codec.decode(file:read("*a")));assert(file:close())
		file=assert(io.open(Paths.shared("data/locales/en.json"),"rb"));local locale=require("json").decode(file:read("*a"));assert(file:close())
		local function t(key) return locale[key] or key end
		local state={source="",paused=false,edits={},prompts=0,pickers=0,errors=0}
		local keys,holds=KeyCatalog.for_platform(defaults,"linux"),HoldOptions.build(defaults.tap_hold.hold_picker)
		package.loaded["modules.gestures.manager"]=nil
		local gestures=require("modules.gestures.manager")
		package.loaded["modules.shortcuts.key_combinations"]=nil
		local Pair=require("modules.shortcuts.key_combinations")
		local owner=Pair.new({keys=keys,hold_picker=defaults.tap_hold.hold_picker,route=function() return "/controlled/config.toml" end,
			files={read_with_status=function() return state.source,"ok" end},is_paused=function() return state.paused end,
			actions=gestures,changed=function() return true end});Pair.set_instance(owner)
		package.loaded["infra.key_combinations_scope"]={retry_restore=function() return true end,
			edit=function(rows,_,receipt)
				if receipt.guard()~=true then return false end
				state.edits[#state.edits+1]=rows;return true
			end,set_enabled=function() return true end}
		package.loaded["infra.i18n"]={get=t,section=t,get_locale=function() return "en" end}
		package.loaded["infra.manifest_menu"]=nil
		local renderer=require("infra.manifest_menu")
		package.loaded["ui.menu.key_combinations"]=nil
		local Menu=require("ui.menu.key_combinations")
		state.rows=Menu.build({tap_holds={key_catalog=function() return keys end,hold_options=function() return holds end},
			gestures=gestures,is_paused=function() return state.paused end},{manifest=renderer,get=t,key_label=function(entry) return t(entry.label_key) end,
			action_label=function(action) return action end,error=function() state.errors=state.errors+1 end,
			open_hold_picker=function(label,current,items,callback)
				state.prompts=state.prompts+1;state.hold={label=label,current=current,items=items,confirm=callback}
				return true
			end,open_picker=function(_,_,_,callback) state.pickers=state.pickers+1;state.confirm=callback;return true end})
		state.keys,state.holds,state.owner,state.translate=keys,holds,owner,t
		local function walk(rows,visit)
			for _,row in ipairs(rows or {}) do visit(row);walk(row.items or row.submenu or row.menu,visit) end
		end
		state.walk=walk
		function state.find(part)
			local found;walk(state.rows,function(row) if not found and tostring(row.label or row.title or ""):find(part,1,true) then found=row end end)
			return found
		end
		function state.click(row) return assert(row.action or row.fn)() end
		body(state)
	end)
	for name in pairs(package.loaded) do if saved[name]==nil then package.loaded[name]=nil end end
	for name,value in pairs(saved) do package.loaded[name]=value end
	if not ok then error(err,0) end
end
helpers.describe("bounded actual ordered-pair menu",function()
	helpers.it("retains every ordered pair and no eager hold-choice subtree",function()
		with_menu(function(state)
			local total,pairs=0,0;state.walk(state.rows,function(row)
				total=total+1;if tostring(row.label or row.title or ""):find("  :  ",1,true) then pairs=pairs+1 end
			end)
			helpers.assert_eq(#state.keys,14);helpers.assert_eq(pairs,182)
			helpers.assert_true(total<1200,"ordered pairs must fit the unchanged whole-tray ceiling")
			helpers.assert_eq(state.prompts,0);helpers.assert_eq(state.pickers,0)
		end)
	end)
	-- The maintainer's decision of 2026-10-22: the hold slot opens the shared
	-- action picker on the hold options, as the tap slot opens it on actions.
	helpers.it("opens the shared picker on the hold options only on click and publishes an exact hold (key-combination-hold-picker)",function()
		with_menu(function(state)
			local row=state.find("Hold 1 + hold 2 → ")
			helpers.assert_nil(row.items or row.submenu or row.menu,"the hold slot opens no submenu")
			helpers.assert_eq(state.prompts,0,"nothing opens before the click")
			state.click(row)
			helpers.assert_eq(state.prompts,1);helpers.assert_eq(state.pickers,0,"not the action catalogue")
			helpers.assert_eq(#state.hold.items,#state.holds-1,"every hold option but the picker's own none row")
			for index,item in ipairs(state.hold.items) do
				helpers.assert_eq(item.id,state.holds[index+1].id)
				helpers.assert_eq(item.label,HoldOptions.label(state.holds[index+1],state.translate))
			end
			helpers.assert_eq(state.hold.current,Shared.NONE,"an empty slot marks the none row")
			helpers.assert_eq(#state.edits,0,"opening writes nothing")
			helpers.assert_eq(state.hold.confirm("shift"),true)
			helpers.assert_eq(#state.edits,1);helpers.assert_eq(state.edits[1][1].section,Shared.HOLD_SECTION)
			helpers.assert_eq(state.edits[1][1].value,"shift")
		end)
	end)
	for _,mode in ipairs({"cancel","unknown","source","paused"}) do
		helpers.it("refuses "..mode.." without any publication and keeps the picker open (key-combination-hold-picker)",function()
			with_menu(function(state)
				state.click(state.find("Hold 1 + hold 2 → "))
				if mode=="source" then state.source="[unrelated]\nchanged=true\n" end
				if mode=="paused" then state.paused=true end
				if mode~="cancel" then
					helpers.assert_eq(state.hold.confirm(mode=="unknown" and "copy" or "shift"),false,
						"a refused pick returns false, so the bridge keeps the picker open")
				end
				helpers.assert_eq(#state.edits,0)
			end)
		end)
	end
end)

-- Independent Linux order: eight left-hand and six right-hand native keys.
-- This is an authored oracle, not a projection of the provider's rows.
local EXPECTED_LINUX_KEYS = {
	"escape", "tab", "caps_lock", "left_shift", "left_ctrl", "win", "left_alt", "space",
	"alt_gr", "right_ctrl", "right_shift", "enter", "backspace", "delete",
}

--- Reads canonical translation data independently of the active translator.
--- @param relative string Shared data file.
--- @return table
local function read_locale_data(relative)
	local file = assert(io.open(require("infra.paths").shared(relative), "rb"))
	local bytes = assert(file:read("*a"))
	assert(file:close())
	return assert(require("json").decode(bytes))
end

--- Replaces the native availability probes of the action picker for one callback.
--- Every pick rebuilds the whole catalogue and each build probes the machine
--- (tool lookups, session kind, workspace backend) through spawned shells: with
--- 21 locales and 182 pairs that was thousands of spawns and the run never ended.
--- Availability only greys rows; this test asserts labels, identities and edits.
--- @param callback function Runs with the probes answering without a spawn.
local function with_controlled_probes(callback)
	local targets = {
		{ require("adapters.shell_runner"), "has_command", function() return true end },
		{ require("adapters.window_switch"), "available", function() return true, nil, nil end },
		{ require("modules.gestures.program_owner"), "available", function() return true end },
		{ require("modules.gestures.workspace_switcher"), "detect", function() return {}, nil end },
	}
	local originals = {}
	for index, target in ipairs(targets) do
		originals[index] = target[1][target[2]]
		target[1][target[2]] = target[3]
	end
	local ok, err = pcall(callback)
	for index, target in ipairs(targets) do target[1][target[2]] = originals[index] end
	if not ok then error(err, 0) end
end

--- Keeps real locale, renderer, Pair and catalogue owners across live builds.
--- Only preference persistence, dialog presentation and publication are controlled.
--- @param callback function Receives the actual locale/provider fixture.
local function with_canonical_locale_menu(callback)
	with_menu(function(state)
		local preference = "en"
		package.loaded["adapters.storage"] = {
			get = function(key) return key == "locale" and preference or nil end,
			set = function(key, value)
				assert(key == "locale" and type(value) == "string")
				preference = value
				return true
			end,
		}
		for _, name in ipairs({ "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu" }) do
			package.loaded[name] = nil
		end
		local i18n = require("infra.i18n")
		i18n.init()
		local renderer = require("infra.manifest_menu")
		local provider = require("ui.menu.key_combinations")
		local actions = require("modules.gestures.manager")
		local last_pick
		local context = {
			tap_holds = { key_catalog = function() return state.keys end, hold_options = function() return state.holds end },
			gestures = actions, is_paused = function() return state.paused end,
		}
		local ui = {
			manifest = renderer, get = i18n.get,
			key_label = function(entry) return i18n.get(entry.label_key) end,
			action_label = function(action) return actions.get_action_label(action) end,
			error = function() state.errors = state.errors + 1 end,
			open_hold_picker = function(label, current, items, confirm)
				state.last_hold = { label = label, current = current, items = items, confirm = confirm }
				return true
			end,
			open_picker = function(label, current, binding, confirm)
				last_pick = { label = label, current = current, binding = binding, confirm = confirm }
				return true
			end,
		}
		function state.build(code)
			assert(i18n.set_locale(code) == true)
			assert(i18n.get_locale() == code and require("infra.locale").current_locale() == code)
			return provider.build(context, ui)
		end
		function state.pair_rows(rows)
			local result = {}
			state.walk(rows, function(row)
				if tostring(row.title or ""):find("  :  ", 1, true) then result[#result + 1] = row end
			end)
			return result
		end
		function state.pick(row)
			last_pick = nil
			state.click(assert(row.menu[2]))
			return assert(last_pick)
		end
		state.i18n, state.preference = i18n, function() return preference end
		with_controlled_probes(function() callback(state) end)
	end)
end

--- Checks every label/order against authored IDs and independently read JSON.
--- @param state table Actual fixture.
--- @param rows table Actual provider result.
--- @param strings table Canonical locale source.
--- @return table Actual ordered pair rows.
local function check_locale_matrix(state, rows, strings)
	local actual = state.pair_rows(rows)
	helpers.assert_eq(#actual, 182, "Linux retains all ordered pairs without applying Mac-only pair exclusions")
	helpers.assert_eq(#state.keys, 14)
	for index, id in ipairs(EXPECTED_LINUX_KEYS) do helpers.assert_eq(state.keys[index].id, id, "independent native key order") end
	local cursor = 0
	for _, first in ipairs(EXPECTED_LINUX_KEYS) do
		for _, second in ipairs(EXPECTED_LINUX_KEYS) do
			if first ~= second then
				cursor = cursor + 1
				local first_label, second_label = strings["tap_hold.group." .. first], strings["tap_hold.group." .. second]
				helpers.assert_true(type(first_label) == "string" and first_label ~= "")
				helpers.assert_true(type(second_label) == "string" and second_label ~= "")
				local label = first_label .. " → " .. second_label
				helpers.assert_eq(actual[cursor].title, label .. "  :  " .. strings["tap_hold.tap.none"] .. "  /  " .. strings["tap_hold.hold.none"])
				helpers.assert_true(actual[cursor].menu[2].disabled ~= true, "real source receipt admits the tap picker")
				local picked = state.pick(actual[cursor])
				helpers.assert_eq(picked.label, label)
				helpers.assert_eq(picked.binding, "combination__" .. first .. "_then_" .. second, "native setter identity is locale-independent")
				helpers.assert_eq(picked.current, "none")
			end
		end
	end
	state.walk(rows, function(row)
		local label = row.title
		helpers.assert_true(label ~= strings["menu.tapholds.symmetric"] and label ~= strings["menu.tapholds.copy_tap_to_combo"], "Linux never exposes unavailable simultaneous controls")
	end)
	return actual
end

helpers.describe("actual Linux ordered-pair translations", function()
	helpers.it("renders the independent complete matrix in all 21 canonical locales without reloading owners", function()
		with_canonical_locale_menu(function(state)
			local order = read_locale_data("data/locale_order.json").order
			helpers.assert_eq(#order, 21)
			helpers.assert_eq(state.i18n.list_locales(), order, "real i18n discovers the canonical language set/order")
			for _, code in ipairs(order) do
				local strings = read_locale_data("data/locales/" .. code .. ".json")
				check_locale_matrix(state, state.build(code), strings)
				helpers.assert_eq(state.preference(), code)
			end
			helpers.assert_eq(#state.edits, 0, "enumerating all labels/IDs creates no configuration writes")
			helpers.assert_eq(state.errors, 0)
		end)
	end)
	helpers.it("changes live captions and preserves captured setter receipts across locale switches and back", function()
		with_canonical_locale_menu(function(state)
			local english = read_locale_data("data/locales/en.json")
			local french = read_locale_data("data/locales/fr.json")
			local first = check_locale_matrix(state, state.build("en"), english)
			local saved_label = first[1].title
			local saved_picker = state.pick(first[1])
			local second = check_locale_matrix(state, state.build("fr"), french)
			helpers.assert_true(first[1].title ~= second[1].title, "the same provider reflects a genuine language change")
			helpers.assert_eq(first[1].title, saved_label, "a new menu does not rewrite a prior detached caption")
			helpers.assert_true(saved_picker.confirm("copy") == true)
			helpers.assert_eq(#state.edits, 1)
			helpers.assert_eq(state.edits[1], {{ section = "shortcuts.key_combination_taps", key = "escape_then_tab", value = "copy" }})
			state.click(second[1].menu[3])
			helpers.assert_eq(state.last_hold.confirm("shift"), true)
			helpers.assert_eq(state.edits[2], {{ section = "shortcuts.key_combination_holds", key = "escape_then_tab", value = "shift" }})
			local third = check_locale_matrix(state, state.build("en"), english)
			helpers.assert_eq(third[1].title, saved_label)
			state.source = "[unrelated]\nchanged=true\n"
			helpers.assert_true(saved_picker.confirm("copy") == false, "an unchanged binding cannot bypass source revocation")
			helpers.assert_eq(#state.edits, 2)
		end)
	end)
end)
