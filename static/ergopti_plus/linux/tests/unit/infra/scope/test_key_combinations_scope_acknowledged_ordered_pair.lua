--- tests/unit/infra/scope/test_key_combinations_scope_acknowledged_ordered_pair.lua

--- Actual canonical pair and parameter owners through the shared publisher.
--- File and native delivery ports are controlled; no physical input is claimed.

package.loaded["tests.support.infra.scope.key_combinations_scope_fixture"] = nil
local Fixture = require("tests.support.infra.scope.key_combinations_scope_fixture")
local NativeLoop, helpers, Codec, Scope, path, backup, pair, binding, parameter, source, edits, with_owner, failed, next_scope, with_menu, find_menu =
	Fixture.NativeLoop, Fixture.helpers, Fixture.Codec, Fixture.Scope, Fixture.path, Fixture.backup, Fixture.pair, Fixture.binding, Fixture.parameter, Fixture.source, Fixture.edits, Fixture.with_owner, Fixture.failed, Fixture.next_scope, Fixture.with_menu, Fixture.find_menu




helpers.describe("acknowledged Linux ordered pair editing",function()
	helpers.it("rebuilds the actual installed pair engine only after source and delivery ACKs",function()
		with_owner(function(s)
			local physical={ready=true,physical=true,source="controlled-owned-keyboard",generation=7}
			helpers.assert_true(s.native~=nil,"pairs remain independent of the disabled tap-hold master")
			s.native:process(58,1,0,physical)
			local first,_,_,frame=s.native:process(15,1,10,physical)
			helpers.assert_eq(first[1].code,42);helpers.assert_true(frame.ack(true))
			s.before_publish=function() helpers.assert_eq(s.native,nil,"unpublished candidate cannot receive input") end
			helpers.assert_true(s.scope.edit(edits));helpers.assert_true(s.native~=nil)
			local retired_shift=false;for _,row in ipairs(s.retired) do if row.code==42 and row.value==0 then retired_shift=true end end
			helpers.assert_true(retired_shift,"the previous installed hold owes its exact release")
			s.native:process(58,1,1000,physical)
			local held,_,_,acquired=s.native:process(15,1,1010,physical)
			helpers.assert_eq(held[1].code,56,"published Alt slot replaces the old Shift snapshot")
			helpers.assert_true(acquired.ack(true))
			local _,tap,slot,released=s.native:process(15,0,1100,physical)
			helpers.assert_eq(tap,"open_url");helpers.assert_eq(slot,binding);helpers.assert_true(released.ack(true))
			helpers.assert_true(released.run(s.on_tap,physical));helpers.assert_eq(s.executed,{"open_url",binding})
		end,true)
	end)

	helpers.it("publishes coherent pair slots and owned parameters before reopening admission",function()
		with_owner(function(s)
			s.before_publish=function(target)
				helpers.assert_true(s.pairs.configuration_pending());helpers.assert_eq(s.pairs.capture_runtime(),nil)
				helpers.assert_true(type(s.gestures.parameter_configuration_snapshot(s.scope))=="table")
			end
			helpers.assert_true(s.scope.edit(edits));failed(s.scope.pending())
			local decoded=Codec.decode(s.bytes[path]);helpers.assert_eq(decoded.shortcuts.key_combination_holds[pair],"alt")
			helpers.assert_eq(decoded.gesture_parameters[parameter],"https://new.example")
			helpers.assert_eq(decoded.shortcuts.key_combination_taps.future_then_tab,"future");helpers.assert_eq(decoded.unrelated.keep,42)
			helpers.assert_eq(s.bytes[backup],source);helpers.assert_eq(s.publications,1)
			local guard=s.pairs.capture_action(binding,"open_url");helpers.assert_true(guard())
			helpers.assert_eq(s.gestures.get_action_parameter(binding,"open_url"),"https://new.example")
		end)
	end)
	helpers.it("deletes an owned slot without deleting future pair neighbors",function()
		with_owner(function(s)
			helpers.assert_true(s.scope.edit({{section="shortcuts.key_combination_taps",key=pair,delete=true}}))
			local decoded=Codec.decode(s.bytes[path]);helpers.assert_eq(decoded.shortcuts.key_combination_taps[pair],nil)
			helpers.assert_eq(decoded.shortcuts.key_combination_taps.future_then_tab,"future");helpers.assert_eq(s.pairs.get_action(pair),"none")
		end)
	end)
	helpers.it("refuses unrelated, unknown, native-only and malformed edit rows",function()
		for _,row in ipairs({{section="shortcuts.keyboard",key="ctrl_j",value="copy"},
			{section="shortcuts.key_combination_taps",key="unknown_then_tab",value="copy"},
			{section="shortcuts.key_combination_taps",key=pair,value="one_shot_shift"},
			{section="shortcuts.key_combination_holds",key=pair,value="unknown"},
			{section="gesture_parameters",key=parameter,value="invalid"},
			{section="gesture_parameters",key="tap_3__open_url",value="https://new.example"},
			{section="shortcuts.key_combination_taps",key=pair,value="copy",intent={kind="keyboard_assignment"}}}) do
			with_owner(function(s) failed(s.scope.edit({row}));helpers.assert_eq(s.bytes[path],source);helpers.assert_eq(s.publications,0);failed(s.scope.pending()) end)
		end
	end)
	helpers.it("refuses dense-row violations before any publication",function()
		for _,rows in ipairs({{edits[1],edits[1]},setmetatable({edits[1]},{}),{[1]=edits[1],[3]=edits[2]},{{section="shortcuts.key_combination_taps",key=pair,value="copy",extra=true}}}) do
			with_owner(function(s) failed(s.scope.edit(rows));helpers.assert_eq(s.publications,0);failed(s.scope.pending()) end)
		end
	end)
	helpers.it("retains refused pair retirement and retries only its exact token",function()
		with_owner(function(s)
			s.changed=function() return false end;failed(s.scope.edit(edits));helpers.assert_true(s.scope.pending())
			helpers.assert_true(s.pairs.owns_configuration(s.scope));failed(s.pairs.release_configuration({}));helpers.assert_eq(s.publications,0)
			s.changed=nil;helpers.assert_true(s.scope.retry_restore());failed(s.scope.pending());failed(s.pairs.configuration_pending())
		end)
	end)
	helpers.it("never releases a foreign parameter lease after admission refusal",function()
		with_owner(function(s)
			local foreign={};helpers.assert_true(s.gestures.acquire_parameter_configuration(foreign))
			failed(s.scope.edit(edits));helpers.assert_true(s.scope.pending());helpers.assert_true(s.scope.retry_restore())
			helpers.assert_true(type(s.gestures.parameter_configuration_snapshot(foreign))=="table")
			helpers.assert_true(s.gestures.release_parameter_configuration(foreign));helpers.assert_eq(s.publications,0)
		end)
	end)
	helpers.it("contains mutation followed by a thrown parameter apply and restores runtime",function()
		with_owner(function(s)
			local apply=s.gestures.apply_parameter_configuration;local once=true
			s.gestures.apply_parameter_configuration=function(token,params)
				local accepted=apply(token,params);if once then once=false;error("PRIVATE NATIVE ERROR") end;return accepted
			end
			failed(s.scope.edit(edits));failed(s.scope.pending());helpers.assert_eq(s.bytes[path],source)
			helpers.assert_eq(s.gestures.get_action_parameter(binding,"open_url"),"https://old.example")
			helpers.assert_eq(s.pairs.engine_options({}).holds[pair],"shift")
		end)
	end)
	helpers.it("retains refused release through fenced inverse and recovers later",function()
		with_owner(function(s)
			local release=s.gestures.release_parameter_configuration
			s.gestures.release_parameter_configuration=function() return false end
			failed(s.scope.edit(edits));helpers.assert_true(s.scope.pending());failed(s.scope.edit(edits));failed(s.scope.release())
			helpers.assert_true(s.pairs.configuration_pending());helpers.assert_eq(s.bytes[path],source)
			s.gestures.release_parameter_configuration=release;helpers.assert_true(s.scope.retry_restore());failed(s.scope.pending())
		end)
	end)
	helpers.it("preserves a source changed before conditional publication",function()
		with_owner(function(s)
			local foreign=source:gsub('caps_lock_then_tab = "shift"','caps_lock_then_tab = "nav"').."\n# foreign edit\n"
			s.before_publish=function(target) if target==path then s.bytes[path]=foreign end end
			failed(s.scope.edit(edits));helpers.assert_eq(s.bytes[path],foreign);failed(s.scope.pending())
			helpers.assert_eq(s.pairs.capture_runtime(),nil);helpers.assert_eq(s.pairs.engine_options({}).holds[pair],"shift")
		end)
	end)
	helpers.it("retains foreign-source revert debt until the exact candidate is restored",function()
		with_owner(function(s)
			helpers.assert_true(s.scope.edit(edits));local candidate=s.bytes[path];local foreign=candidate.."\n# foreign\n";s.bytes[path]=foreign
			failed(s.scope.revert());helpers.assert_true(s.scope.pending());helpers.assert_eq(s.bytes[path],foreign)
			helpers.assert_true(s.pairs.configuration_pending());failed(s.scope.edit(edits))
			s.bytes[path]=candidate;helpers.assert_true(s.scope.retry_restore());helpers.assert_eq(s.bytes[path],source)
			failed(s.scope.pending());helpers.assert_true(s.pairs.capture_runtime()())
		end)
	end)
	helpers.it("rejects reentrant edit, inverse and retry from native publication callbacks",function()
		with_owner(function(s)
			s.before_publish=function() failed(s.scope.edit(edits));failed(s.scope.revert());failed(s.scope.retry_restore());helpers.assert_true(s.scope.pending()) end
			helpers.assert_true(s.scope.edit(edits));failed(s.scope.pending());helpers.assert_eq(s.publications,1)
		end)
	end)

	helpers.it("refuses a successor during native lease acquisition before transaction capture",function()
		with_owner(function(s)
			s.changed=function()
				failed(s.scope.edit(edits));failed(s.scope.retry_restore());failed(s.scope.revert())
				helpers.assert_true(s.scope.pending());return true
			end
			helpers.assert_true(s.scope.edit(edits));failed(s.scope.pending());helpers.assert_eq(s.publications,1)
		end)
	end)
	helpers.it("retains unknown pair lease identity rather than assuming idle",function()
		with_owner(function(s)
			local identify=s.pairs.owns_configuration;s.pairs.owns_configuration=function() error("PRIVATE OWNERSHIP ERROR") end
			failed(s.scope.edit(edits));helpers.assert_true(s.scope.pending());failed(s.scope.retry_restore());failed(s.scope.release())
			s.pairs.owns_configuration=identify;helpers.assert_true(s.scope.retry_restore());failed(s.scope.pending())
		end)
	end)
	helpers.it("retains an exact parameter acquisition that throws after mutation",function()
		with_owner(function(s)
			local acquire=s.gestures.acquire_parameter_configuration
			s.gestures.acquire_parameter_configuration=function(token) helpers.assert_true(acquire(token));error("PRIVATE ACQUISITION ERROR") end
			failed(s.scope.edit(edits));helpers.assert_true(s.scope.pending())
			helpers.assert_true(type(s.gestures.parameter_configuration_snapshot(s.scope))=="table")
			s.gestures.acquire_parameter_configuration=acquire;helpers.assert_true(s.scope.retry_restore());failed(s.scope.pending())
			helpers.assert_eq(s.gestures.parameter_configuration_snapshot(s.scope),nil)
		end)
	end)
	helpers.it("retains an unknown parameter acquisition receipt until identified",function()
		with_owner(function(s)
			local snapshot=s.gestures.parameter_configuration_snapshot
			s.gestures.parameter_configuration_snapshot=function() error("PRIVATE RECEIPT ERROR") end
			failed(s.scope.edit(edits));helpers.assert_true(s.scope.pending());failed(s.scope.retry_restore())
			s.gestures.parameter_configuration_snapshot=snapshot;helpers.assert_true(s.scope.retry_restore());failed(s.scope.pending())
		end)
	end)
	helpers.it("reacquires native fences before reverting committed slots",function()
		with_owner(function(s)
			helpers.assert_true(s.scope.edit(edits));local candidate=s.bytes[path]
			s.changed=function() return false end;failed(s.scope.revert());helpers.assert_true(s.scope.pending());helpers.assert_eq(s.bytes[path],candidate)
			s.changed=nil;helpers.assert_true(s.scope.retry_restore());helpers.assert_eq(s.bytes[path],source);failed(s.scope.pending())
		end)
	end)
	helpers.it("refuses paused edits before native acquisition or source changes",function()
		with_owner(function(s) s.paused=true;failed(s.scope.edit(edits));helpers.assert_eq(s.changes,0);helpers.assert_eq(s.publications,0) end)
	end)
end)




