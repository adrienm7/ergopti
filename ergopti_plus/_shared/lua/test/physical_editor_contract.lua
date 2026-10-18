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
	helpers.describe("Optional physical position emission enrollment", function()
		local function fixture()
			local canonical = {}
			local state = { native_calls = 0, emitted = 0, cancels = 0, active = nil }
			local options = { model = Model, parameter_section = "gesture_parameters", positions = {},
				catalogue = { is_assignable = function(action) return action == "none" end,
					get_action_parameter_spec = function() end, validate_action_parameter = function() return false end,
					split_action_parameter_key = function() end },
				capture = function() return { assignments = {}, parameters = {} }, canonical end,
				current = function(receipt) return rawequal(receipt, canonical) end,
				commit = function() error("position observation cannot publish") end,
				picker = function() return false end, label = function(action) return action end,
				emit = function() return true end, position_field = "evdev",
				position_available = function() return true end }
			options.emit_position = function(packet)
				state.emitted = state.emitted + 1; state.packet = packet; return true
			end
			options.capture_position = function(current, receive)
				state.native_calls = state.native_calls + 1
				state.current, state.receive, state.active = current, receive, {}
				return state.active
			end
			options.cancel_position = function(token)
				state.cancels = state.cancels + 1
				return rawequal(token, state.active)
			end
			state.options, state.owner = options, Editor.new(options)
			return state
		end
		helpers.it("missing emission port refuses advertisement and enrollment", function()
			local s = fixture(); s.options.emit_position = nil
			eq(s.owner.open().capture, false, "no emission port is offered")
			eq(s.owner.capture_position({ request_id = 1 }), false, "missing emission port refuses request")
			eq(s.native_calls, 0, "no native resource is acquired without emission")
			eq(s.owner.close(), true, "unarmed session closes without native debt")
			eq(s.cancels, 0, "no absent token is cancelled")
		end)
		helpers.it("noncallable emission ports refuse advertisement and enrollment", function()
			for _, port in ipairs({ false, "not callable", {} }) do
				local s = fixture(); s.options.emit_position = port
				eq(s.owner.open().capture, false, "noncallable emission port is not offered")
				eq(s.owner.capture_position({ request_id = 2 }), false, "noncallable emission port refuses request")
				eq(s.native_calls, 0, "noncallable emission acquires no resource")
				eq(s.owner.close(), true)
			end
		end)
		helpers.it("complete emission port retains actual capture and exact retirement", function()
			local s = fixture()
			eq(s.owner.open().capture, true)
			eq(s.owner.capture_position({ request_id = 3 }), true)
			eq(s.native_calls, 1)
			eq(s.receive({ native_code = 36, mods = {} }), true)
			eq(s.emitted, 1); eq(s.packet.code, "KeyJ"); eq(s.packet.request_id, 3)
			eq(s.owner.close(), true); eq(s.cancels, 1, "original token is retired")
		end)
		helpers.it("capture callback removal cannot advertise emission", function()
			local s = fixture(); local original = s.options.capture
			s.options.capture = function() s.options.emit_position = nil; return original() end
			eq(s.owner.open().capture, false); eq(s.owner.capture_position({ request_id = 4 }), false)
			eq(s.native_calls, 0); eq(s.owner.close(), true)
		end)
		helpers.it("availability callback removal cannot advertise emission", function()
			local s = fixture()
			s.options.position_available = function() s.options.emit_position = false; return true end
			eq(s.owner.open().capture, false); eq(s.owner.capture_position({ request_id = 5 }), false)
			eq(s.native_calls, 0); eq(s.owner.close(), true)
		end)
		helpers.it("last open currency callback removal cannot advertise emission", function()
			local s = fixture(); local original = s.options.current; local last = false
			s.options.position_available = function() last = true; return true end
			s.options.current = function(receipt)
				if last then s.options.emit_position = nil end
				return original(receipt)
			end
			eq(s.owner.open().capture, false); eq(s.owner.capture_position({ request_id = 6 }), false)
			eq(s.native_calls, 0); eq(s.owner.close(), true)
		end)
		helpers.it("intake currency callback removal refuses before native enrollment", function()
			local s = fixture(); eq(s.owner.open().capture, true); local original = s.options.current
			s.options.current = function(receipt) s.options.emit_position = nil; return original(receipt) end
			eq(s.owner.capture_position({ request_id = 7 }), false)
			eq(s.native_calls, 0); eq(s.cancels, 0); eq(s.owner.close(), true)
		end)
		helpers.it("post-enrollment currency removal retires the exact original token", function()
			local s = fixture(); s.owner.open(); local original = s.options.capture_position
			s.options.capture_position = function(current, receive)
				local token = original(current, receive)
				s.options.emit_position = nil
				return token
			end
			eq(s.owner.capture_position({ request_id = 8 }), false)
			eq(s.native_calls, 1); eq(s.cancels, 1); eq(s.current(), false)
			eq(s.receive({ native_code = 36, mods = {} }), false); eq(s.emitted, 0)
			eq(s.owner.close(), true); eq(s.cancels, 1)
		end)
		helpers.it("delivery currency callback removal never calls the removed emitter", function()
			local s = fixture(); s.owner.open(); eq(s.owner.capture_position({ request_id = 9 }), true)
			local original = s.options.current
			s.options.current = function(receipt) s.options.emit_position = nil; return original(receipt) end
			eq(s.receive({ native_code = 36, mods = {} }), false)
			eq(s.current(), false, "existing native currency guard observes missing emission")
			eq(s.emitted, 0); eq(s.owner.close(), true); eq(s.cancels, 1)
		end)
		helpers.it("callable replacement remains within the existing optional port contract", function()
			local s = fixture(); s.owner.open(); local replacement_calls = 0
			s.options.emit_position = function(packet) replacement_calls = replacement_calls + 1; return packet.code == "KeyJ" end
			eq(s.owner.capture_position({ request_id = 10 }), true)
			eq(s.receive({ native_code = 36, mods = {} }), true)
			eq(replacement_calls, 1); eq(s.emitted, 0); eq(s.owner.close(), true)
		end)
		helpers.it("emission enrollment does not expand availability policy", function()
			local s = fixture()
			s.options.position_available = function() return false end
			eq(s.owner.open().capture, false, "existing advertisement policy is retained")
			eq(s.owner.capture_position({ request_id = 11 }), true, "existing intake policy is unchanged")
			eq(s.owner.close(), true); eq(s.native_calls, 1); eq(s.cancels, 1)
		end)
	end)
	helpers.describe("Selected message acknowledgement and label freshness", function()
		local function fixture()
			local state = { receipt = {}, writes = 0, emitted = 0, emit_result = true }
			local options = { model = Model, parameter_section = "gesture_parameters", positions = {},
				catalogue = { is_assignable = function(action) return action == "none" or action == "copy" end,
					get_action_parameter_spec = function() end, validate_action_parameter = function() return false end,
					split_action_parameter_key = function() end },
				capture = function() return { assignments = {}, parameters = {} }, state.receipt end,
				current = function(receipt) return rawequal(receipt, state.receipt) end,
				commit = function(_, receipt)
					eq(receipt, state.receipt, "publication uses the original captured source")
					state.writes = state.writes + 1; return true
				end,
				picker = function(_, _, callback) state.callback = callback; return true end,
				label = function(action) if state.on_label then state.on_label() end; return action end,
				page_current = function() return true end, translate = function(key) return key end,
				close = function() return true end }
			local function selected(packet)
				state.emitted, state.packet = state.emitted + 1, packet
				if state.on_emit then state.on_emit() end
				return state.emit_result
			end
			options.emit = selected
			options.send = function(name, packet)
				if name == "selected" then return selected(packet) end
				state.message, state.result = name, packet; return true
			end
			state.options, state.owner = options, Editor.new(options)
			return state
		end
		local function choose(state)
			eq(type(state.owner.open()), "table", "actual editor captures the original source")
			eq(state.owner.choose({ code = "KeyJ", mods = {}, request_id = 1 }), true)
		end
		helpers.it("true selected acknowledgement admits the exact editor and Window draft", function()
			local s = fixture(); choose(s)
			eq(s.callback("copy"), true); eq(s.emitted, 1); eq(s.writes, 0)
			eq(s.owner.save(s.packet.token).committed, true); eq(s.writes, 1)
			s = fixture(); local window = Window.new(s.options)
			eq(window.receive({ action = "ready" }), true)
			eq(window.receive({ action = "choose", request = { code = "KeyJ", mods = {}, request_id = 1 } }), true)
			eq(s.callback("copy"), true); eq(s.emitted, 1); eq(s.writes, 0)
			eq(window.receive({ action = "save", token = s.packet.token }), true)
			eq(s.result.committed, true); eq(s.writes, 1); eq(window.close(), true)
		end)
		helpers.it("false nil and nonliteral selected acknowledgements never admit a savable draft", function()
			for _, outcome in ipairs({ "false", "nil", "string", "table" }) do
				local s = fixture(); choose(s)
				if outcome == "false" then s.emit_result = false
				elseif outcome == "nil" then s.emit_result = nil
				elseif outcome == "string" then s.emit_result = "true"
				else s.emit_result = {} end
				eq(s.callback("copy"), false, "only literal true acknowledges delivery")
				eq(s.emitted, 1); eq(s.owner.save(s.packet.token).committed, false); eq(s.writes, 0)
				s.emit_result = true
				eq(s.callback("copy"), true, "same current picker may retry the refused message")
				eq(s.owner.save(s.packet.token).committed, true); eq(s.writes, 1)
			end
		end)
		helpers.it("actual Window false selected transport refuses publication", function()
			local s = fixture(); local window = Window.new(s.options)
			eq(window.receive({ action = "ready" }), true)
			eq(window.receive({ action = "choose", request = { code = "KeyJ", mods = {}, request_id = 1 } }), true)
			s.emit_result = false; eq(s.callback("copy"), false)
			eq(s.emitted, 1); eq(window.receive({ action = "save", token = s.packet.token }), true)
			eq(s.result.committed, false); eq(s.writes, 0); eq(window.close(), true)
		end)
		helpers.it("throwing selected transport leaves no admitted draft", function()
			local s = fixture(); choose(s)
			s.on_emit = function() error("controlled selected transport refusal") end
			eq(s.callback("copy"), false); eq(s.emitted, 1)
			s.on_emit = nil
			eq(s.owner.save(s.packet.token).committed, false); eq(s.writes, 0)
		end)
		helpers.it("throwing label leaves no emitted message or admitted draft", function()
			local s = fixture(); choose(s)
			s.on_label = function() error("controlled label refusal") end
			eq(s.callback("copy"), false); eq(s.emitted, 0)
			s.on_label = nil
			eq(s.owner.save(1).committed, false, "unissued page token cannot publish")
			eq(s.writes, 0)
		end)
		helpers.it("label source revocation prevents a stale selected message", function()
			local s = fixture(); choose(s); local original = s.receipt
			s.on_label = function() s.receipt = {} end
			eq(s.callback("copy"), false); eq(s.emitted, 0, "label callback precedes the final pre-send source join")
			s.on_label, s.receipt = nil, original
			eq(s.owner.save(1).committed, false, "failed callback never admitted a draft")
			eq(s.writes, 0)
		end)
		helpers.it("label page retirement prevents a stale selected message", function()
			local s = fixture(); choose(s)
			s.on_label = function() eq(s.owner.close(), true, "original page retires during label callback") end
			eq(s.callback("copy"), false); eq(s.emitted, 0)
			eq(s.owner.save(1).committed, false); eq(s.writes, 0)
		end)
		helpers.it("true transport with source revocation never admits the draft", function()
			local s = fixture(); choose(s); local original = s.receipt
			s.on_emit = function() s.receipt = {} end
			eq(s.callback("copy"), false); eq(s.emitted, 1)
			s.on_emit, s.receipt = nil, original
			eq(s.owner.save(s.packet.token).committed, false, "ACK alone does not admit a revoked-source draft")
			eq(s.writes, 0)
		end)
		helpers.it("selected transport cannot reenter Save before acknowledgement", function()
			local s = fixture(); choose(s); local nested
			s.on_emit = function() nested = s.owner.save(s.packet.token).committed end
			eq(s.callback("copy"), true); eq(nested, false); eq(s.writes, 0)
			eq(s.owner.save(s.packet.token).committed, true); eq(s.writes, 1)
		end)
	end)
	helpers.describe("Shared physical editor publication refresh", function()
		local function fixture()
			local state = { receipt = {}, assignments = {}, writes = 0, messages = {}, refresh_labels = 0 }
			local options = { model = Model, parameter_section = "gesture_parameters", positions = {},
				catalogue = { is_assignable = function(action) return action == "copy" or action == "none" end,
					get_action_parameter_spec = function() end, validate_action_parameter = function() return false end,
					split_action_parameter_key = function(key) return key:match("^(keyboard__.+)__(.+)$") end },
				capture = function()
					local assignments = {}; for slot, action in pairs(state.assignments) do assignments[slot] = action end
					return { assignments = assignments, parameters = { future = "preserved" } }, state.receipt
				end,
				current = function(receipt) return rawequal(receipt, state.receipt) end,
				commit = function(rows, receipt)
					eq(receipt, state.receipt, "publication carries the original current receipt")
					for _, row in ipairs(rows) do
						eq(row.section, "shortcuts.keyboard", "ordinary copy needs no parameter writes")
						state.assignments[row.key] = row.delete and nil or row.value
					end
					state.writes = state.writes + 1; state.receipt = {}; return true
				end,
				picker = function(_, _, callback) state.callback = callback; return true end,
				label = function(action)
					if state.writes > 0 then
						state.refresh_labels = state.refresh_labels + 1
						if state.on_refresh_label then state.on_refresh_label() end
					end
					return "label:" .. action
				end,
				emit = function(packet) state.selected = packet; return true end,
				page_current = function() return true end, translate = function(key) return key end,
				send = function(name, packet)
					state.messages[#state.messages + 1] = { name = name, packet = packet }
					if name == "selected" then state.selected = packet end
					return true
				end,
				close = function() return true end }
			state.options, state.owner = options, Editor.new(options)
			return state
		end
		local function choose(state, window)
			if window then
				eq(window.receive({ action = "ready" }), true)
				eq(window.receive({ action = "choose", request = { code = "KeyJ", mods = {}, request_id = 1 } }), true)
			else
				eq(type(state.owner.open()), "table")
				eq(state.owner.choose({ code = "KeyJ", mods = {}, request_id = 1 }), true)
			end
			eq(state.callback("copy"), true); eq(state.writes, 0); eq(state.refresh_labels, 0)
		end
		helpers.it("publication refresh rejects source revoked by its label callback", function()
			local s = fixture(); choose(s)
			s.on_refresh_label = function() s.receipt = {} end
			local result = s.owner.save(s.selected.token)
			eq(s.writes, 1); eq(s.refresh_labels, 1); eq(result.committed, true, "durable publication remains truthful")
			eq(s.assignments.physical_none_KeyJ, "copy", "committed assignment is not rolled back")
			s = fixture(); local window = Window.new(s.options); choose(s, window)
			s.on_refresh_label = function() s.receipt = {} end
			eq(window.receive({ action = "save", token = s.selected.token }), true)
			local delivered = s.messages[#s.messages]
			eq(delivered.name, "result"); eq(delivered.packet.committed, true)
			eq({ editor = result.refreshed, window = delivered.packet.refreshed },
				{ editor = false, window = false }, "both actual owners refuse stale refreshed entries")
			eq(result.refreshed, false, "post-label source revocation refuses the refreshed inventory")
			eq(result.entries, nil, "stale entries are never returned as refreshed")
			eq(delivered.packet.refreshed, false); eq(delivered.packet.entries, nil)
			eq(s.writes, 1); eq(s.refresh_labels, 1); eq(window.close(), true)
		end)
		helpers.it("publication refresh retains a genuine current labelled inventory", function()
			for _, through_window in ipairs({ false, true }) do
				local s = fixture(); local window = through_window and Window.new(s.options) or nil
				choose(s, window)
				local result
				if window then
					eq(window.receive({ action = "save", token = s.selected.token }), true)
					result = s.messages[#s.messages].packet
				else result = s.owner.save(s.selected.token) end
				eq(result.committed, true); eq(result.refreshed, true); eq(#result.entries, 1)
				eq(result.entries[1].slot, "physical_none_KeyJ"); eq(result.entries[1].action, "copy")
				eq(result.entries[1].label, "label:copy"); eq(s.writes, 1); eq(s.refresh_labels, 1)
				if window then eq(window.close(), true) else eq(s.owner.close(), true) end
			end
		end)
		helpers.it("publication refresh rejects a session closed by its label callback", function()
			local s = fixture(); choose(s); local closed
			s.on_refresh_label = function() closed = s.owner.close() end
			local result = s.owner.save(s.selected.token)
			eq(closed, true); eq(s.writes, 1); eq(s.refresh_labels, 1); eq(result.committed, true)
			eq(result.refreshed, false, "retired editor cannot attest a refreshed display")
			eq(result.entries, nil); eq(s.owner.choose({ code = "KeyK", mods = {}, request_id = 2 }), false)
			s = fixture(); local window = Window.new(s.options); choose(s, window)
			local messages = #s.messages
			s.on_refresh_label = function() window.retire() end
			eq(window.receive({ action = "save", token = s.selected.token }), false)
			eq(s.writes, 1); eq(s.refresh_labels, 1); eq(#s.messages, messages, "retired native page receives no result")
		end)
	end)
	helpers.describe("Physical editor retained request cancellation", function()
		local function fixture()
			local s = { receipt = {}, original_calls = 0, foreign_calls = 0, acquired = 0, emitted = 0 }
			local options = { model = Model, parameter_section = "gesture_parameters", positions = {},
				catalogue = { is_assignable = function(action) return action == "none" end,
					get_action_parameter_spec = function() end, validate_action_parameter = function() return false end,
					split_action_parameter_key = function() end },
				capture = function() return { assignments = {}, parameters = {} }, s.receipt end,
				current = function(receipt) return rawequal(receipt, s.receipt) end,
				commit = function() error("observation retirement never publishes") end,
				picker = function() return false end, label = function(action) return action end,
				emit = function() return true end, position_field = "evdev",
				position_available = function() return true end }
			options.emit_position = function() s.emitted = s.emitted + 1; return true end
			options.capture_position = function(current, receive)
				s.acquired = s.acquired + 1
				s.active, s.native_current, s.receive = {}, current, receive
				if s.on_capture then s.on_capture() end
				return s.active
			end
			options.cancel_position = function(token)
				s.original_calls = s.original_calls + 1
				eq(token, s.active, "the original cancellation receives its exact acquired token")
				if s.on_cancel then s.on_cancel() end
				if s.refuse then return false end
				s.active = nil
				return true
			end
			s.foreign = function() s.foreign_calls = s.foreign_calls + 1; return true end
			s.original, s.options = options.cancel_position, options
			s.owner = Editor.new(options)
			eq(type(s.owner.open()), "table")
			return s
		end
		local function enroll(s, request)
			eq(s.owner.capture_position({ request_id = request or 1 }), true)
			eq(type(s.active), "table")
		end
		helpers.it("foreign success cannot replace the acquired request cancellation", function()
			local s = fixture(); enroll(s)
			s.options.cancel_position = s.foreign
			eq(s.owner.close(), true); eq(s.original_calls, 1); eq(s.foreign_calls, 0)
			eq(s.active, nil, "success requires actual retirement by the acquired request owner")
			eq(s.owner.close(), true); eq(s.original_calls, 1, "completed request is not retired twice")
		end)
		helpers.it("removed noncallable and throwing replacements do not lose original retirement", function()
			for _, kind in ipairs({ "nil", "false", "throw" }) do
				local s = fixture(); enroll(s)
				if kind == "nil" then s.options.cancel_position = nil
				elseif kind == "false" then s.options.cancel_position = false
				else s.options.cancel_position = function() s.foreign_calls = s.foreign_calls + 1; error("foreign callback") end end
				eq(s.owner.close(), true); eq(s.original_calls, 1); eq(s.foreign_calls, 0); eq(s.active, nil)
			end
		end)
		helpers.it("original refusal retains the exact token and original retry port", function()
			local s = fixture(); enroll(s); local token = s.active
			s.refuse = true; s.options.cancel_position = s.foreign
			eq(s.owner.close(), false); eq(s.original_calls, 1); eq(s.active, token); eq(s.foreign_calls, 0)
			eq(s.receive({ native_code = 36, mods = {} }), false, "closed page cannot emit during retirement debt")
			s.refuse = false
			eq(s.owner.close(), true); eq(s.original_calls, 2); eq(s.active, nil); eq(s.foreign_calls, 0)
		end)
		helpers.it("original exception retains the request for the same cancellation retry", function()
			local s = fixture(); enroll(s); local token = s.active
			s.on_cancel = function() error("original controlled refusal") end
			s.options.cancel_position = nil
			eq(s.owner.close(), false); eq(s.original_calls, 1); eq(s.active, token)
			s.on_cancel = nil
			eq(s.owner.close(), true); eq(s.original_calls, 2); eq(s.active, nil)
		end)
		helpers.it("capture constructor replacement cannot substitute the retained cancellation", function()
			local s = fixture();
			s.on_capture = function() s.options.cancel_position = s.foreign end
			enroll(s)
			eq(s.owner.close(), true); eq(s.original_calls, 1); eq(s.foreign_calls, 0); eq(s.active, nil)
		end)
		helpers.it("replacement before enrollment remains the optional port for that request", function()
			local s = fixture(); local selected_calls = 0
			s.options.cancel_position = function(token)
				selected_calls = selected_calls + 1; eq(token, s.active); s.active = nil; return true
			end
			enroll(s); s.options.cancel_position = s.foreign
			eq(s.owner.close(), true); eq(selected_calls, 1); eq(s.original_calls, 0)
			eq(s.foreign_calls, 0); eq(s.active, nil)
		end)
		helpers.it("retained cancellation refuses recursive close and successor enrollment", function()
			local s = fixture(); enroll(s); local nested_close, nested_capture
			s.on_cancel = function()
				nested_close = s.owner.close()
				nested_capture = s.owner.capture_position({ request_id = 2 })
			end
			s.options.cancel_position = s.foreign
			eq(s.owner.close(), true); eq(nested_close, false); eq(nested_capture, false)
			eq(s.original_calls, 1); eq(s.foreign_calls, 0); eq(s.acquired, 1); eq(s.active, nil)
		end)
		helpers.it("prior retirement removing the next port refuses before another acquisition", function()
			local s = fixture(); enroll(s)
			s.on_cancel = function() s.options.cancel_position = nil end
			eq(s.owner.capture_position({ request_id = 2 }), false)
			eq(s.original_calls, 1); eq(s.acquired, 1, "no resource is acquired without its cancellation port")
			eq(s.active, nil); eq(s.owner.close(), true)
		end)
		helpers.it("successive requests retain separate original cancellation functions", function()
			local s = fixture(); enroll(s); local stale = s.receive
			eq(s.owner.cancel_position(), true); eq(s.original_calls, 1)
			local next_calls = 0
			s.options.cancel_position = function(token) next_calls = next_calls + 1; eq(token, s.active); s.active = nil; return true end
			enroll(s, 2); local successor = s.active; s.options.cancel_position = s.foreign
			eq(stale({ native_code = 36, mods = {} }), false); eq(s.active, successor)
			eq(s.owner.close(), true); eq(next_calls, 1); eq(s.original_calls, 1)
			eq(s.foreign_calls, 0); eq(s.acquired, 2); eq(s.active, nil)
		end)
		helpers.it("post-constructor source refusal retires through the acquired request port", function()
			local s = fixture()
			s.on_capture = function() s.options.cancel_position = s.foreign; s.receipt = {} end
			eq(s.owner.capture_position({ request_id = 1 }), false)
			eq(s.acquired, 1); eq(s.original_calls, 1); eq(s.foreign_calls, 0); eq(s.active, nil)
			eq(s.owner.close(), true); eq(s.original_calls, 1)
		end)
	end)

	helpers.describe("Shared Window original retirement acknowledgements", function()
		-- These are controlled session-port observations, not native input or page evidence.
		local function fixture()
			local s = { canonical = {}, active = nil, page = true, cancel_mode = true,
				native_mode = true, cancel_calls = 0, native_calls = 0, editor_calls = 0,
				picker_calls = 0, writes = 0, foreign_calls = 0 }
			local function answer(mode)
				if mode == "throw" then error("Controlled original retirement refusal") end
				if mode == "nil" then return nil end
				if mode == "nonboolean" then return 1 end
				return mode
			end
			local actions = { is_assignable = function(action) return action == "none" end,
				get_action_parameter_spec = function() end, validate_action_parameter = function() return false end,
				split_action_parameter_key = function() end }
			local options = { model = Model, catalogue = actions, parameter_section = "gesture_parameters",
				positions = {}, label = function(action) return action end,
				capture = function() return { assignments = {}, parameters = {} }, s.canonical end,
				current = function(receipt) return rawequal(receipt, s.canonical) end,
				commit = function() s.writes = s.writes + 1; return true end,
				picker = function() s.picker_calls = s.picker_calls + 1; return true end,
				emit = function() return true end, send = function() return true end,
				translate = function(key) return key end, position_field = "evdev",
				position_available = function() return true end,
				page_current = function()
					if s.on_page then s.on_page(s) end
					return s.page
				end,
				capture_position = function(_, receive)
					s.active, s.receive = {}, receive
					return s.active
				end,
				cancel_position = function(token)
					eq(rawequal(token, s.active), true, "cancel carries the original observation token")
					s.cancel_calls = s.cancel_calls + 1
					if s.on_cancel then s.on_cancel(s) end
					local acknowledged = answer(s.cancel_mode)
					if acknowledged == true then s.active = nil end
					return acknowledged
				end,
				close = function()
					s.native_calls = s.native_calls + 1
					if s.on_native then s.on_native(s) end
					local acknowledged = answer(s.native_mode)
					if acknowledged == true then s.page = false end
					return acknowledged
				end }
			-- Count the actual Editor close body without replacing any of its outcomes.
			-- Restore the constructor even if the real Window constructor refuses.
			local original_new = Editor.new
			Editor.new = function(ports)
				local owner = original_new(ports)
				local original_close = owner.close
				owner.close = function() s.editor_calls = s.editor_calls + 1; return original_close() end
				return owner
			end
			local called, window = pcall(Window.new, options)
			Editor.new = original_new
			eq(called, true, "real Window constructor accepts the complete controlled ports")
			s.window, s.options = window, options
			eq(window.receive({ action = "ready" }), true)
			eq(window.receive({ action = "capture_position", request = { request_id = 1 } }), true)
			eq(type(s.active), "table")
			return s
		end
		for _, mode in ipairs({ false, "throw", "nil", "nonboolean" }) do
			helpers.it("(physical-window-close) original cancellation refusal retains both owners: " .. tostring(mode), function()
				local s = fixture(); local token = s.active; s.cancel_mode = mode
				eq(s.window.close(), false, "unacknowledged observation cannot report a closed Window")
				eq(s.editor_calls, 1); eq(s.cancel_calls, 1); eq(s.native_calls, 0)
				eq(rawequal(s.active, token), true); eq(s.page, true)
				eq(s.receive({ native_code = 36, mods = {} }), false, "closing observation cannot emit after refusal")
				eq(s.window.receive({ action = "choose", request = { code = "KeyJ", mods = {}, request_id = 2 } }), false)
				s.cancel_mode = true
				eq(s.window.receive({ action = "close" }), true, "close channel retries its exact retained observation")
				eq(s.editor_calls, 2); eq(s.cancel_calls, 2); eq(s.native_calls, 1); eq(s.active, nil)
				eq(s.window.close(), false, "completed native page is not closed twice")
				eq(s.picker_calls, 0); eq(s.writes, 0)
			end)
		end
		for _, mode in ipairs({ false, "throw", "nil", "nonboolean" }) do
			helpers.it("(physical-window-close) native refusal retains prior Editor acknowledgement: " .. tostring(mode), function()
				local s = fixture(); s.native_mode = mode
				eq(s.window.close(), false)
				eq(s.editor_calls, 1); eq(s.cancel_calls, 1); eq(s.native_calls, 1); eq(s.active, nil)
				eq(s.window.receive({ action = "save", token = 1 }), false, "retired draft cannot publish during native debt")
				eq(s.window.receive({ action = "capture_position", request = { request_id = 2 } }), false)
				s.native_mode = true
				eq(s.window.receive({ action = "close" }), true)
				eq(s.editor_calls, 1, "positive Editor acknowledgement is never repeated")
				eq(s.cancel_calls, 1); eq(s.native_calls, 2); eq(s.picker_calls, 0); eq(s.writes, 0)
			end)
		end
		helpers.it("(physical-window-close) native recursive retirement cannot repeat Editor or native close", function()
			local s = fixture(); local retired, recursive, routed
			s.on_native = function()
				retired = s.window.retire(); recursive = s.window.close()
				routed = s.window.receive({ action = "close" })
			end
			eq(s.window.close(), true); eq(retired, true); eq(recursive, false); eq(routed, false)
			eq(s.editor_calls, 1); eq(s.cancel_calls, 1); eq(s.native_calls, 1); eq(s.active, nil)
		end)
		helpers.it("(physical-window-close) cancellation callback cannot borrow a close or retire acknowledgement", function()
			local s = fixture(); local retired, recursive, routed
			s.on_cancel = function()
				retired = s.window.retire(); recursive = s.window.close()
				routed = s.window.receive({ action = "capture_position", request = { request_id = 2 } })
			end
			eq(s.window.close(), true); eq(retired, false); eq(recursive, false); eq(routed, false)
			eq(s.editor_calls, 1); eq(s.cancel_calls, 1); eq(s.native_calls, 1)
		end)
		helpers.it("(physical-window-close) first page getter is reserved before recursive close", function()
			local s = fixture(); local recursive
			s.on_page = function() s.on_page = nil; recursive = s.window.close() end
			eq(s.window.close(), true); eq(recursive, false)
			eq(s.editor_calls, 1); eq(s.cancel_calls, 1); eq(s.native_calls, 1)
		end)
		helpers.it("(physical-window-close) terminal getter retirement refuses native acquisition", function()
			local s = fixture()
			s.on_page = function() s.on_page = nil; eq(s.window.retire(), true) end
			eq(s.window.close(), false)
			eq(s.editor_calls, 1); eq(s.cancel_calls, 1); eq(s.native_calls, 0)
		end)
		helpers.it("(physical-window-close) native refusal retries only the original captured close port", function()
			local s = fixture(); s.native_mode = false
			eq(s.window.close(), false)
			s.options.close = function() s.foreign_calls = s.foreign_calls + 1; return true end
			s.native_mode = true
			eq(s.window.close(), true)
			eq(s.foreign_calls, 0); eq(s.native_calls, 2); eq(s.editor_calls, 1); eq(s.cancel_calls, 1)
		end)
		helpers.it("(physical-window-close) external page retirement retries observation without granting native acknowledgement", function()
			local s = fixture(); local token = s.active; s.cancel_mode = false
			eq(s.window.retire(), false); eq(rawequal(s.active, token), true)
			eq(s.window.receive({ action = "save", token = 1 }), false)
			s.cancel_mode = true
			eq(s.window.retire(), true); eq(s.window.retire(), true)
			eq(s.editor_calls, 2); eq(s.cancel_calls, 2); eq(s.native_calls, 0); eq(s.active, nil)
			eq(s.window.close(), false, "external page revocation is not a close-request capability")
		end)
	end)
	helpers.describe("Physical editor serialized optional old identity", function()
		local Json = require("json")
		-- These literals are fixed independently of the browser implementation.
		-- The browser controls require its actual serialized packets to match them.
		local add_wire = '{"action":"choose","request":{"code":"KeyJ","mods":{"ctrl":true,"alt":false,"shift":false,"super":false},"request_id":3}}'
		local edit_wire = '{"action":"choose","request":{"code":"KeyK","mods":{"ctrl":true,"alt":false,"shift":false,"super":false},"previous_slot":"physical_ctrl_KeyK","request_id":8}}'
		local function clone(value)
			if type(value) ~= "table" then return value end
			local result = {}; for key, item in pairs(value) do result[key] = clone(item) end
			return result
		end
		local function fixture(previous)
			local state = { receipt = {}, assignments = { other_owner = "copy" },
				parameters = { unknown_owner = "retain" }, picks = 0, writes = 0, messages = {}, page = true }
			if previous then state.assignments.physical_ctrl_KeyK = "none" end
			local actions = { is_assignable = function(action) return action == "none" or action == "copy" end,
				get_action_parameter_spec = function() end, validate_action_parameter = function() return false end,
				split_action_parameter_key = function(key) return key:match("^(keyboard__.+)__(.+)$") end }
			state.window = Window.new({ model = Model, catalogue = actions, parameter_section = "gesture_parameters",
				positions = {}, label = function(action) return action end, translate = function(key) return key end,
				capture = function() return { assignments = clone(state.assignments), parameters = clone(state.parameters) }, state.receipt end,
				current = function(receipt) return rawequal(receipt, state.receipt) end,
				page_current = function() return state.page end,
				picker = function(binding, action, callback)
					state.picks = state.picks + 1; state.binding, state.action, state.confirm = binding, action, callback
					return true
				end,
				emit = function() return true end,
				send = function(name, data) state.messages[name] = data; return true end,
				commit = function(rows, receipt)
					eq(rawequal(receipt, state.receipt), true, "wire selection retains original canonical receipt")
					state.writes = state.writes + 1; state.rows = clone(rows)
					for _, row in ipairs(rows) do
						local map = row.section == "shortcuts.keyboard" and state.assignments or state.parameters
						if row.delete then map[row.key] = nil else map[row.key] = row.value end
					end
					state.receipt = {}; return true
				end,
				close = function() state.page = false; return true end })
			eq(state.window.receive({ action = "ready" }), true, "actual shared intake opens from owned fixture source")
			return state
		end
		helpers.it("(physical-editor-wire) Add omission survives actual JSON decode and exact publication", function()
			local state = fixture(); local message = Json.decode(add_wire)
			eq(message.request.previous_slot, nil, "omission is actual absence after unchanged native JSON decode")
			eq(state.window.receive(message), true, "actual intake and Editor admit serialized Add")
			eq(state.picks, 1); eq(state.binding, "keyboard__physical_ctrl_KeyJ"); eq(state.writes, 0)
			eq(state.confirm("none"), true, "exact picker creates only a draft")
			eq(state.window.receive({ action = "save", token = state.messages.selected.token }), true)
			eq(state.messages.result.committed, true); eq(state.writes, 1)
			eq(state.rows, { { section = "shortcuts.keyboard", key = "physical_ctrl_KeyJ", value = "none", intent = "keyboard_assignment" } })
			eq(state.assignments.other_owner, "copy"); eq(state.parameters.unknown_owner, "retain")
			eq(state.window.close(), true)
		end)
		helpers.it("(physical-editor-wire) Edit retains exact prior identity through actual JSON and Editor", function()
			local state = fixture(true); local message = Json.decode(edit_wire)
			eq(message.request.previous_slot, "physical_ctrl_KeyK")
			eq(state.window.receive(message), true); eq(state.picks, 1)
			eq(state.binding, "keyboard__physical_ctrl_KeyK"); eq(state.action, "none"); eq(state.writes, 0)
			eq(state.confirm("copy"), true)
			eq(state.window.receive({ action = "save", token = state.messages.selected.token }), true)
			eq(state.messages.result.committed, true); eq(state.writes, 1)
			eq(state.rows, { { section = "shortcuts.keyboard", key = "physical_ctrl_KeyK", value = "copy", intent = "keyboard_assignment" } })
			eq(state.assignments.other_owner, "copy"); eq(state.parameters.unknown_owner, "retain")
			eq(state.window.close(), true)
		end)
		local refusals = {
			{ "original-null", '{"action":"choose","request":{"code":"KeyJ","mods":{"ctrl":true},"previous_slot":null,"request_id":3}}' },
			{ "empty-object", '{"action":"choose","request":{"code":"KeyJ","mods":{"ctrl":true},"previous_slot":{},"request_id":3}}' },
			{ "wrong-scope", '{"action":"choose","request":{"code":"KeyJ","mods":{"ctrl":true},"previous_slot":"foreign_owner","request_id":3}}' },
			{ "absent-old-entry", edit_wire },
			{ "outer-authority", '{"action":"choose","source":"foreign","request":{"code":"KeyJ","mods":{"ctrl":true},"request_id":3}}' },
			{ "request-authority", '{"action":"choose","request":{"code":"KeyJ","mods":{"ctrl":true},"source":"foreign","request_id":3}}' },
		}
		for _, refusal in ipairs(refusals) do
			helpers.it("(physical-editor-wire) serialized " .. refusal[1] .. " remains refused without picker or write", function()
				local state = fixture(); local message = Json.decode(refusal[2])
				if refusal[1] == "original-null" or refusal[1] == "empty-object" then
					eq(type(message.request.previous_slot), "table", "legacy null cannot be authenticated as absence")
				end
				eq(state.window.receive(message), false); eq(state.picks, 0); eq(state.writes, 0)
				eq(state.assignments, { other_owner = "copy" }); eq(state.parameters, { unknown_owner = "retain" })
				eq(state.window.close(), true)
			end)
		end
		helpers.it("(physical-editor-wire) inherited request fields remain refused without picker or write", function()
			local state = fixture(); local message = Json.decode(add_wire)
			setmetatable(message.request, { __index = { source = "foreign" } })
			eq(state.window.receive(message), false); eq(state.picks, 0); eq(state.writes, 0)
			eq(state.window.close(), true)
		end)
	end)
end
