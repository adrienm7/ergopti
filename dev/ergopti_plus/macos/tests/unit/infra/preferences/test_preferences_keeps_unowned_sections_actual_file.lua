--- tests/unit/infra/preferences/test_preferences_keeps_unowned_sections_actual_file.lua

--- ==============================================================================
--- MODULE: Preferences Keep Sections They Do Not Own
--- DESCRIPTION:
--- Preferences.save serialised only its own sections and replaced config.toml
--- wholesale, so [_meta] (the schema version the boot migration stamps), the
--- expert [script] and [features] overrides config_overrides reads, and any
--- other top-level table vanished at the first menu change. The next boot then
--- took the file for an unstamped one and migrated it again. These tests pin
--- that a save keeps every top-level table outside the sections it owns, that
--- the sections it owns still come from the state, and that a file it can no
--- longer decode is never replaced by the owned sections alone.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.infra.preferences.preferences_keeps_unowned_sections_fixture"] = nil
local Fixture = require("tests.support.infra.preferences.preferences_keeps_unowned_sections_fixture")
local TomlWriter = Fixture.TomlWriter





helpers.describe("Mac actual file exact integer scalar publication", function()
	helpers.it("writes exact requested integer through root inline with native file and fresh reader", function()
		helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim" }, function()
			local logger=helpers.make_logger_stub()
			package.loaded["infra.logger"],package.loaded["logger.shim"]=logger,logger
			package.loaded["adapters.file_system"]=nil
			local preferences=helpers.load_with_stubs("infra.preferences")
			local path=os.tmpname()
			local file=assert(io.open(path,"wb")); assert(file:write("llm={generation={temperature=9007199254740993,future=[]}} # exact\n")); assert(file:close())
			local called,detail=xpcall(function()
				local _,status=preferences.load(path); helpers.assert_eq(status,"ok")
				helpers.assert_true(preferences.save(path,{llm_temperature=9007199254740992},{},{}))
				local current=assert(io.open(path,"rb")); local bytes=assert(current:read("*a")); assert(current:close())
				helpers.assert_eq(bytes,"llm={generation={temperature=9007199254740992,future=[]}} # exact\n" .. '\n[hotstrings]\nmodules = {  }\n\n[shortcuts]\nkeys = {  }\n')
				package.loaded["infra.preferences"]=nil
				local state,read_status=helpers.load_with_stubs("infra.preferences").load(path)
				helpers.assert_eq(read_status,"ok"); helpers.assert_eq(state.llm_temperature,9007199254740992)
			end,debug.traceback)
			os.remove(path)
			if not called then error(detail,0) end
		end)
	end)
	helpers.it("writes exact requested integer through root dotted with native file and fresh reader", function()
		helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim" }, function()
			local logger=helpers.make_logger_stub()
			package.loaded["infra.logger"],package.loaded["logger.shim"]=logger,logger
			package.loaded["adapters.file_system"]=nil
			local preferences=helpers.load_with_stubs("infra.preferences")
			local path=os.tmpname()
			local file=assert(io.open(path,"wb")); assert(file:write("llm.generation.temperature=9007199254740993 # owned\nfuture=[] # exact\n")); assert(file:close())
			local called,detail=xpcall(function()
				local _,status=preferences.load(path); helpers.assert_eq(status,"ok")
				helpers.assert_true(preferences.save(path,{llm_temperature=9007199254740992},{},{}))
				local current=assert(io.open(path,"rb")); local bytes=assert(current:read("*a")); assert(current:close())
				helpers.assert_eq(bytes,"llm.generation.temperature = 9007199254740992\nfuture=[] # exact\n" .. '\n[hotstrings]\nmodules = {  }\n\n[shortcuts]\nkeys = {  }\n')
				package.loaded["infra.preferences"]=nil
				local state,read_status=helpers.load_with_stubs("infra.preferences").load(path)
				helpers.assert_eq(read_status,"ok"); helpers.assert_eq(state.llm_temperature,9007199254740992)
			end,debug.traceback)
			os.remove(path)
			if not called then error(detail,0) end
		end)
	end)
	helpers.it("writes exact requested integer through section dotted with native file and fresh reader", function()
		helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim" }, function()
			local logger=helpers.make_logger_stub()
			package.loaded["infra.logger"],package.loaded["logger.shim"]=logger,logger
			package.loaded["adapters.file_system"]=nil
			local preferences=helpers.load_with_stubs("infra.preferences")
			local path=os.tmpname()
			local file=assert(io.open(path,"wb")); assert(file:write("[llm]\ngeneration.temperature=9007199254740993 # owned\nfuture=[] # exact\n")); assert(file:close())
			local called,detail=xpcall(function()
				local _,status=preferences.load(path); helpers.assert_eq(status,"ok")
				helpers.assert_true(preferences.save(path,{llm_temperature=9007199254740992},{},{}))
				local current=assert(io.open(path,"rb")); local bytes=assert(current:read("*a")); assert(current:close())
				helpers.assert_eq(bytes,"[llm]\ngeneration.temperature = 9007199254740992\nfuture=[] # exact\n" .. '\n[hotstrings]\nmodules = {  }\n\n[shortcuts]\nkeys = {  }\n')
				package.loaded["infra.preferences"]=nil
				local state,read_status=helpers.load_with_stubs("infra.preferences").load(path)
				helpers.assert_eq(read_status,"ok"); helpers.assert_eq(state.llm_temperature,9007199254740992)
			end,debug.traceback)
			os.remove(path)
			if not called then error(detail,0) end
		end)
	end)
	helpers.it("writes exact requested integer through header leaf with native file and fresh reader", function()
		helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim" }, function()
			local logger=helpers.make_logger_stub()
			package.loaded["infra.logger"],package.loaded["logger.shim"]=logger,logger
			package.loaded["adapters.file_system"]=nil
			local preferences=helpers.load_with_stubs("infra.preferences")
			local path=os.tmpname()
			local file=assert(io.open(path,"wb")); assert(file:write("[llm.generation]\ntemperature=9007199254740993 # owned\nfuture=[] # exact\n")); assert(file:close())
			local called,detail=xpcall(function()
				local _,status=preferences.load(path); helpers.assert_eq(status,"ok")
				helpers.assert_true(preferences.save(path,{llm_temperature=9007199254740992},{},{}))
				local current=assert(io.open(path,"rb")); local bytes=assert(current:read("*a")); assert(current:close())
				helpers.assert_eq(bytes,"[llm.generation]\ntemperature = 9007199254740992\nfuture=[] # exact\n" .. '\n[hotstrings]\nmodules = {  }\n\n[shortcuts]\nkeys = {  }\n')
				package.loaded["infra.preferences"]=nil
				local state,read_status=helpers.load_with_stubs("infra.preferences").load(path)
				helpers.assert_eq(read_status,"ok"); helpers.assert_eq(state.llm_temperature,9007199254740992)
			end,debug.traceback)
			os.remove(path)
			if not called then error(detail,0) end
		end)
	end)
	helpers.it("writes exact requested integer through section inline with native file and fresh reader", function()
		helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim" }, function()
			local logger=helpers.make_logger_stub()
			package.loaded["infra.logger"],package.loaded["logger.shim"]=logger,logger
			package.loaded["adapters.file_system"]=nil
			local preferences=helpers.load_with_stubs("infra.preferences")
			local path=os.tmpname()
			local file=assert(io.open(path,"wb")); assert(file:write("[llm]\ngeneration={temperature=9007199254740993,future=[]} # exact\n")); assert(file:close())
			local called,detail=xpcall(function()
				local _,status=preferences.load(path); helpers.assert_eq(status,"ok")
				helpers.assert_true(preferences.save(path,{llm_temperature=9007199254740992},{},{}))
				local current=assert(io.open(path,"rb")); local bytes=assert(current:read("*a")); assert(current:close())
				helpers.assert_eq(bytes,"[llm]\ngeneration={temperature=9007199254740992,future=[]} # exact\n" .. '\n[hotstrings]\nmodules = {  }\n\n[shortcuts]\nkeys = {  }\n')
				package.loaded["infra.preferences"]=nil
				local state,read_status=helpers.load_with_stubs("infra.preferences").load(path)
				helpers.assert_eq(read_status,"ok"); helpers.assert_eq(state.llm_temperature,9007199254740992)
			end,debug.traceback)
			os.remove(path)
			if not called then error(detail,0) end
		end)
	end)
