--- tests/unit/ui/menu/test_runtime_preference_recovery.lua

--- ==============================================================================
--- MODULE: Native Menu Runtime Preference Recovery
--- DESCRIPTION:
--- Executes actual ui.menu.start with original native recovery/configuration and
--- terminal/global transaction constructors over disposable host ports. Display
--- and unrelated feature owners are explicit doubles. This proves local command
--- behavior, not a Hammerspoon boot, installed macOS reload or physical retirement.
--- ==============================================================================

local helpers = require("tests.helpers")
local recovery_fixture = require("tests.support.runtime_recovery_fixture")
local menu_fixture = require("tests.support.runtime_recovery_menu_fixture")
local with_source = recovery_fixture.with_source
local OWNED = '[karabiner]\nruntime = "owned"\nintegration_enabled = true\n[future]\nrevision = 29\n'

local function assert_not_contains(value, needle)
	helpers.assert_type(value, "string")
	helpers.assert_type(needle, "string")
	helpers.assert_eq(value:find(needle, 1, true), nil, "unexpected fixed substring: " .. needle)
end

local function no_shared_effects(calls)
	for _, name in ipairs({ "lease_init", "expand", "start", "start_paused", "build", "deploy",
		"execute", "save", "lease_bound_starts", "input_source_watchers", "wizard_runs", "scope_imports" }) do
		helpers.assert_eq(calls[name], 0, name .. " must remain unacquired")
	end
	helpers.assert_eq(#calls.rule_removals, 0)
	helpers.assert_eq(#calls.legacy_removals, 0)
	helpers.assert_eq(#calls.first_run_timers, 0)
end

local function load_coordinator(options)
	options = options or {}
	local calls = {
		order = {},
		lease_requests = 0,
		input_drains = 0,
		teardowns = 0,
		drains = 0,
		finalizers = 0,
		reloads = 0,
		exits = 0,
		fatal_exits = 0,
		marks = 0,
		clears = 0,
		logger_calls = 0,
	}
	local function append(value) calls.order[#calls.order + 1] = value end
	local function observe_log() calls.logger_calls = calls.logger_calls + 1 end
	local function observe_info(...)
		observe_log(...)
		if options.logger_info_raises then error("synthetic post-fence logger failure") end
	end
	package.loaded["infra.logger"] = {
		start = observe_log, debug = observe_log, info = observe_info, warn = observe_log,
		error = observe_log, success = observe_log, done = observe_log,
	}
	package.loaded["infra.termination_coordinator"] = nil
	local coordinator = require("infra.termination_coordinator")
	helpers.assert_true(coordinator.is_initialized() == false)
	local initialized = coordinator.init({
		capture_publication_admission = options.capture_publication_admission,
		request_lease = function(reason, callback)
			calls.lease_requests = calls.lease_requests + 1
			calls.reason = reason
			calls.lease_callback = callback
			append("request-lease")
			if options.request_raises then error("synthetic lease request failure") end
			if options.synchronous_result ~= nil then
				callback(options.synchronous_result, "synchronous")
			end
			if options.request_raises_after_callback then
				error("synthetic lease request failure after callback")
			end
			return options.request_accepted ~= false
		end,
		drain_input = function(callback)
			calls.input_drains = calls.input_drains + 1
			calls.input_drain_callback = callback
			append("drain-input")
			if options.input_drain_raises then
				error("synthetic input drain acquisition failure")
			end
			if options.input_drain_deferred ~= true then callback() end
			return options.input_drain_accepted ~= false
		end,
		teardown = function(kind, on_ready)
			calls.teardowns = calls.teardowns + 1
			calls.teardown_kind = kind
			append("teardown-" .. kind)
			if options.teardown_synchronous_ready ~= nil and not calls.teardown_released then
				calls.teardown_released = true
				on_ready(options.teardown_synchronous_ready, "synchronous teardown boundary")
				if options.teardown_raises_after_callback then
					error("synthetic teardown failure after callback")
				end
				return options.teardown_return_after_callback ~= false
			end
			if options.teardown_deferred and not calls.teardown_released then
				calls.teardown_callback = on_ready
				return true, "pending"
			end
			if options.partial_teardown then
				calls.first_owner_stopped = true
				append("first-owner-stopped")
			end
			if options.teardown_raises then error("synthetic teardown failure") end
			return options.teardown_result ~= false
		end,
		begin_drain = function(callback)
			calls.drains = calls.drains + 1
			calls.drain_callback = callback
			append("begin-drain")
			if options.drain_raises then error("synthetic drain begin failure") end
			if options.drain_deferred ~= true then
				callback(options.drain_result ~= false, options.drain_detail or "drained")
			end
			return options.drain_accepted ~= false
		end,
		finalize_teardown = function()
			calls.finalizers = calls.finalizers + 1
			append("finalize-teardown")
			if options.finalize_raises then error("synthetic finalizer failure") end
			return options.finalize_result ~= false
		end,
		reload = function(...)
			calls.reloads = calls.reloads + 1
			calls.reload_arguments = table.pack(...)
			append("reload")
			if options.reload_raises then error("synthetic reload failure") end
			return true
		end,
		exit = function(code)
			calls.exits = calls.exits + 1
			calls.exit_code = code
			append("exit")
			if options.exit_raises then error("synthetic exit failure") end
			return true
		end,
		fatal_exit = function(code)
			calls.fatal_exits = calls.fatal_exits + 1
			calls.fatal_exit_code = code
			append("fatal-exit")
			if options.fatal_exit_raises then error("synthetic fatal exit failure") end
			return true
		end,
		fatal_exit_code = 70,
		schedule = function(delay, callback)
			calls.watchdog_delay = delay
			calls.watchdog_callback = callback
			append("arm-watchdog")
			return { stop = function() calls.watchdog_stopped = true; return true end }
		end,
		user_exit_deadline_seconds = 12,
		mark_reload = function()
			calls.marks = calls.marks + 1
			append("mark-reload")
			if options.mark_raises then error("synthetic mark failure") end
			return options.mark_result ~= false
		end,
		clear_reload = function()
			calls.clears = calls.clears + 1
			append("clear-reload")
			return true
		end,
	})
	helpers.assert_true(initialized)
	helpers.assert_true(coordinator.is_initialized())
	return coordinator, calls
end


-- This test host acknowledges only the genuine controller's absent generation;
-- it does not fabricate a successful STOPPED protocol reply or boot the root.
local function no_generation_request(lease)
 -- Receive the actual root fence adapter; uninitialized owners are acknowledged
 -- before diagnostic status, as in the pinned native implementation.
 local root_path=assert(package.searchpath("init",package.path))
 local stream=assert(io.open(root_path,"rb"))
 local source=assert(stream:read("*a"));assert(stream:close())
 local first=assert(source:find("local function invoke_lifecycle_callback",1,true))
 local last=assert(source:find("-- The once-only quit step",first,true))
 local native=source:sub(first,last-1)
 local receive=assert(load("return function(Logger,LOG,LeaseController,karabiner)\n"..native
  .."\nreturn request_exact_lease_revoke end","@"..root_path))()
 return receive(require("infra.logger"),"root",lease,require("platform.remap"))
end

-- Observe the actual menu-created owner; this introspection never injects an
-- external writer or modifies its token/retention state.
local function retained_owner(fn, seen)
	seen = seen or {}
	if seen[fn] then return nil end
	seen[fn] = true
	for index = 1, 100 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == "global_actions_owner" then return value end
		if type(value) == "function" then
			local found = retained_owner(value, seen)
			if found then return found end
		end
	end
	return nil
end

local function with_recovery(options, body)
	options = options or {}
	helpers.with_stub_scope({ "infra.termination_coordinator", "ui.menu.global_actions_transaction", "infra.logger",
		"ui.menu.init", "ui.menu.builder", "ui.menu.menu_paths" }, function()
		with_source(OWNED, function(remap, calls, lease, read, _initialized, path)
			local terminal, effects = load_coordinator(options)
			if not options.port_failure then
				local native = no_generation_request(lease)
				for index = 1, 30 do
					local name, request = debug.getupvalue(terminal.request_reload_owned, index)
					if name == "request" then
						for inner = 1, 30 do
							local field, deps = debug.getupvalue(request, inner)
							if field == "_deps" then deps.request_lease = native end
						end
					end
				end
			end
			local cleanup = options.before_menu and options.before_menu(remap, terminal)
			local current_path = path
			local boot = menu_fixture.boot({ karabiner = remap, terminal = terminal,
				runtime_path = function() return current_path end })
			boot.menu_provider()
			local ctx = boot.ctx
			helpers.assert_type(ctx, "table")
			helpers.assert_type(ctx.recover_shared_runtime, "function")
			local global = retained_owner(ctx.recover_shared_runtime)
			helpers.assert_type(global, "table")
			local function write(bytes)
				local stream = assert(io.open(path, "wb"))
				assert(stream:write(bytes))
				assert(stream:close())
			end
			local body_ok, body_error = pcall(body, { ctx = ctx, remap = remap, calls = calls, lease = lease, terminal = terminal,
				effects = effects, global = global, path = path, read = read, write = write,
				paths = package.loaded["ui.menu.menu_paths"], set_path = function(value) current_path = value end })
			if cleanup then cleanup() end
			if not body_ok then error(body_error, 0) end
		end)
	end)
end

local function displayed(f)
 helpers.assert_eq(type(f.ctx.can_recover_shared_runtime),"function")
 helpers.assert_eq(type(f.ctx.recover_shared_runtime),"function")
 helpers.assert_eq(f.ctx.can_recover_shared_runtime(),true)
end
helpers.describe("Native menu runtime preference recovery",function()
 helpers.it("paint captures bytes without acquisition, publication or terminal requests",function()
  with_recovery({},function(f)
   displayed(f);helpers.assert_eq(f.read(),OWNED);no_shared_effects(f.calls)
   helpers.assert_eq(f.effects.lease_requests,0);helpers.assert_eq(f.global.is_pending(),false)
  end)
 end)
 helpers.it("synchronous accepted reload preserves live owned intent and retains writer despite wrapper false",function()
  with_recovery({},function(f)
   displayed(f);helpers.assert_eq(f.ctx.recover_shared_runtime(),true)
   helpers.assert_eq(f.remap.get_runtime(),"owned");helpers.assert_eq(f.remap.get_enabled(),true)
   helpers.assert_eq(f.effects.reloads,1);assert_not_contains(f.read(),'runtime = "owned"')
   helpers.assert_contains(f.read(),'revision = 29');helpers.assert_contains(f.read(),'integration_enabled = true')
   helpers.assert_eq(f.global.is_pending(),true)
   local other=0;helpers.assert_eq(f.global.run_exclusive("other",function()other=other+1;return true end),false)
   helpers.assert_eq(other,0)
  end)
 end)
 helpers.it("asynchronous accepted request keeps exact inverse and never claims reload completion",function()
  with_recovery({input_drain_deferred=true},function(f)
   displayed(f);helpers.assert_eq(f.ctx.recover_shared_runtime(),true)
   helpers.assert_eq(f.effects.reloads,0);helpers.assert_eq(f.terminal.is_pending(),true)
   helpers.assert_eq(f.global.is_pending(),true)
   local candidate=f.read();helpers.assert_eq(f.ctx.recover_shared_runtime(),false);helpers.assert_eq(f.read(),candidate)
  end)
 end)
 helpers.it("exact pre-fence abort restores original bytes through genuine native inverse",function()
  with_recovery({port_failure=true,synchronous_result=false},function(f)
   displayed(f);helpers.assert_eq(f.ctx.recover_shared_runtime(),false)
   helpers.assert_eq(f.read(),OWNED);helpers.assert_eq(f.global.is_pending(),false)
   helpers.assert_eq(f.effects.reloads,0)
  end)
 end)
 helpers.it("refusal before any terminal transaction restores only the owned candidate",function()
  with_recovery({capture_publication_admission=function()return nil end},function(f)
   displayed(f);helpers.assert_eq(f.ctx.recover_shared_runtime(),false)
   helpers.assert_eq(f.read(),OWNED);helpers.assert_eq(f.global.is_pending(),false)
  end)
 end)
 helpers.it("changed displayed source is preserved and never triggers a reload",function()
  with_recovery({},function(f)
   displayed(f);local successor=OWNED.."\n# successor\n";f.write(successor)
   helpers.assert_eq(f.ctx.recover_shared_runtime(),false)
   helpers.assert_eq(f.read(),successor);helpers.assert_eq(f.effects.reloads,0)
  end)
 end)
 for _,port in ipairs({{"remap","stop_lease"},{"remap","teardown_local"},{"remap","runtime_recovery_admission"},{"terminal","request_reload_owned"},{"global","run_exclusive"}})do
  helpers.it("late native port replacement refuses before foreign calls: "..port[2],function()
   with_recovery({},function(f)
    displayed(f);local owner=f[port[1]];local original,counter=owner[port[2]],0
    owner[port[2]]=function()counter=counter+1;return true end
    helpers.assert_eq(f.ctx.recover_shared_runtime(),false);helpers.assert_eq(counter,0);helpers.assert_eq(f.read(),OWNED)
    owner[port[2]]=original
   end)
  end)
 end
 helpers.it("changed native route refuses without writing either route",function()
  with_recovery({},function(f)
   displayed(f);f.set_path(f.path..".foreign")
   helpers.assert_eq(f.ctx.recover_shared_runtime(),false);helpers.assert_eq(f.read(),OWNED)
   helpers.assert_eq(io.open(f.path..".foreign","rb"),nil)
  end)
 end)
 helpers.it("abort with a successor inode retains debt; same command retries inverse without republishing",function()
  with_recovery({port_failure=true},function(f)
   displayed(f);helpers.assert_eq(f.ctx.recover_shared_runtime(),true)
   local published=f.read();local displaced=f.path..".candidate"
   assert(os.rename(f.path,displaced));f.write(published)
   f.effects.lease_callback(false,"test-exact-fence-refused")
   helpers.assert_eq(f.read(),published);helpers.assert_eq(f.global.is_pending(),true)
   helpers.assert_eq(f.ctx.can_recover_shared_runtime(),true)
   helpers.assert_eq(f.ctx.recover_shared_runtime(),false)
   helpers.assert_eq(f.read(),published)
   assert(os.remove(f.path));assert(os.rename(displaced,f.path))
   helpers.assert_eq(f.ctx.recover_shared_runtime(),true)
   helpers.assert_eq(f.read(),OWNED);helpers.assert_eq(f.global.is_pending(),false)
   helpers.assert_eq(f.effects.lease_requests,1);helpers.assert_eq(f.effects.reloads,0)
  end)
 end)
end)


helpers.describe("Original native menu recovery role custody", function()
	for _, role in ipairs({ "config", "remap", "terminal" }) do
		helpers.it("preconstruction same-file " .. role .. " alias is never invoked", function()
			local entries = 0
			with_recovery({ before_menu = function(remap, terminal)
				local owner, key, alias
				if role == "config" then
					owner, key = require("platform.remap.config"), "save_runtime"
					alias = owner.load_user_config
				elseif role == "remap" then
					owner, key, alias = remap, "stop_lease", remap.teardown_local
				else
					owner, key, alias = terminal, "request_reload_owned", terminal.request_reload
				end
				local original = owner[key]
				owner[key] = alias
				debug.sethook(function(event)
					if event == "call" and debug.getinfo(2, "f").func == alias then entries = entries + 1 end
				end, "c")
				return function() debug.sethook(); owner[key] = original end
			end }, function(f)
				helpers.assert_eq(f.ctx.can_recover_shared_runtime(), false)
				helpers.assert_eq(f.ctx.recover_shared_runtime(), false)
				helpers.assert_eq(entries, 0)
				helpers.assert_eq(f.effects.lease_requests, 0)
				helpers.assert_eq(f.global.is_pending(), false)
				helpers.assert_eq(f.read(), OWNED)
			end)
		end)
	end

	helpers.it("new recovery follows original retained-token settlement after async successful inverse", function()
		with_recovery({ port_failure = true }, function(f)
			displayed(f)
			helpers.assert_eq(f.ctx.recover_shared_runtime(), true)
			helpers.assert_eq(f.effects.lease_requests, 1)
			f.effects.lease_callback(false, "test-exact-fence-refused")
			helpers.assert_eq(f.read(), OWNED)
			helpers.assert_eq(f.terminal.is_pending(), false)
			helpers.assert_eq(f.global.is_pending(), true)
			displayed(f)
			helpers.assert_eq(f.ctx.recover_shared_runtime(), true)
			helpers.assert_eq(f.effects.lease_requests, 2)
			helpers.assert_eq(f.global.is_pending(), true)
			assert_not_contains(f.read(), 'runtime = "owned"')
		end)
	end)
end)
