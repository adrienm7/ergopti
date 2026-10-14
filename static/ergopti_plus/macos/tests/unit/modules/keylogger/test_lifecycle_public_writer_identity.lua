--- tests/unit/modules/keylogger/test_lifecycle_public_writer_identity.lua

--- Confirms that observed public writers retain their real native handler/delegate.
local helpers=require("tests.helpers")
local Fixture=require("tests.support.keylogger_provenance_fixture")
local OWNERS = {
	"keylogger.physical_lifecycle_observation", "adapters.physical_observation_clock", "hs", "tests.stubs.hs", "infra.logger", "infra.manifest_reader", "infra.config_paths",
	"infra.dialog_util", "infra.teardown_transaction", "modules.keylogger.init",
	"modules.keylogger.log_manager", "modules.keylogger.context_tracker",
	"modules.keylogger.kc_bridge", "modules.keylogger.watchers", "modules.keylogger.timestamp",
	"modules.keylogger.physical_accounting_mode", "adapters.synthetic_input", "adapters.event_provenance", "adapters.process_lifecycle",
	"adapters.keyboard_hook", "adapters.input_source_broker", "adapters.storage",
	"adapters.timer_scheduler", "modules.keylogger.aggregator.events",
	"modules.keylogger.aggregator.state", "modules.keylogger.aggregator.core",
	"modules.keylogger.aggregator.physical", "ui.metrics_typing.init",
}
local function upvalue(fn,wanted)
	for index=1,200 do
		local name,value=debug.getupvalue(fn,index)
		if name==nil then break end
		if name==wanted then return value end
	end
end
local function with_fixture(callback)
	return helpers.with_stub_scope(OWNERS,function()
		local fixture = Fixture.load_keylogger()
		-- The generic HS stub has no caffeinate constructor; model its documented
		-- exact object result without changing the existing provenance fixture.
		fixture.hs.caffeinate = { watcher = { new = function(callback)
			local watcher = { callback = callback }
			function watcher:start() return self end
			function watcher:stop() return self end
			return watcher
		end } }
		return callback(fixture)
	end)
end
helpers.describe("Observed public keylogger writers keep their native identity",function()
	helpers.it("public start exposes the exact handler installed in the native hook",function()
		with_fixture(function(fixture)
			local handler=upvalue(fixture.keylogger.start,"handle_key")
			helpers.assert_eq(type(handler),"function")
			local installed,calls=nil,0
			package.loaded["adapters.keyboard_hook"].start=function(options) installed=options.onEvent;calls=calls+1;return true end
			fixture.start({is_paused=function() return false end})
			helpers.assert_eq(calls,1)
			helpers.assert_true(rawequal(handler,installed),"The public upvalue must be the actual installed production handler")
			helpers.assert_true(rawequal(upvalue(handler,"CoreState"),fixture.state))
			fixture.keylogger.stop()
		end)
	end)
	helpers.it("bound start denies before actual native hook construction",function()
		with_fixture(function(fixture)
			local clock,records=0,{}
			fixture.hs.timer.absoluteTime=function() clock=clock+1;return clock end
			helpers.assert_true(fixture.keylogger.bind_physical_lifecycle_observer({},100,function(record) records[#records+1]=record;return true end)~=nil)
			local calls=0
			package.loaded["adapters.keyboard_hook"].start=function(options)
				calls=calls+1
				helpers.assert_eq(records[#records].source,"start")
				helpers.assert_eq(records[#records].stage,"boundary")
				helpers.assert_eq(records[#records].allowed,false)
				helpers.assert_eq(type(options.onEvent),"function")
				return true
			end
			fixture.start({is_paused=function() return false end})
			helpers.assert_eq(calls,1)
			helpers.assert_eq(records[#records].complete,true)
			helpers.assert_eq(records[#records].allowed,false)
			fixture.keylogger.stop()
		end)
	end)
	helpers.it("observed resync retains one real delegated call and exact result semantics",function()
		with_fixture(function(fixture)
			fixture.start({is_paused=function() return false end})
			local clock,records=0,{}
			fixture.hs.timer.absoluteTime=function() clock=clock+1;return clock end
			helpers.assert_true(fixture.keylogger.bind_physical_lifecycle_observer({},100,function(record) records[#records+1]=record;return true end)~=nil)
			local calls=0
			for _,mode in ipairs({"true","false","nil","truthy","throw"}) do
				package.loaded["modules.keylogger.context_tracker"].resync_context=function()
					calls=calls+1
					helpers.assert_eq(records[#records].source,"resync")
					helpers.assert_eq(records[#records].stage,"boundary")
					if mode=="throw" then error("delegated resync failure") end
					if mode=="true" then return true end
					if mode=="false" then return false end
					if mode=="truthy" then return 1 end
				end
				local prior=calls
				helpers.assert_eq(fixture.keylogger.resync_context(),mode=="true")
				helpers.assert_eq(calls,prior+1,"Instrumentation cannot add a second native resync query")
			end
			fixture.keylogger.stop()
		end)
	end)
end)