helpers.describe("ordered editing source and program retirement",function()
	helpers.it("refuses a picker source changed before acquiring native leases",function()
		with_owner(function(s)
			local receipt=s.pairs.capture_edit_source();helpers.assert_true(receipt.guard())
			local owner=next_scope(s,receipt);s.bytes[path]=source.."\n# changed\n"
			failed(receipt.guard());failed(owner.edit(edits));helpers.assert_eq(s.changes,0);helpers.assert_eq(s.publications,0)
		end)
	end)
	helpers.it("refuses source substitution during native acquisition without overwriting it",function()
		with_owner(function(s)
			local receipt=s.pairs.capture_edit_source();local owner=next_scope(s,receipt)
			local foreign=source:gsub('caps_lock_then_tab = "shift"','caps_lock_then_tab = "nav"')
			s.changed=function() s.bytes[path]=foreign;return true end
			failed(owner.edit(edits));helpers.assert_eq(s.bytes[path],foreign);helpers.assert_eq(s.publications,0);failed(owner.pending())
		end)
	end)
	helpers.it("retains refused program retirement and exact leases before any write",function()
		with_owner(function(s)
			local stop=s.gestures.stop_programs;local calls=0
			s.gestures.stop_programs=function() calls=calls+1;return false end
			failed(s.scope.edit(edits));helpers.assert_true(s.scope.pending());helpers.assert_true(s.pairs.owns_configuration(s.scope))
			helpers.assert_true(type(s.gestures.parameter_configuration_snapshot(s.scope))=="table")
			failed(s.scope.retry_restore());failed(s.scope.release());helpers.assert_eq(s.publications,0);helpers.assert_eq(s.bytes[backup],nil)
			helpers.assert_eq(calls,2);s.gestures.stop_programs=stop;helpers.assert_true(s.scope.retry_restore());failed(s.scope.pending())
		end)
	end)
	helpers.it("contains throwing program retirement and cannot acknowledge idle",function()
		with_owner(function(s)
			local stop=s.gestures.stop_programs;s.gestures.stop_programs=function() error("PRIVATE RETIREMENT ERROR") end
			failed(s.scope.edit(edits));helpers.assert_true(s.scope.pending());failed(s.scope.retry_restore())
			helpers.assert_eq(s.publications,0);s.gestures.stop_programs=stop;helpers.assert_true(s.scope.retry_restore())
		end)
	end)
	helpers.it("uses the real Linux declaration and sparse typed gate without disabling editing",function()
		with_owner(function(s)
			local manifest=require("infra.manifest_reader")
			helpers.assert_true(manifest.has_default("category_enabled.key_combinations"))
			helpers.assert_eq(manifest.default_for("category_enabled.key_combinations"),true)
			local disabled=next_scope(s,s.pairs.capture_edit_source(),manifest,".disable")
			helpers.assert_true(disabled.set_enabled(false));helpers.assert_eq(Codec.decode(s.bytes[path]).category_enabled.key_combinations,false)
			failed(s.pairs.is_enabled());helpers.assert_eq(s.pairs.capture_runtime(),nil)
			local receipt=s.pairs.capture_edit_source();helpers.assert_true(receipt.guard())
			local enabled=next_scope(s,receipt,manifest,".enable");helpers.assert_true(enabled.set_enabled(true))
			helpers.assert_eq(Codec.decode(s.bytes[path]).category_enabled.key_combinations,nil)
			helpers.assert_true(s.pairs.is_enabled());helpers.assert_true(s.pairs.capture_runtime()())
			helpers.assert_eq(Codec.decode(s.bytes[path]).unrelated.keep,42)
		end)
	end)
	helpers.it("keeps all three actual recommendations safe for the Linux pair dispatcher",function()
		local manifest=require("infra.manifest_reader")
		helpers.assert_eq(manifest.recommended_for("shortcuts.key_combination_taps.alt_gr_then_left_alt"),"ctrl_backspace")
		helpers.assert_eq(manifest.recommended_for("shortcuts.key_combination_taps.alt_gr_then_caps_lock"),"ctrl_delete")
		helpers.assert_eq(manifest.recommended_for("shortcuts.key_combination_taps.left_alt_then_caps_lock"),"none")
	end)
end)