end)

helpers.describe("Mac actual file authenticated integer candidate proof", function()
	helpers.it("refuses a wrong genuine prepared scalar then reloads repaired bytes through native Preferences", function()
		helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim" },function()
			local logger=helpers.make_logger_stub()
			package.loaded["infra.logger"],package.loaded["logger.shim"]=logger,logger
			package.loaded["adapters.file_system"]=nil
			local file_owner=require("adapters.file_system")
			local LeafRows=require("toml_codec.leaf_rows")
			local source='[llm.generation]\ntemperature=0\nfuture=9223372036854775807 # exact\n'
			local path=os.tmpname()
			local file=assert(io.open(path,"wb")); assert(file:write(source)); assert(file:close())
			local function bytes()
				local current=assert(io.open(path,"rb"));local content=assert(current:read("*a"));assert(current:close());return content
			end
			local okay,detail=xpcall(function()
				local original=LeafRows.value_literal
				local capability
				LeafRows.value_literal=function(value) if value==9007199254740992 then return "9007199254740993" end return original(value) end
				local called,accepted=pcall(function()
					local rows=LeafRows.prepare(source,{ {path={"llm","generation","temperature"},value=9007199254740992} })
					capability=LeafRows.publication_capability(rows[1])
					return TomlWriter.batch_write(path,rows,file_owner)
				end)
				LeafRows.value_literal=original
				helpers.assert_eq(called,true,accepted)
				helpers.assert_true(capability~=nil)
				helpers.assert_eq(accepted,false)
				helpers.assert_eq(bytes(),source)
				local rows=LeafRows.prepare(source,{ {path={"llm","generation","temperature"},value=9007199254740992} })
				helpers.assert_true(TomlWriter.batch_write(path,rows,file_owner))
				helpers.assert_eq(bytes(),'[llm.generation]\ntemperature = 9007199254740992\nfuture=9223372036854775807 # exact\n')
				package.loaded["infra.preferences"]=nil
				local state,status=helpers.load_with_stubs("infra.preferences").load(path)
				helpers.assert_eq(status,"ok");helpers.assert_eq(state.llm_temperature,9007199254740992)
			end,debug.traceback)
			os.remove(path)
			if not okay then error(detail,0) end
		end)
	end)
