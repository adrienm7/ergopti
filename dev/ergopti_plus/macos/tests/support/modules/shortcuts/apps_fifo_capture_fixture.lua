--- tests/support/modules/shortcuts/apps_fifo_capture_fixture.lua
--- Drives actual Apps, SyntheticInput and TimerScheduler with an explicit native event port.
local helpers = require("tests.helpers")
local Fixture = require("tests.support.synthetic_input_fixture")
require("infra.logger")
local M = {}
local OWNED = {
	"modules.shortcuts.actions.apps", "adapters.synthetic_input", "adapters.event_provenance",
	"adapters.timer_scheduler", "adapters.storage", "infra.logger", "logger.shim", "tests.stubs.hs", "hs",
	"adapters.window_info", "adapters.window_manager", "adapters.app_launcher", "adapters.shell_runner",
	"infra.notifications", "infra.i18n", "infra.text_utils",
	"text_utils", "compat.utf8",
}
function M.with_world(options, callback)
	return helpers.with_stub_scope(OWNED, function()
		local f = Fixture.make({ absolute_time = 0, epoch = 1900000000 })
		local syn = f.load()
		local backlog = options.backlog == true
		local original = { ['public.utf8-plain-text'] = 'ORIGINAL', ['public.html'] = '<b>ORIGINAL</b>' }
		local board = original
		local events, reads = {}, 0
		local copies, restores, urls = 0, 0, {}
		local refusal_count = options.restore_refusals or 0
		local now = 0
		local function observe(event)
			local mods = table.concat(event.modifiers or {}, '+')
			if event.isDown and event.key == 'c' and (mods == 'cmd' or mods == 'cmd+alt') then
				copies = copies + 1
				if mods == 'cmd' or not options.no_finder_path then
					board = { ['public.utf8-plain-text'] = mods == 'cmd' and 'SELECTED WORDS' or '/Users/user/Documents/report.txt' }
				end
				events[#events+1] = {kind='copy', at=now}
			end
		end
		f.key_observer = observe
		hs.pasteboard = {
			readAllData = function() return board end,
			clearContents = function() board = {} end,
			getContents = function() reads = reads + 1; return board['public.utf8-plain-text'] end,
			writeAllData = function(saved)
				restores = restores + 1
				if restores <= refusal_count then return false end
				board = saved; events[#events+1] = {kind='restore', at=now}; return true
			end,
		}
		hs.urlevent = { openURL = function(value) urls[#urls+1]=value; return true end }
		hs.http = { encodeForQuery = function(value) return value end }
		package.loaded['adapters.window_info'] = { getFocused = function() return {appId=options.finder and 'Finder' or 'TextEdit'} end }
		package.loaded['adapters.window_manager'] = {}
		package.loaded['adapters.app_launcher'] = {}
		package.loaded['adapters.shell_runner'] = {}
		package.loaded['infra.notifications'] = { notify=function() end }
		package.loaded['infra.i18n'] = {get=function(key) return key end}
		local apps = require('modules.shortcuts.actions.apps')
		local head_completed = not backlog
		if backlog then
			local pairs = options.pairs or 20
			f.callback_active = true; syn.enter_callback()
			local tx=syn.begin('probe.actual.paced','replacement')
			syn.with_transaction(tx,function()
				for _=1,pairs do assert(syn.emit_key_stroke({},'delete',0)) end
				assert(syn.emit_key_strokes('X'))
			end)
			syn.on_complete(tx,function(_,status) head_completed=true; events[#events+1] = {kind='head_terminal', at=now, status=status} end)
			local target = { pid = function() return 222 end, isRunning = function() return true end }
			f.live_applications = { [222] = target }
			local owner=assert(syn.prepare_collected_paced(tx,pairs,20000,target))
			assert(syn.seal(tx)); assert(syn.authorize_collected_paced(owner)); assert(syn.commit_collected_paced(owner))
			syn.leave_callback(true); f.callback_active=false
		end

		local applied=0
		local function advance(until_time)
			for turn=1,1000 do
				local index,deadline
				for i,timer in ipairs(f.timers) do
					if not timer.stopped then
						timer.due=timer.due or (now+timer.delay)
						if not deadline or timer.due<deadline then index,deadline=i,timer.due end
					end
				end
				if not index or deadline>until_time then break end
				local timer=table.remove(f.timers,index)
				now=deadline; f.options.absolute_time=math.floor(now*1e9);f.options.epoch=1900000000+now
				timer.callback()
				if timer.recurring and not timer.stopped then timer.due=now+timer.delay;f.timers[#f.timers+1]=timer end
				while applied<#f.pump_deliveries do
					applied=applied+1
					for _,event in ipairs(f.pump_deliveries[applied].events or {}) do observe(event) end
				end
			end

		end
		local world = { apps=apps, synthetic=syn, original=original, events=events, fixture=f,
			advance=advance, clipboard=function() return board end,
			counts=function() return copies, restores, #urls, reads end }
		local outcome=table.pack(xpcall(function() return callback(world) end, debug.traceback))
		apps.stop_apps_actions()
		advance(2)
		assert(apps.stop_apps_actions() == true and apps.has_pending_apps_action() == false, "Apps debt remains")
		assert(syn.stats().pending==0 and syn.stats().active_transactions==0, "synthetic debt remains")
		if not outcome[1] then error(outcome[2],0) end
		return table.unpack(outcome,2,outcome.n)
	end)
end
return M