helpers.describe("canonical parameter and native source frame",function()
	helpers.it("refuses an unedited external parameter value before backup or runtime mutation",function()
		with_owner(function(s)
			local foreign=source:gsub('https://old.example','https://external.example')
			s.bytes[path]=foreign
			failed(s.scope.edit({{section="shortcuts.key_combination_holds",key=pair,value="alt"}}))
			helpers.assert_eq(s.bytes[path],foreign);helpers.assert_eq(s.bytes[backup],nil);helpers.assert_eq(s.publications,0)
			helpers.assert_eq(s.gestures.get_action_parameter(binding,"open_url"),"https://old.example")
			helpers.assert_eq(s.pairs.get_hold(pair),"shift");failed(s.scope.pending())
		end)
	end)
	helpers.it("refuses a canonical parameter deletion while retaining the old runtime",function()
		with_owner(function(s)
			s.bytes[path]=source:gsub('combination__caps_lock_then_tab__open_url = "https://old.example"\n','')
			local foreign=s.bytes[path]
			failed(s.scope.edit({{section="shortcuts.key_combination_holds",key=pair,value="alt"}}))
			helpers.assert_eq(s.bytes[path],foreign);helpers.assert_eq(s.bytes[backup],nil);helpers.assert_eq(s.publications,0)
			helpers.assert_eq(s.gestures.get_action_parameter(binding,"open_url"),"https://old.example")
		end)
	end)
	helpers.it("rechecks source after the native parameter callback and restores the previous pair",function()
		with_owner(function(s)
			local apply=s.gestures.apply_parameter_configuration
			local foreign=source.."\n# external native callback\n";local once=true
			s.gestures.apply_parameter_configuration=function(token,params)
				local accepted=apply(token,params)
				if once then once=false;s.bytes[path]=foreign end
				return accepted
			end
			failed(s.scope.edit(edits));helpers.assert_eq(s.bytes[path],foreign);helpers.assert_eq(s.publications,0)
			helpers.assert_eq(s.pairs.get_hold(pair),"shift")
			helpers.assert_eq(s.gestures.get_action_parameter(binding,"open_url"),"https://old.example")
			failed(s.scope.pending())
		end)
	end)
	helpers.it("refuses source replacement during native frame read without acknowledging a successor",function()
		with_owner(function(s)
			local read=s.files.read_with_status;local mutated=false
			s.files.read_with_status=function(target)
				local content,status=read(target)
				if target==path and s.pairs.configuration_pending() and not mutated then
					mutated=true;s.bytes[path]=source.."\n# acquisition change\n"
				end
				return content,status
			end
			failed(s.scope.edit(edits));helpers.assert_true(mutated);helpers.assert_eq(s.publications,0)
			helpers.assert_eq(s.bytes[backup],nil);failed(s.scope.pending())
		end)
	end)
	helpers.it("refuses the dynamic category fallback without a supported Linux declaration",function()
		with_owner(function(s)
			local future=require("infra.manifest_reader")
			local unsupported={sparse_operation=future.sparse_operation,scope_plan=future.scope_plan,
				find_entry_by_path=function() return nil end,has_default=function() return true end}
			local owner=next_scope(s,nil,unsupported)
			failed(owner.set_enabled(false));helpers.assert_eq(s.changes,0);helpers.assert_eq(s.publications,0)
		end)
	end)
end)




