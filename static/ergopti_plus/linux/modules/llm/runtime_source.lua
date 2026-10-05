--- modules/llm/runtime_source.lua

--- ==============================================================================
--- MODULE: Linux Acknowledged Ollama Runtime Source
--- DESCRIPTION:
--- Binds existing profile writes to exact prepared source images, native
--- revisions and one-shot application ownership receipts.
--- ==============================================================================

local M={}
local function same_source(a,b)
	return type(a)=='table' and type(b)=='table' and a.status==b.status and a.content==b.content
end
local function copy(a)local r={};for k,v in pairs(a)do r[k]=v end;return r end
function M.new(deps)
	local backend_key=deps.backend_key
	assert(type(backend_key)=='string' and deps.manifest.find_entry_by_path(backend_key),
		'runtime source requires the engine-owned backend declaration')
	local KEYS={backend_key,'llm.models.ollama','llm.enabled'}
	local p=deps.preferences
	local get_many,generation,admit=p.get_many,p.generation,p.admit
	local revision_current=p.is_current_revision
	local enable,disable,is_enabled=deps.profiles.enable,deps.profiles.disable,deps.profiles.is_enabled
	local prepare,operation=deps.writer.prepare_batch,deps.manifest.sparse_operation
	local native_get,native_publish,native_restore=deps.engine.state,deps.engine.publish_enabled,deps.engine.restore_disabled
	local native_admit=deps.engine.admit_write
	local path=deps.path
	assert(type(path)=='string' and path~='', 'runtime preference path unavailable')
	for _,fn in ipairs({get_many,generation,admit,revision_current,enable,disable,is_enabled,prepare,operation,native_get,native_publish,native_restore,native_admit})do
		assert(type(fn)=='function','runtime source owner unavailable')
	end
	local records=setmetatable({}, {__mode='k'})
	local proofs=setmetatable({}, {__mode='k'})
	local applications=setmetatable({}, {__mode='k'})
	local source={}
	local function read_source()
		-- generation() itself rereads classified bytes. Bracket values with its
		-- private revisions; one bounded refresh permits an enabled/model-only
		-- edit without borrowing an older backend from another image.
		for _=1,2 do
			local before=generation()
			local values,image=get_many(KEYS)
			local revision=generation()
			if before==revision then return values,image,revision end
		end
		return nil,nil,nil,nil
	end
	local function read()
		local values,image,revision=read_source()
		if type(values)~='table' then return nil,nil,nil,nil end
		return values,image,revision,native_get()
	end
	local function available(state)
		return type(state)=='table' and state.paused==false and state.blocked==false
			and type(state.revision)=='number' and type(state.app_epoch)=='number' and admit()==true
	end
	local function identity(state,record,enabled)
		return available(state) and state.revision==record.native.revision
			and state.app_epoch==record.native.app_epoch and state.enabled==enabled
			and state.backend=='ollama' and state.origin==record.origin and state.model==record.model
	end
	local function unchanged(record)
		local values,image,revision,state=read()
		return identity(state,record,false) and is_enabled()==false and revision==record.preference_revision
			and values['llm.enabled']==false and values[backend_key]=='ollama'
			and values['llm.models.ollama']==record.model and same_source(image,record.image)
			and identity(native_get(),record,false) and generation()==revision
	end
	function source.capture()
		local values,image,revision,state=read()
		if not available(state) or state.enabled~=false or is_enabled()~=false or state.backend~='ollama'
			or values['llm.enabled']~=false or values[backend_key]~='ollama'
			or state.model~=values['llm.models.ollama'] or type(state.origin)~='string' then return nil end
		local handle={origin=state.origin}
		local record={origin=state.origin,model=state.model,image=copy(image),
			preference_revision=revision,native=copy(state)}
		records[handle]=record
		if not unchanged(record) then records[handle]=nil;return nil end
		return handle
	end
	function source.current(handle)
		local record=records[handle]
		return record~=nil and not record.writing and not record.retired and handle.origin==record.origin
			and unchanged(record) and records[handle]==record and not record.retired
	end
	--- Admits an error notice only for this exact source or its own saved image.
	--- @param handle table Originating opaque repair source.
	--- @return boolean current
	function source.diagnostic_current(handle)
		local record=records[handle]
		if not record or record.retired or handle.origin~=record.origin then return false end
		local values,image,revision,state=read()
		if type(values)~='table' or not available(state) or state.revision~=record.native.revision
			or state.app_epoch~=record.native.app_epoch or state.origin~=record.origin
			or state.backend~='ollama' or state.model~=record.model or values[backend_key]~='ollama'
			or values['llm.models.ollama']~=record.model then return false end
		local original=revision==record.preference_revision and same_source(image,record.image)
		local restored=record.compensated and revision==record.restored_revision and same_source(image,record.restored_image)
		local saved=record.candidate~=nil and revision==record.preference_revision+2
			and image.status=='ok' and image.content==record.candidate
		return (original or saved or restored) and not record.retired
	end
	function source.retire(handle)
		local record=records[handle];if record then record.retired=true end
		return true
	end
	-- Bind the source image, revisions and callbacks privately for one writer.
	-- observe_source performs all classified IO first. Only lexical preference
	-- owner/revision and profile checks follow; engine.admit_write finishes with
	-- lexical native owner/revision/app checks before Writer's native rename.
	local function final_admission(record,image,revision,native_enabled,profile_enabled)
		local expected=copy(image)
		local observe_source=function()
			local values,current,observed=read_source()
			return type(values)=='table' and same_source(current,expected)
				and observed==revision and values['llm.enabled']==profile_enabled
				and values[backend_key]=='ollama' and values['llm.models.ollama']==record.model
				and not record.retired and is_enabled()==profile_enabled and revision_current(revision)==true
		end
		local native_revision,app_epoch=record.native.revision,record.native.app_epoch
		return function()
			return native_admit(native_revision,app_epoch,native_enabled,observe_source)==true
		end
	end
	--- Compensates only this originating acknowledged enabled image.
	--- @param handle table Private originating source identity.
	--- @return boolean restored Existing profile/native owners acknowledged false.
	function source.compensate(handle)
		local record=records[handle]
		if not record or record.retired then return false end
		if record.compensated then return true end
		if not record.written then return record.write_unknown~=true end
		local values,image,revision,state=read()
		if type(values)~='table' or revision~=record.preference_revision+2 or image.status~='ok'
			or image.content~=record.candidate or values['llm.enabled']~=true
			or values[backend_key]~='ollama' or values['llm.models.ollama']~=record.model
			or is_enabled()~=true or not identity(state,record,record.native_ack==true)
			or not identity(native_get(),record,record.native_ack==true) or generation()~=revision then
			record.compensation='foreign_or_stale';return false
		end
		local ok,restored=pcall(disable,{status=image.status,content=image.content},
			final_admission(record,image,revision,record.native_ack==true,true))
		if not ok or restored~=true then record.compensation='writer_refused';return false end
		values,image,revision,state=read()
		if type(values)~='table' or values['llm.enabled']~=false or is_enabled()~=false
			or values[backend_key]~='ollama' or values['llm.models.ollama']~=record.model
			or revision~=record.preference_revision+4 or not identity(state,record,record.native_ack==true)
			or generation()~=revision then record.compensation='restore_context_changed';return false end
		if record.native_ack and native_restore(record.native.revision,record.native.app_epoch)~=true then
			record.compensation='native_restore_refused';return false
		end
		if not identity(native_get(),record,false) then record.compensation='native_restore_unknown';return false end
		record.compensated=true;record.compensation='restored'
		record.restored_image=copy(image);record.restored_revision=revision
		return true
	end
	function source.publish(handle,acknowledge)
		local record=records[handle]
		if not record or type(acknowledge)~='function' or not source.current(handle) then return false end
		local prepared,_,candidate,preimage=prepare(path,{operation('llm.enabled',true)},nil,record.image)
		if prepared~=true or type(candidate)~='string' or not same_source(preimage,record.image)
			or not source.current(handle) then return false end
		-- Keep this write owner reserved across profiles/storage/logger callbacks.
		record.candidate=candidate
		record.writing=true
		local succeeded,committed=pcall(enable,record.image,
			final_admission(record,record.image,record.preference_revision,false,false))
		if not succeeded or committed~=true then record.write_unknown=true;record.writing=false;return false end
		record.written=true
		if record.retired then record.writing=false;return false end
		local values,image,revision,state=read()
		-- One acknowledged preference write + one observed changed source. A
		-- same-byte extra write or independently observed image adds a revision.
		if type(values)~='table' or revision~=record.preference_revision+2 or image.status~='ok' or image.content~=candidate
			or values['llm.enabled']~=true or values[backend_key]~='ollama'
			or values['llm.models.ollama']~=record.model or is_enabled()~=true
			or not identity(state,record,false) or not identity(native_get(),record,false)
			or generation()~=revision then record.writing=false;return false end
		local published=native_publish(record.native.revision,record.native.app_epoch)
		record.native_ack=published==true
		if published~=true or record.retired then record.writing=false;return false end
		values,image,revision,state=read()
		if type(values)~='table' or revision~=record.preference_revision+2 or image.status~='ok' or image.content~=candidate
			or values['llm.enabled']~=true or values[backend_key]~='ollama'
			or values['llm.models.ollama']~=record.model or is_enabled()~=true
			or not identity(state,record,true) or not identity(native_get(),record,true)
			or generation()~=revision then record.writing=false;return false end
		local proof={}
		proofs[proof]={record=record,handle=handle,origin=record.origin,app_epoch=record.native.app_epoch,
			candidate=candidate,revision=revision,consumed=false}
		local ok,accepted=pcall(acknowledge,proof)
		record.writing=false
		return ok and accepted==true and not record.retired
	end
	function source.app_capture(proof,handle,runtime,origin)
		local receipt=proofs[proof]
		if not receipt or receipt.consumed or receipt.handle~=handle or receipt.origin~=origin
			or records[handle]~=receipt.record or receipt.record.retired or not receipt.record.writing then return nil end
		local values,image,revision,state=read()
		if not identity(state,receipt.record,true) or is_enabled()~=true
			or values['llm.enabled']~=true or image.status~='ok' or image.content~=receipt.candidate
			or revision~=receipt.revision or not identity(native_get(),receipt.record,true)
			or generation()~=revision or receipt.record.retired then return nil end
		local app={};receipt.consumed=true
		applications[app]={origin=origin,app_epoch=receipt.app_epoch,runtime=runtime}
		return app
	end
	function source.app_current(app,runtime,origin)
		local held=applications[app]
		if not held or held.runtime~=runtime or held.origin~=origin then return false end
		local values,_,_,state=read()
		if not available(state) or state.app_epoch~=held.app_epoch or state.origin~=held.origin
			or state.backend~='ollama' or values[backend_key]~='ollama' then return false end
		-- The app owns the service after handoff. Disabling master consent,
		-- changing model or retiring that enable ticket cannot kill this lease.
		local final=native_get()
		return available(final) and final.app_epoch==held.app_epoch and final.origin==held.origin
			and final.backend=='ollama' and applications[app]==held
	end
	return source
end
return M
