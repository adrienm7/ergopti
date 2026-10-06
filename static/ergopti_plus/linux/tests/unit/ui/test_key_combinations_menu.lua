--- tests/unit/ui/test_key_combinations_menu.lua

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
			prompt_hold=function(_,_,choices)
				state.prompts=state.prompts+1;state.choices=choices
				if state.on_prompt then state.on_prompt() end
				return state.selected
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
	helpers.it("opens the real catalogue choices only on click and publishes an exact hold",function()
		with_menu(function(state)
			state.selected=state.translate("tap_hold.hold.shift")
			state.click(state.find("Hold 1 + hold 2 → "))
			helpers.assert_eq(state.prompts,1);helpers.assert_eq(#state.choices,#state.holds)
			helpers.assert_eq(#state.edits,1);helpers.assert_eq(state.edits[1][1].section,Shared.HOLD_SECTION)
			helpers.assert_eq(state.edits[1][1].value,"shift")
		end)
	end)
	for _,mode in ipairs({"cancel","unknown","source","paused"}) do
		helpers.it("refuses "..mode.." without any publication",function()
			with_menu(function(state)
				if mode~="cancel" then state.selected=mode=="unknown" and "unoffered" or state.translate("tap_hold.hold.shift") end
				state.on_prompt=function()
					if mode=="source" then state.source="[unrelated]\nchanged=true\n" end
					if mode=="paused" then state.paused=true end
				end
				state.click(state.find("Hold 1 + hold 2 → "));helpers.assert_eq(#state.edits,0)
			end)
		end)
	end
end)