end)

helpers.describe("Mac native absent inline scalar preference",function()
	local vectors={
		{source='llm={generation={top_p=0.75,future=[]}} # keep\n',expected='llm={generation={top_p=0.75,future=[],temperature = 0.25}} # keep\n'},
		{source='[llm]\ngeneration={top_p=0.75,future=[]} # keep\n',expected='[llm]\ngeneration={top_p=0.75,future=[],temperature = 0.25} # keep\n'},
	}
	for index,vector in ipairs(vectors) do
		helpers.it("inserts absent known scalar with native file and fresh Preferences reader "..index,function()
			helpers.with_stub_scope({"infra.preferences","adapters.file_system","infra.logger","logger.shim"},function()
				local logger=helpers.make_logger_stub()
				package.loaded["infra.logger"],package.loaded["logger.shim"]=logger,logger
				package.loaded["adapters.file_system"]=nil
				local preferences=helpers.load_with_stubs("infra.preferences")
				local path=os.tmpname();local file=assert(io.open(path,"wb"));assert(file:write(vector.source));assert(file:close())
				local okay,detail=xpcall(function()
					local _,status=preferences.load(path);helpers.assert_eq(status,"ok")
					helpers.assert_true(preferences.save(path,{llm_temperature=0.25},{},{}))
					local current=assert(io.open(path,"rb"));local bytes=assert(current:read("*a"));assert(current:close())
					helpers.assert_eq(bytes,vector.expected..'\n[hotstrings]\nmodules = {  }\n\n[shortcuts]\nkeys = {  }\n')
					package.loaded["infra.preferences"]=nil
					local state,fresh_status=helpers.load_with_stubs("infra.preferences").load(path)
					helpers.assert_eq(fresh_status,"ok");helpers.assert_eq(state.llm_temperature,0.25)
				end,debug.traceback)
				os.remove(path);if not okay then error(detail,0) end
			end)
		end)
	end
end)
