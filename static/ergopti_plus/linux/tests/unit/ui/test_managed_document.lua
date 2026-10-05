--- static/ergopti_plus/linux/tests/unit/ui/test_managed_document.lua

--- Actual Linux manager/Versions caller over controlled native hooks.
--- No real LGI, WebKit, Crypto, desktop notification or timer ACK qualification.
local helpers=require("tests.helpers")
local function run(body)
	local previous=package.loaded["ui.changelog.bridge"]
	package.loaded["ui.changelog.bridge"]=nil
	local Bridge=require("ui.changelog.bridge")
	local calls,pushes={},{}
	Bridge._http_get=function(_,_,_,callback)calls[#calls+1]=callback end
	Bridge._push=function(payload)pushes[#pushes+1]=payload;return true end
	local native=require("tests.support.document_fixture").new("changelog",Bridge,{})
	local ok,err=pcall(body,native,Bridge,calls,pushes)
	native.close();package.loaded["ui.changelog.bridge"]=previous
	if not ok then error(err) end
end
helpers.describe("actual managed document causal seams",function()
	helpers.it("reads the native boolean loading property through genuine initialization", function()
		run(function(c, _, calls)
			helpers.assert_type(c.view().is_loading, "boolean")
			local view = c.start_load()
			helpers.assert_eq(view.is_loading, true)
			c.finish_load(view)
			helpers.assert_eq(view.is_loading, false)
			c.ack(view)
			c.timers[#c.timers]:ack_close()
			c.send("ready", view)
			helpers.assert_eq(#calls, 1)
			helpers.assert_type(c.manager.capture_document_owner("changelog"), "table")
		end)
	end)
	helpers.it("refuses an unknown native loading property without reading a page nonce", function()
		run(function(c, _, calls)
			local view = c.start_load()
			view.loading = nil
			view.on_load_changed(view, "FINISHED")
			helpers.assert_eq(#view.results, 0)
			helpers.assert_eq(#calls, 0)
			helpers.assert_nil(c.manager.capture_document_owner("changelog"))
		end)
	end)
	helpers.it("a native loading-property reentry cannot publish into a successor", function()
		run(function(c, _, calls, pushes)
			c.handshake()
			c.on_loading = function()
				c.on_loading = nil
				c.start_load()
			end
			calls[1](200, "[]", nil)
			helpers.assert_eq(#pushes, 0)
		end)
	end)
	helpers.it("real manager refuses raw messages before genuine challenge roundtrip",function()
		run(function(c,_,calls)
			helpers.assert_eq(c.manager.route_message("changelog","changelog_bridge","ready",c.manager.current_epoch("changelog")),nil)
			helpers.assert_eq(#calls,0);c.handshake();helpers.assert_eq(#calls,1)
		end)
	end)
	helpers.it("release completion after same-URI STARTED before successor ready cannot publish",function()
		run(function(c,_,calls,pushes)
			c.handshake();c.start_load();calls[1](200,"[]",nil)
			helpers.assert_eq(#pushes,0)
		end)
	end)
	helpers.it("old API failure after same-URI STARTED admits no Atom fallback child",function()
		run(function(c,_,calls,pushes)
			c.handshake();helpers.assert_eq(#calls,1)
			c.start_load();calls[1](0,"","Independent API failure")
			helpers.assert_eq(#calls,1,"stale API callback must not reach shared fallback admission")
			helpers.assert_eq(#pushes,0)
		end)
	end)
	helpers.it("current API failure still follows the original Atom fallback policy",function()
		run(function(c,_,calls,pushes)
			c.handshake();calls[1](0,"","Independent API failure")
			helpers.assert_eq(#calls,2)
			calls[2](200,"<feed></feed>",nil)
			helpers.assert_eq(#pushes,1)
			helpers.assert_eq(pushes[1].feed,"<feed></feed>")
		end)
	end)
	helpers.it("release completion cannot borrow replacement during actual URI probe",function()
		run(function(c,_,calls,pushes)
			c.handshake();c.on_uri=function()c.on_uri=nil;c.start_load()end
			calls[1](200,"[]",nil);helpers.assert_eq(#pushes,0)
		end)
	end)
	helpers.it("actual asynchronous JS result cannot lend nonce to a successor load",function()
		run(function(c)
			local view=c.start_load();view.loading=false;view.on_load_changed(view,"FINISHED")
			local callback=view.results[1]
			c.on_finish=function()c.on_finish=nil;c.start_load()end
			callback(view,string.rep("a",36))
			helpers.assert_eq(view.metadata,nil)
			helpers.assert_eq(c.manager.capture_document_owner("changelog"),nil)
		end)
	end)
	helpers.it("late ACK cannot initialize after exact native deadline",function()
		run(function(c)
			local v=c.start_load();local metadata=c.finish_load(v);c.now=5100;c.ack(v,metadata)
			helpers.assert_eq(v.confirmed,nil);helpers.assert_eq(#c.notices,1)
			helpers.assert_eq(c.manager.capture_document_owner("changelog"),nil)
		end)
	end)
	helpers.it("no ACK timeout admits one generic native notice and no document effect",function()
		run(function(c)
			c.start_load();c.now=5100;c.timers[1].expired();c.timers[1].expired()
			helpers.assert_eq(#c.notices,1)
			helpers.assert_eq(c.notices[1].title,require("infra.i18n").get("error_dialog.heading"))
			helpers.assert_eq(#c.effects,0)
		end)
	end)
	helpers.it("pause at timeout suppresses notice and resume cannot revive consent",function()
		run(function(c)
			local v=c.start_load();local old=c.finish_load(v);c.paused=true;c.now=5100;c.timers[1].expired()
			c.paused=false;c.ack(v,old)
			helpers.assert_eq(#c.notices,0);helpers.assert_eq(v.confirmed,nil)
			helpers.assert_eq(c.manager.capture_document_owner("changelog"),nil)
		end)
	end)
	helpers.it("successor during notifier capability probe cannot receive old notice",function()
		run(function(c)
			c.start_load();c.on_notice_probe=function()c.on_notice_probe=nil;c.start_load()end
			c.now=5100;c.timers[1].expired();helpers.assert_eq(#c.notices,0)
		end)
	end)
	helpers.it("fresh pause during notifier capability probe suppresses old notice",function()
		run(function(c)
			c.start_load();c.on_notice_probe=function()c.paused=true end
			c.now=5100;c.timers[1].expired();helpers.assert_eq(#c.notices,0)
		end)
	end)
	helpers.it("physical timer-close reentry cannot clear a replacement native window",function()
		run(function(c)
			c.start_load();local old_epoch=c.manager.current_epoch("changelog")
			c.on_cancel=function()
				c.on_cancel=nil
				helpers.assert_eq(c.manager.show("changelog"),true)
			end
			c.manager.hide("changelog",old_epoch)
			helpers.assert_eq(c.manager.current_epoch("changelog")~=old_epoch,true)
			helpers.assert_eq(c.manager.is_visible("changelog"),true)
		end)
	end)
end)

helpers.describe("actual STARTED and successor before native install acceptance",function()
	for _, port in ipairs({"blocked","find"})do
		helpers.it("reload during actual "..port.." cannot borrow successor for backup",function()
			run(function(c,Bridge,calls)
				local Installation=require("infra.installation")
				local Parser=require("updater.release_parser")
				local old_source,old_parse=Installation.is_source_run,Parser.parse_tag
				local old_manager=package.loaded["modules.updater.manager"]
				local real_manager=require("modules.updater.manager")
				local backups,armed=0,false
				Bridge._config_backup={owner=function()return {latest=function()return nil end,
					create=function()backups=backups+1;return {path="/controlled/backup"}end}end}
				package.loaded["modules.updater.manager"]=setmetatable({installation_kind=function()return "standalone"end,
					release_record=function()return {tag="v9.8.7"}end,download_release=function()return false end},{__index=real_manager})
				local function replace()
					if armed then armed=false;c.handshake()end
				end
				Installation.is_source_run=function()if port=="blocked"then replace()end;return false end
				Parser.parse_tag=function(chunk)if port=="find"then replace()end;return old_parse(chunk)end
				local ok,err=pcall(function()
					c.handshake();calls[1](200,'[{"tag_name":"v9.8.7","assets":[]}]',nil)
					armed=true;c.send({action="install_release",tag="v9.8.7",channel="dev"})
					helpers.assert_eq(armed,false,"actual native read/find port must trigger STARTED and fresh successor ready")
					helpers.assert_eq(backups,0)
				end)
				Installation.is_source_run,Parser.parse_tag=old_source,old_parse
				package.loaded["modules.updater.manager"]=old_manager
				if not ok then error(err)end
			end)
		end)
	end
end)

helpers.describe("actual owned native notification effect boundary",function()
	helpers.it("capability probe reentry cannot admit old notify-send command",function()
		local old_shell,old_notifier=package.loaded["adapters.shell_runner"],package.loaded["adapters.notifier"]
		local live,invoked=true,0
		package.loaded["adapters.shell_runner"]={has_command=function()live=false;return true end,
			quote=function(value)return value end,run=function()invoked=invoked+1;return true end}
		package.loaded["adapters.notifier"]=nil
		local ok,err=pcall(function()
			local Notifier=require("adapters.notifier")
			helpers.assert_eq(Notifier.send_owned("Generic error",{level="error"},function()return live end),false)
			helpers.assert_eq(invoked,0)
		end)
		package.loaded["adapters.shell_runner"],package.loaded["adapters.notifier"]=old_shell,old_notifier
		if not ok then error(err)end
	end)
end)