helpers.describe("actual shared Linux ordered-pair menu",function()
	helpers.it("renders ordered tap and hold slots without a chord provider",function()
		with_menu(function(s)
			local rows=s.build();local row=find_menu(rows,"caps_lock → tab")
			helpers.assert_true(type(row)=="table" and type(row.menu)=="table")
			helpers.assert_eq(#row.menu,3,"the native pair submenu has clear, tap and hold only")
			local tap=find_menu(row.menu,s.translate("menu.shortcuts.key_combinations_hold_tap"):gsub("%%s","open_url"))
			helpers.assert_true(type(tap)=="table" and type(tap.fn)=="function")
			helpers.assert_true(find_menu(row.menu,s.translate("menu.shortcuts.key_combinations_hold_hold"):gsub("%%s",""))~=nil)
			helpers.assert_eq(find_menu(rows,s.translate("menu.shortcuts.key_combinations_chord")),nil)
		end)
	end)
	helpers.it("opens the real action catalogue, offers CapsWord and excludes pair-native state actions",function()
		with_menu(function(s)
			local row=find_menu(s.build(),"caps_lock → tab")
			local tap=find_menu(row.menu,s.translate("menu.shortcuts.key_combinations_hold_tap"):gsub("%%s","open_url"))
			helpers.assert_true(tap.fn());helpers.assert_eq(s.picker.binding,binding)
			local found,caps_word=false,false
			for _,item in ipairs(s.picker.items) do
				helpers.assert_true(item.id~="one_shot_shift")
				if item.id=="open_url" then found=true end
				if item.id=="caps_word" then caps_word=true end
			end
			helpers.assert_true(found)
			-- (linux-caps-word-trigger) the Windows pair LAlt then CapsLock can bind it.
			helpers.assert_true(caps_word,"the pair picker offers CapsWord")
			helpers.assert_true(s.picker.confirm("open_url","https://picker.example"))
			helpers.assert_eq(s.gestures.get_action_parameter(binding,"open_url"),"https://picker.example")
			helpers.assert_eq(Codec.decode(s.bytes[path]).gesture_parameters[parameter],"https://picker.example")
			helpers.assert_eq(s.refreshes,1)
		end)
	end)
	helpers.it("refuses a stale picker source without changing either canonical slots or parameters",function()
		with_menu(function(s)
			local row=find_menu(s.build(),"caps_lock → tab")
			local tap=find_menu(row.menu,s.translate("menu.shortcuts.key_combinations_hold_tap"):gsub("%%s","open_url"))
			helpers.assert_true(tap.fn());local foreign=source.."\n# picker source changed\n";s.bytes[path]=foreign
			failed(s.picker.confirm("open_url","https://picker.example"));helpers.assert_eq(s.bytes[path],foreign)
			helpers.assert_eq(s.gestures.get_action_parameter(binding,"open_url"),"https://old.example")
			helpers.assert_eq(s.publications,0);helpers.assert_eq(s.errors,1)
		end)
	end)
	helpers.it("publishes a selected hold through the actual scope and supports category-off editing",function()
		with_menu(function(s)
			local row=find_menu(s.build(),"caps_lock → tab")
			local hold=find_menu(row.menu,s.translate("menu.shortcuts.key_combinations_hold_hold"):gsub("%%s",""))
			local alt=hold;helpers.assert_true(type(alt)=="table")
			helpers.assert_eq(hold.menu,nil,"the hold row opens a native modal instead of an eager subtree")
			s.hold_selection=s.translate("tap_hold.hold.alt")
			helpers.assert_true(alt.fn());helpers.assert_eq(s.pairs.get_hold(pair),"alt")
			local offered=false;for _,choice in ipairs(s.hold_choices) do if choice==s.hold_selection then offered=true end end
			helpers.assert_true(offered,"the actual shared hold catalogue offers the confirmed modal value")
			local toggle=find_menu(s.build(),s.translate("menu.shortcuts.key_combinations_enable"))
			helpers.assert_true(toggle.fn());failed(s.pairs.is_enabled())
			local nextrow=find_menu(s.build(),"caps_lock → tab")
			local nexttap=find_menu(nextrow.menu,s.translate("menu.shortcuts.key_combinations_hold_tap"):gsub("%%s","open_url"))
			helpers.assert_eq(nexttap.disabled,nil);helpers.assert_true(nexttap.fn())
			helpers.assert_true(s.picker.confirm("copy"));helpers.assert_eq(s.pairs.get_action(pair),"copy")
			failed(s.pairs.is_enabled())
		end)
	end)
	helpers.it("retains program retirement refusal from a real picker selection",function()
		with_menu(function(s)
			local row=find_menu(s.build(),"caps_lock → tab")
			local tap=find_menu(row.menu,s.translate("menu.shortcuts.key_combinations_hold_tap"):gsub("%%s","open_url"))
			helpers.assert_true(tap.fn());local stop=s.gestures.stop_programs;s.gestures.stop_programs=function() return false end
			failed(s.picker.confirm("copy"));helpers.assert_true(s.pairs.configuration_pending());helpers.assert_eq(s.publications,0)
			s.gestures.stop_programs=stop
			local retried=find_menu(s.build(),"caps_lock → tab")
			helpers.assert_true(type(retried)=="table");failed(s.pairs.configuration_pending())
			helpers.assert_eq(s.publications,0)
		end)
	end)
end)




helpers.describe("owned program action in the actual ordered picker",function()
	helpers.it("admits only installed pair domains to the native program parameter page",function()
		with_menu(function(s)
			local known={{type="action",id="run_program"}}
			s.gestures.get_picker_parameter_fields(known,binding)
			helpers.assert_eq(known[1].disabled,nil);helpers.assert_eq(known[1].parameter,"program")
			local foreign={{type="action",id="run_program"}}
			s.gestures.get_picker_parameter_fields(foreign,"combination__unknown_then_tab")
			helpers.assert_eq(foreign[1].disabled,true)
		end)
	end)
	helpers.it("publishes a native picker scalar and pair assignment together after retirement",function()
		with_menu(function(s)
			local row=find_menu(s.build(),"caps_lock → tab")
			local tap=find_menu(row.menu,s.translate("menu.shortcuts.key_combinations_hold_tap"):gsub("%%s","open_url"))
			helpers.assert_true(tap.fn())
			local scalar='{"version":1,"executable":"/controlled/program","arguments":["","literal"]}'
			helpers.assert_true(s.picker.confirm("run_program",scalar))
			local doc=Codec.decode(s.bytes[path]);helpers.assert_eq(doc.shortcuts.key_combination_taps[pair],"run_program")
			helpers.assert_eq(doc.gesture_parameters[binding.."__run_program"],scalar)
			helpers.assert_eq(s.gestures.get_action_parameter(binding,"run_program"),scalar)
			helpers.assert_eq(s.gestures.get_action_parameter(binding,"open_url"),"https://old.example")
			helpers.assert_eq(s.refreshes,1);helpers.assert_eq(s.publications,1)
		end)
	end)
	helpers.it("rejects a private parameter generation changed while the picker is open",function()
		with_menu(function(s)
			local row=find_menu(s.build(),"caps_lock → tab")
			local tap=find_menu(row.menu,s.translate("menu.shortcuts.key_combinations_hold_tap"):gsub("%%s","open_url"))
			helpers.assert_true(tap.fn());local token={}
			helpers.assert_true(s.gestures.acquire_parameter_configuration(token))
			helpers.assert_true(s.gestures.apply_parameter_configuration(token,{[parameter]="https://other.example"}))
			helpers.assert_true(s.gestures.release_parameter_configuration(token))
			failed(s.picker.confirm("copy"));helpers.assert_eq(s.bytes[path],source);helpers.assert_eq(s.publications,0)
			helpers.assert_eq(s.pairs.get_action(pair),"open_url")
		end)
	end)
end)




helpers.describe("exact configuration route after native callbacks",function()
	helpers.it("refuses a route handoff after parameter application before publishing the old source",function()
		with_owner(function(s)
			local route=path;local other="/controlled/other.toml";s.bytes[other]=source
			local Pair=require("modules.shortcuts.key_combinations")
			local owned=Pair.new({keys={{id="caps_lock",key="caps_lock"},{id="tab",key="tab"}},
				hold_picker={modifiers={"shift","alt"},layers={"nav"}},files=s.files,route=function() return route end,
				is_paused=function() return s.paused end,actions=s.gestures,changed=function() return true end})
			local owner=Scope.new({path=path,backup_path=backup,files=s.files,combinations=owned,parameters=s.gestures,
				manifest={scope_plan=function() return {presets={},operations={}} end},is_paused=function() return s.paused end})
			local apply=s.gestures.apply_parameter_configuration
			s.gestures.apply_parameter_configuration=function(token,params)
				local accepted=apply(token,params);route=other;return accepted
			end
			failed(owner.edit(edits));helpers.assert_eq(s.bytes[path],source);helpers.assert_eq(s.bytes[other],source)
			helpers.assert_eq(s.publications,0);helpers.assert_eq(owned.get_hold(pair),"shift")
			helpers.assert_eq(s.gestures.get_action_parameter(binding,"open_url"),"https://old.example")
			failed(owner.pending())
		end)
	end)
end)




helpers.describe("final ordered-pair publication route ownership",function()
	for _,phase in ipairs({"publication","parameter_release","pair_release"}) do
		helpers.it("retains the exact inverse when "..phase.." hands off the canonical route",function()
			with_owner(function(s)
				local route,other=path,"/controlled/other.toml"
				local Pair=require("modules.shortcuts.key_combinations")
				local handed=false
				local owned
				local function handoff()
					if handed then return end
					handed=true;route=other;s.bytes[other]=s.bytes[path]
				end
				owned=Pair.new({keys={{id="caps_lock",key="caps_lock"},{id="tab",key="tab"}},
					hold_picker={modifiers={"shift","alt"},layers={"nav"}},files=s.files,route=function() return route end,
					is_paused=function() return s.paused end,actions=s.gestures,changed=function()
						if phase=="pair_release" and s.publications==1 and not owned.configuration_pending() then handoff() end
						return true
					end})
				local owner=Scope.new({path=path,backup_path=backup,files=s.files,combinations=owned,parameters=s.gestures,
					manifest={scope_plan=function() return {presets={},operations={}} end},is_paused=function() return s.paused end})
				if phase=="publication" then
					s.before_publish=function(target,candidate)
						if target==path and not handed then handed=true;route=other;s.bytes[other]=candidate end
					end
				elseif phase=="parameter_release" then
					local release=s.gestures.release_parameter_configuration
					s.gestures.release_parameter_configuration=function(token)
						local accepted=release(token);if accepted==true and s.publications==1 then handoff() end;return accepted
					end
				end
				local accepted=owner.edit(edits)
				helpers.assert_true(handed,"The actual native/file callback must reach the handoff premise")
				failed(accepted);helpers.assert_true(owner.pending())
				helpers.assert_true(owned.owns_configuration(owner))
				helpers.assert_eq(s.bytes[path],source,"Inverse restores only the exact originally published path")
				local foreign=s.bytes[other];helpers.assert_eq(Codec.decode(foreign).shortcuts.key_combination_holds[pair],"alt")
				helpers.assert_eq(owned.get_hold(pair),"shift")
				helpers.assert_eq(s.gestures.get_action_parameter(binding,"open_url"),"https://old.example")
				failed(owner.retry_restore());helpers.assert_true(owner.pending());helpers.assert_eq(s.bytes[other],foreign)
				route=path;helpers.assert_true(owner.retry_restore());failed(owner.pending())
				failed(owned.configuration_pending());helpers.assert_eq(s.bytes[other],foreign)
			end)
		end)
	end
end)




helpers.describe("final ordered-pair parameter currency",function()
	helpers.it("keeps the actual parameter owner fenced across the final native pair callback",function()
		with_owner(function(s)
			local attempted,acquired,mutated=false,nil,nil
			s.changed=function()
				if s.pairs.get_hold(pair)=="alt" and not s.pairs.configuration_pending() and not attempted then
					attempted=true;local token={};acquired=s.gestures.acquire_parameter_configuration(token)
					if acquired==true then
						local params=s.gestures.parameter_configuration_snapshot(token);params[parameter]="https://unpublished.example"
						mutated=s.gestures.apply_parameter_configuration(token,params)
						helpers.assert_true(s.gestures.release_parameter_configuration(token))
					end
				end
				return true
			end
			local accepted=s.scope.edit(edits)
			helpers.assert_true(attempted);failed(acquired);helpers.assert_eq(mutated,nil)
			helpers.assert_true(accepted);failed(s.scope.pending())
			helpers.assert_eq(Codec.decode(s.bytes[path]).gesture_parameters[parameter],"https://new.example")
			helpers.assert_eq(s.gestures.get_action_parameter(binding,"open_url"),"https://new.example")
		end)
	end)
	helpers.it("refuses an actual unpublished parameter mutation inside the detached source guard",function()
		with_owner(function(s)
			local capture=s.pairs.capture_edit_source;local once=true
			s.pairs.capture_edit_source=function(...)
				local receipt=capture(...)
				if receipt and s.publications==1 and s.gestures.parameter_configuration_snapshot(s.scope)==nil and once then
					local guard=receipt.guard;receipt.guard=function()
						local current=guard()
						if once then once=false;helpers.assert_true(s.gestures.set_action_parameter(binding,"open_url","https://unpublished.example")) end
						return current
					end
				end
				return receipt
			end
			failed(s.scope.edit(edits));failed(s.scope.pending());helpers.assert_eq(once,false)
			helpers.assert_eq(s.bytes[path],source)
			helpers.assert_eq(s.gestures.get_action_parameter(binding,"open_url"),"https://old.example")
		end)
	end)
end)




helpers.describe("staged ordered-pair native delivery",function()
	for _, mode in ipairs({"accepted","refused","throwing"}) do
		helpers.it("blocks actual native hold delivery inside a "..mode.." final parameter callback",function()
			with_owner(function(s)
				local release=s.gestures.release_parameter_configuration
				local observed=false
				s.gestures.release_parameter_configuration=function(token)
					if token==s.scope and s.publications==1 and not observed then
						observed=true
						s.callback_runtime=s.pairs.capture_runtime()
						s.callback_action=s.pairs.capture_action(binding,"open_url")
						s.callback_editor=s.pairs.capture_edit_source()
						s.callback_fenced=s.pairs.owns_delivery_fence(s.scope)
						local receipt=s.pairs.capture_edit_source(s.scope);s.callback_source=receipt and receipt.guard()
						s.callback_modifier=false;s.callback_tap=false
						local physical={ready=true,physical=true,source="controlled-owned-keyboard",generation=7}
						for _,event in ipairs({{58,1},{15,1},{15,0},{58,0}}) do
							local rows,action,_,frame=s.native:process(event[1],event[2],1000,physical)
							for _,row in ipairs(rows or {}) do
								if row.code==42 or row.code==56 then s.callback_modifier=true end
							end
							if action then s.callback_tap=true end
							if frame and frame.ack then frame.ack(true) end
						end
						local foreign={};s.callback_foreign=s.pairs.acquire_configuration(foreign)
						if s.callback_foreign then s.pairs.release_configuration(foreign) end
						if mode=="refused" then return false end
						if mode=="throwing" then error("Controlled terminal refusal") end
					end
					return release(token)
				end
				local accepted=s.scope.edit(edits);helpers.assert_true(observed)
				print("STAGED_NATIVE_CALLBACK "..mode.." runtime="..tostring(s.callback_runtime~=nil).." modifier="..tostring(s.callback_modifier).." fence="..tostring(s.callback_fenced))
				helpers.assert_eq(s.callback_runtime,nil);helpers.assert_eq(s.callback_action,nil)
				helpers.assert_eq(s.callback_editor,nil);helpers.assert_true(s.callback_fenced)
				helpers.assert_true(s.callback_source);failed(s.callback_modifier);failed(s.callback_tap);failed(s.callback_foreign)
				if mode=="accepted" then
					helpers.assert_true(accepted);failed(s.scope.pending())
				else
					failed(accepted)
					if s.scope.pending() then helpers.assert_true(s.scope.retry_restore()) end
				end
				failed(s.pairs.owns_delivery_fence(s.scope))
				helpers.assert_true(s.pairs.capture_runtime()~=nil)
			end,true)
		end)
	end
	helpers.it("retains its private delivery fence through repeatable terminal release debt",function()
		with_owner(function(s)
			local release=s.gestures.release_parameter_configuration;local refuse=true
			s.gestures.release_parameter_configuration=function(token)
				if token==s.scope and refuse then return false end
				return release(token)
			end
			failed(s.scope.edit(edits));helpers.assert_true(s.scope.pending())
			helpers.assert_true(s.pairs.owns_delivery_fence(s.scope));helpers.assert_eq(s.pairs.capture_runtime(),nil)
			failed(s.scope.retry_restore());helpers.assert_true(s.pairs.owns_delivery_fence(s.scope))
			refuse=false;helpers.assert_true(s.scope.retry_restore());failed(s.scope.pending())
			failed(s.pairs.owns_delivery_fence(s.scope));helpers.assert_true(s.pairs.capture_runtime()~=nil)
		end,true)
	end)
end)




helpers.describe("staged publication source after native pause callback",function()
	helpers.it("retains exact inverse and fenced delivery after the final pause getter changes canonical route",function()
		with_owner(function(s)
			local route,other=path,"/controlled/final-pause.toml";local armed,handed,calls=false,false,0
			local Pair=require("modules.shortcuts.key_combinations")
			local owned=Pair.new({keys={{id="caps_lock",key="caps_lock"},{id="tab",key="tab"}},
				hold_picker={modifiers={"shift","alt"},layers={"nav"}},files=s.files,route=function() return route end,
				is_paused=function()
					if armed and not handed then calls=calls+1;if calls==5 then handed=true;route=other;s.bytes[other]=s.bytes[path] end end
					return false
				end,actions=s.gestures,changed=function() return true end})
			local owner=Scope.new({path=path,backup_path=backup,files=s.files,combinations=owned,parameters=s.gestures,
				manifest={scope_plan=function() return {presets={},operations={}} end},is_paused=function() return false end})
			local release=s.gestures.release_parameter_configuration
			s.gestures.release_parameter_configuration=function(token)
				local accepted=release(token);if accepted and token==owner and s.publications==1 then armed=true end;return accepted
			end
			local accepted=owner.edit(edits)
			print("TERMINAL_PAUSE_ROUTE_HANDOFF accepted="..tostring(accepted).." handed="..tostring(handed))
			helpers.assert_true(handed);failed(accepted);helpers.assert_true(owner.pending())
			helpers.assert_true(owned.owns_delivery_fence(owner));helpers.assert_eq(owned.capture_runtime(),nil)
			helpers.assert_eq(s.bytes[path],source);local foreign=s.bytes[other]
			failed(owner.retry_restore());helpers.assert_eq(s.bytes[other],foreign)
			route=path;helpers.assert_true(owner.retry_restore());failed(owner.pending());failed(owned.owns_delivery_fence(owner))
			helpers.assert_eq(s.bytes[other],foreign);helpers.assert_true(owned.capture_runtime()~=nil)
		end)
	end)
end)




helpers.describe("canonical detached pair parameter updates", function()
	helpers.it("uses the parameter owner's canonical transport without publication", function()
		with_owner(function(state)
			local before=state.gestures.get_all_action_parameters()
			local row=state.gestures.action_parameter_update(binding,"open_url","https://new.example")
			helpers.assert_eq(row,{section="gesture_parameters",key=parameter,value="https://new.example"})
			helpers.assert_eq(state.gestures.get_all_action_parameters(),before)
			helpers.assert_eq(state.publications,0)
			for _,args in ipairs({{binding,"open_url","invalid"},{"", "open_url","https://new.example"},{binding,"unknown","value"},{binding,"open_url",42}}) do
				helpers.assert_eq(state.gestures.action_parameter_update(args[1],args[2],args[3]),nil)
			end
			helpers.assert_true(state.scope.edit({row}))
			helpers.assert_eq(state.gestures.get_action_parameter(binding,"open_url"),"https://new.example")
		end)
	end)
end)




-- The native module owns one libuv loop context for this Lua state. Restoring
-- Lua fixture dependencies must never unload/reopen that process-wide owner.
helpers.describe("pair fixture native loop ownership", function()
	helpers.it("retains the exact libuv issuer across fixture teardown and a real callback turn", function()
		local native = NativeLoop
		local detached = {}; for key, value in pairs(native) do detached[key] = value end
		helpers.assert_true(not rawequal(detached, native), "a detached lookalike is not the native issuer")
		with_owner(function() end)
		helpers.assert_true(rawequal(package.loaded.luv, native), "fixture restoration retains the exact native loop issuer")
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
		helpers.assert_true(fired, "the actual native callback must execute")
		helpers.assert_true(settled, "the exact acquired timer must physically close")
	end)
end)

