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
end
