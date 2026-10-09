--- _shared/lua/test/physical_editor_contract.lua

--- Independent user-facing publication and page ownership assertions.
return function(helpers, Editor, Window, Model)
	local function eq(actual, expected, label) helpers.assert_eq(actual, expected, label) end
	helpers.describe("Shared physical shortcut editor", function()
		helpers.it("(physical-editor-ui) complete user operation and exact native receipt contract", function()
			local function clone(value) if type(value)~='table' then return value end;local copy={};for k,v in pairs(value) do copy[k]=clone(v) end;return copy end
			local actions={is_assignable=function(a)return a=='none' or a=='send_text' or a=='copy' end,get_action_parameter_spec=function(a)return a=='send_text' and 'text' or nil end,validate_action_parameter=function(a,v)return a=='send_text' and type(v)=='string' and v~='' end,split_action_parameter_key=function(k)return k:match('^(keyboard__.+)__(.+)$') end}
			local function fixture(section)
			 local state={inventory={assignments={other_owner='copy'},parameters={future='private-unrecognized'}},receipt={},writes=0,selected={},callback=nil,refused=false,captured=true,page=true,close_ack=true}
			 local options={model=Model,catalogue=actions,parameter_section=section or 'gesture_parameters',positions={{code='KeyJ',available=true}},label=function(a)return a end,
			 capture=function()if not state.captured then return nil,"source_changed" end;return clone(state.inventory),state.receipt end,current=function(r)return state.receipt==r end,
			 commit=function(rows,source)eq(source,state.receipt,'Commit carries exact native receipt');if state.refused then return false,'collision' end;state.writes=state.writes+1
			 for _,row in ipairs(rows) do local map=row.section=='shortcuts.keyboard' and state.inventory.assignments or state.inventory.parameters;if row.delete then map[row.key]=nil else map[row.key]=row.value end end
			 state.receipt={};return true end,picker=function(binding,action,callback)state.callback=callback;state.binding=binding;return true end,
			 emit=function(data)state.selected[#state.selected+1]=data;return true end,translate=function(k)return k end,page_current=function()return state.page end,
			 send=function(name,data)state.sent={name=name,data=data};return true end,close=function()return state.close_ack end}
			 state.options=options;state.owner=Editor.new(options);return state
			end
			for _,section in ipairs({'gesture_parameters','gestures.action_parameters'}) do
			 local s=fixture(section);eq(#s.owner.open().entries,0,'Empty user default, unrelated assignment hidden');eq(s.writes,0,'Opening never publishes')
			 eq(s.owner.choose({code='KeyJ',mods={ctrl=true},request_id=1}),true,'Manual physical position opens actual picker seam');eq(s.binding,'keyboard__physical_ctrl_KeyJ','Canonical parameter binding')
			 eq(s.callback('send_text','★'),true,'Unicode star is the same arbitrary text model');eq(s.writes,0,'Choosing action never publishes');local token=s.selected[1].token
			 eq(s.selected[1].parameter,nil,'Scalar never returns to list page');s.refused=true;local result=s.owner.save(token);eq(result.committed,false,'Native refusal truthful');eq(result.reason,'collision','Only closed reason travels');eq(s.writes,0,'Refusal leaves inventory')
			 s.refused=false;result=s.owner.save(token);eq(result.committed,true,'Same draft retries');eq(result.refreshed,true,'New canonical display captured');eq(s.inventory.assignments.physical_ctrl_KeyJ,'send_text','Joint assignment published');eq(s.inventory.parameters.keyboard__physical_ctrl_KeyJ__send_text,'★','Joint private parameter published');eq(s.inventory.parameters.future,'private-unrecognized','Unknown private parameter preserved')
			 eq(s.owner.choose({code='KeyK',mods={},previous_slot='physical_ctrl_KeyJ',request_id=2}),true,'Rebind retains original identity');eq(s.callback('none',nil),true,'None is an explicit user choice');result=s.owner.save(s.selected[2].token);eq(result.committed,true,'Rebind one atomic batch');eq(s.inventory.assignments.physical_ctrl_KeyJ,nil,'Original assignment removed');eq(s.inventory.parameters.keyboard__physical_ctrl_KeyJ__send_text,nil,'Only original recognized parameter removed');eq(s.inventory.assignments.physical_none_KeyK,'none','None native reservation durable')
			 eq(s.owner.remove('physical_none_KeyK').committed,true,'Remove owns existing None');eq(s.inventory.assignments.other_owner,'copy','Foreign assignment unchanged');eq(s.inventory.parameters.future,'private-unrecognized','Foreign parameter unchanged after remove')
			end
			local s=fixture();s.owner.open();s.owner.choose({code='KeyJ',mods={},request_id=1});local old=s.callback;s.owner.choose({code='KeyK',mods={},request_id=2});eq(old('copy'),false,'Late old picker cannot replace draft');eq(s.callback('copy'),true,'Current picker acknowledged');s.receipt={};eq(s.owner.save(s.selected[1].token).committed,false,'Foreign source blocks publication');eq(s.writes,0,'Foreign source never overwritten')
			s=fixture();s.owner.open();s.owner.choose({code='KeyJ',mods={},request_id=1});s.owner.close();eq(s.callback('copy'),false,'Closed page picker cannot mutate');eq(s.writes,0,'Closed page never publishes')
			s=fixture();s.owner.open();s.owner.choose({code='KeyJ',mods={},request_id=1});s.callback('copy');s.options.capture=function()return nil end;local result=s.owner.save(s.selected[1].token);eq(result.committed,true,'Committed success survives refresh failure');eq(result.refreshed,false,'Failed refresh truthful')
			s=fixture();local w=Window.new(s.options);eq(w.receive({action='save',token=1}),false,'Before ready no write');eq(w.receive({action='ready'}),true,'Actual closed window protocol opens form');eq(s.sent.name,'init','Native init pushed');eq(s.sent.data.capture,false,'Browser event capture not offered');eq(w.receive({action='choose',request={code='KeyJ',mods={},request_id=1},path='/foreign'}),false,'Browser source authority rejected');eq(w.receive({action='choose',request={code='KeyJ',mods={},request_id=1}}),true,'Native protocol chooses without persistence');eq(s.writes,0,'Window choose preserves source');eq(s.callback('copy'),true,'Window actual controller picker callback');eq(s.sent.name,'selected','Picker selected event emitted');s.close_ack=false;eq(w.close(),false,'Native close refusal retains owner');s.close_ack=true;eq(w.close(),true,'Same native close retried');eq(w.receive({action='save',token=1}),false,'Retired window cannot write')
			s=fixture();s.captured=false;w=Window.new(s.options);eq(w.receive({action='ready'}),true,'Unreadable source receives an explicit readonly form');eq(s.sent.data.readonly,true,'Capture refusal makes form readonly');eq(s.sent.data.reason,'source_changed','Capture reason visible');eq(w.receive({action='choose',request={code='KeyJ',mods={},request_id=1}}),false,'Readonly frame cannot edit');eq(s.writes,0,'No source acknowledgement no write')
			s=fixture();s.owner.open();s.owner.choose({code='KeyJ',mods={},request_id=1});s.callback('copy');eq(s.owner.save(s.selected[1].token+1).committed,false,'Foreign opaque draft token refused');eq(s.writes,0,'Foreign token cannot publish')
			s=fixture();s.owner.open();s.receipt={};eq(s.owner.choose({code='KeyJ',mods={},request_id=1}),false,'Foreign native source refuses opening picker');eq(s.callback,nil,'No stale-source picker or draft admitted')
			s=fixture();local calls=0;s.options.current=function(receipt)calls=calls+1;if calls==2 then eq(s.owner.choose({code='KeyK',mods={},request_id=2}),false,'Current read cannot reenter admission')end;return s.receipt==receipt end;s.owner.open();eq(s.owner.choose({code='KeyJ',mods={},request_id=1}),true,'Native callback recursion is fenced');eq(calls>=2,true,'Controlled actual source getter called')
			s=fixture();s.options.capture=function()return nil,'unavailable' end;w=Window.new(s.options);eq(w.receive({action='ready'}),true,'Native unavailable reason renders readonly');eq(s.sent.data.reason,'window_unavailable','Unavailable owner never reports a false configuration change')
		end)
	end)
	helpers.describe("Shared physical position observation request", function()
		helpers.it("retains the native page/source guard without granting publication or browser authority", function()
			local page, canonical, callbacks, messages, writes = true, {}, {}, {}, 0
			local active, cancel_refused = nil, false
			local actions = { is_assignable = function(action) return action == "none" end,
				get_action_parameter_spec = function() end, validate_action_parameter = function() return false end,
				split_action_parameter_key = function() end }
			local options = { model = Model, catalogue = actions, parameter_section = "gesture_parameters",
				positions = {}, label = function(action) return action end,
				capture = function() return { assignments = {}, parameters = {} }, canonical end,
				current = function(receipt) return page and rawequal(receipt, canonical) end,
				commit = function() writes = writes + 1; return false end, picker = function() return false end,
				emit = function() return true end, page_current = function() return page end,
				send = function(name, packet) messages[#messages + 1] = { name, packet }; return true end,
				translate = function(key) return key end, close = function() return true end,
				position_available = function() return true end, position_field = "evdev" }
			options.capture_position = function(current, receive)
				active = {}; callbacks[#callbacks + 1] = { current = current, receive = receive, token = active }
				return active
			end
			options.cancel_position = function(token)
				if cancel_refused then return false end
				return rawequal(token, active)
			end
			local window = Window.new(options)
			eq(window.receive({ action = "ready" }), true, "actual shared session opens from native inventory")
			eq(messages[1][2].capture, true, "controlled original position port is distinct from inventory capture")
			eq(window.receive({ action = "capture_position", request = { request_id = 1, code = "KeyJ" } }), false,
				"browser code cannot supply native position facts")
			eq(#callbacks, 0, "forged request cannot enroll capture")
			eq(window.receive({ action = "capture_position", request = { request_id = 2 } }), true, "exact page enrolls one observation")
			eq(callbacks[1].receive({ native_code = 36, mods = { shift = true } }), true, "native code translates through the actual shared registry")
			eq(messages[#messages][1], "captured", "position result uses its own protocol message")
			eq(messages[#messages][2].code, "KeyJ", "registry resolves genuine evdev identity")
			eq(messages[#messages][2].request_id, 2, "result retains the exact page request")
			eq(writes, 0, "position observation creates no action, parameter or file write")
			eq(callbacks[1].receive({ native_code = 37, mods = {} }), false, "duplicate native callback cannot replace the observed position")
			eq(window.receive({ action = "save", token = 2 }), true, "unissued draft receives an explicit refusal result")
			eq(writes, 0, "request identity is never a publication token")
			canonical = {}
			eq(callbacks[1].current(), false, "changed canonical source withdraws capture")
			eq(callbacks[1].receive({ native_code = 36, mods = {} }), false, "stale source callback cannot fill a draft")
			page = false
			eq(window.receive({ action = "capture_position", request = { request_id = 3 } }), false, "foreign page cannot enroll")
			eq(callbacks[1].receive({ native_code = 36, mods = {} }), false, "retired page cannot accept a late native result")
			page, canonical = true, {}
			local retry
			local previous_cancel = options.cancel_position
			local recursions = 0
			local recurse = false
			options.cancel_position = function(token)
				if recurse then
					recursions = recursions + 1
					eq(retry.receive({ action = "cancel_position" }), false, "exact cancellation callback cannot recursively retire the same request")
				end
				return previous_cancel(token)
			end
			retry = Window.new(options)
			eq(retry.receive({ action = "ready" }), true, "fresh page captures a separate exact inventory")
			eq(retry.receive({ action = "capture_position", request = { request_id = 4 } }), true)
			cancel_refused = true
			eq(retry.receive({ action = "capture_position", request = { request_id = 5 } }), false, "refused cancellation retains the exact observation")
			eq(#callbacks, 2, "cancellation debt forbids a successor observation")
			eq(callbacks[2].receive({ native_code = 36, mods = {} }), false, "cancelled pending request cannot fill a draft")
			cancel_refused = false
			recurse = true
			eq(retry.receive({ action = "cancel_position" }), true, "exact cancellation retries after refusal")
			eq(recursions, 1, "native cancellation is called once, without recursive release")
			eq(retry.receive({ action = "capture_position", request = { request_id = 6 } }), true, "settled debt permits a separate request")
			eq(writes, 0, "capture lifecycle never creates a publication or action draft")

		end)
	end)

	helpers.describe("Independent getter enrollment boundary", function()
		helpers.it("refuses recursive enrollment during original source getter", function()
			local canonical, window, armed, recursive, callbacks, cancels = {}, nil, false, nil, {}, 0
			local active
			local actions = { is_assignable = function(a) return a == "none" end,
				get_action_parameter_spec = function() end, validate_action_parameter = function() return false end,
				split_action_parameter_key = function() end }
			local options = { model = Model, catalogue = actions, parameter_section = "gesture_parameters", positions = {},
				label = function(a) return a end, capture = function() return { assignments = {}, parameters = {} }, canonical end,
				current = function(receipt)
					if armed then
						armed = false
						recursive = window.receive({ action = "capture_position", request = { request_id = 202 } })
					end
					return rawequal(receipt, canonical)
				end,
				commit = function() error("no writer authorized") end, picker = function() return false end,
				emit = function() return true end, page_current = function() return true end,
				send = function() return true end, translate = function(k) return k end, close = function() return true end,
				position_available = function() return true end, position_field = "evdev",
				capture_position = function(current, receive)
					active = {}; callbacks[#callbacks + 1] = { current = current, receive = receive, token = active }
					return active
				end,
				cancel_position = function(token) cancels = cancels + 1; return rawequal(token, active) end }
			window = Window.new(options)
			eq(window.receive({ action = "ready" }), true, "original normal page bootstrap")
			armed = true
			local accepted = window.receive({ action = "capture_position", request = { request_id = 101 } })
			print("INDEPENDENT_GETTER_REENTRY", tostring(recursive), "OUTER", tostring(accepted), "ENROLLMENTS", #callbacks, "CANCELS", cancels)
			eq(recursive, false, "source getter may not recursively enroll another observation")
			eq(#callbacks, 1, "only outer request reaches the original native observation port")
			armed = true
			local delivered = callbacks[1].receive({ native_code = 36, mods = {} })
			eq(recursive, false, "delivery getter cannot recursively enroll a successor request")
			eq(#callbacks, 1, "delivery validation reserves the same original observation")
			eq(delivered, true, "refused nested enrollment preserves the valid outer delivery")
			window.close()
		end)
	end)

	helpers.describe("Independent terminal getter cancellation", function()
		helpers.it("refuses terminal emit after source getter cancels original request", function()
			local canonical, window, armed, recursive, callbacks, cancels = {}, nil, false, nil, {}, 0
			local active, calls, captured = nil, 0, 0
			local actions = { is_assignable = function(a) return a == "none" end,
				get_action_parameter_spec = function() end, validate_action_parameter = function() return false end,
				split_action_parameter_key = function() end }
			local options = { model = Model, catalogue = actions, parameter_section = "gesture_parameters", positions = {},
				label = function(a) return a end, capture = function() return { assignments = {}, parameters = {} }, canonical end,
				current = function(receipt)
					if armed then
						calls = calls + 1
						if calls == 2 then
							armed = false
							recursive = window.receive({ action = "cancel_position" })
						end
					end
					return rawequal(receipt, canonical)
				end,
				commit = function() error("no writer authorized") end, picker = function() return false end,
				emit = function() return true end, page_current = function() return true end,
				send = function(name) if name == "captured" then captured = captured + 1 end; return true end, translate = function(k) return k end, close = function() return true end,
				position_available = function() return true end, position_field = "evdev",
				capture_position = function(current, receive)
					active = {}; callbacks[#callbacks + 1] = { current = current, receive = receive, token = active }
					return active
				end,
				cancel_position = function(token) cancels = cancels + 1; return rawequal(token, active) end }
			window = Window.new(options)
			eq(window.receive({ action = "ready" }), true, "original normal page bootstrap")
			eq(window.receive({ action = "capture_position", request = { request_id = 101 } }), true)
			armed = true
			local accepted = callbacks[1].receive({ native_code = 36, mods = {} })
			print("INDEPENDENT_TERMINAL_CANCEL", tostring(recursive), "ACK", tostring(accepted), "CAPTURED", captured, "CANCELS", cancels)
			window.close()
			eq(recursive, true, "getter cancellation has original native retirement acknowledgement")
			eq(captured, 0, "cancelled request must not cross terminal position emit")
		end)
	end)
end
