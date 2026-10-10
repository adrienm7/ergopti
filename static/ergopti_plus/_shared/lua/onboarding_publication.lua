--- _shared/lua/onboarding_publication.lua

--- ==============================================================================
--- MODULE: Wizard Publication Receiving
--- DESCRIPTION:
--- Keeps one wizard's genuine batch publication and compensation capability
--- through native release refusal, another Finish and native view disposal.
--- Uses the existing conditional file inverse; it grants no authority from
--- current bytes and never treats a foreign successor as its publication.
--- ==============================================================================

local M = {}

local function classified(content, status)
	return status == "absent" and content == nil
		or status == "ok" and type(content) == "string"
end

local function admitted(callback)
	local called, result = pcall(callback)
	return called and result == true
end

--- Owns the native handler stack before validation can invoke any provider.
--- This gate does not acknowledge publication or release physical debt.
--- @return table gate Exact enter, leave and busy ports.
function M.callback_gate()
	local claim = nil
	local gate = {}
	function gate.enter()
		if claim ~= nil then return nil end
		claim = {}
		return claim
	end
	function gate.leave(token)
		if claim == nil or not rawequal(claim, token) then return false end
		claim = nil
		return true
	end
	function gate.busy() return claim ~= nil end
	return gate
end

--- Binds the wizard's actual native writer and file provider.
--- @param options table Files, conditional batch writer and current native owner.
--- @return table owner Write, compensation and retained readiness ports.
function M.new(options)
	-- Each newly constructed receiver pins its actual current helper owners.
	-- A previously held receiver retains its original pins through settlement.
	local Writer = require("toml_codec.writer")
	local FileInverse = require("config_file_inverse")
	local SourceIdentity = require("module_source_identity")
	local source_directory = require("module_source_directory").capture()
	local constructor_source = debug.getinfo(1, "S").source
	local inverse_source = SourceIdentity.sibling(constructor_source,
		"onboarding_publication.lua", "config_file_inverse.lua", source_directory)
	local inverse_factory = rawget(FileInverse, "for_current_writer")
	assert(rawequal(package.loaded["config_file_inverse"], FileInverse)
		and rawequal(package.loaded["toml_codec.writer"], Writer)
		and type(inverse_factory) == "function"
		and SourceIdentity.same(debug.getinfo(inverse_factory, "S").source, inverse_source, source_directory),
		"wizard inverse factory must come from its canonical constructor")
	local Inverse, inverse_writer = inverse_factory()
	assert(rawequal(package.loaded["config_file_inverse"], FileInverse)
		and rawget(FileInverse, "for_current_writer") == inverse_factory
		and SourceIdentity.same(debug.getinfo(inverse_factory, "S").source, inverse_source, source_directory)
		and rawequal(inverse_writer, Writer) and rawequal(package.loaded["toml_codec.writer"], Writer)
		and type(Inverse) == "table" and getmetatable(Inverse) == nil
		and type(rawget(Inverse, "settle_publication")) == "function"
		and type(rawget(Inverse, "restore")) == "function"
		and SourceIdentity.same(debug.getinfo(Inverse.settle_publication, "S").source, inverse_source, source_directory)
		and SourceIdentity.same(debug.getinfo(Inverse.restore, "S").source, inverse_source, source_directory),
		"wizard inverse must retain its actual current writer cohort")
	assert(type(options) == "table" and type(options.files) == "table"
		and type(options.files.read_with_status) == "function"
		and type(options.write) == "function" and type(options.current) == "function",
		"wizard publication needs its actual native file and conditional batch owners")
	local files, write, current = options.files, options.write, options.current
	local read = files.read_with_status
	local publishers = { write = files.write, conditional = files.write_if_unchanged,
		remover = files.remove_if_unchanged, remove_exact = files.remove_exact,
		admitted_publish = rawget(files, "write_if_unchanged_admitted"),
		admitted_remove = rawget(files, "remove_if_unchanged_admitted") }
	local shared_publish, shared_remove = Writer.publish_if_unchanged, Writer.remove_if_unchanged
	local settle_file, restore_file = Inverse.settle_publication, Inverse.restore
	local default_settle, default_restore = FileInverse.settle_publication, FileInverse.restore
	local retry_cleanup, read_classified = Writer.retry_publication_cleanup, Writer.read_classified
	local function helpers_current()
		return rawequal(package.loaded["toml_codec.writer"], Writer)
			and rawequal(package.loaded["config_file_inverse"], FileInverse)
			and rawget(FileInverse, "for_current_writer") == inverse_factory
			and FileInverse.settle_publication == default_settle and FileInverse.restore == default_restore
			and Inverse.settle_publication == settle_file and Inverse.restore == restore_file
			and Writer.retry_publication_cleanup == retry_cleanup and Writer.read_classified == read_classified
	end
	local function provider_current()
		return helpers_current() and admitted(current) and files.read_with_status == read
			and files.write == publishers.write and files.write_if_unchanged == publishers.conditional
			and files.remove_if_unchanged == publishers.remover and files.remove_exact == publishers.remove_exact
			and rawget(files, "write_if_unchanged_admitted") == publishers.admitted_publish
			and rawget(files, "remove_if_unchanged_admitted") == publishers.admitted_remove
			and rawequal(package.loaded["toml_codec.writer"], Writer)
			and Writer.publish_if_unchanged == shared_publish and Writer.remove_if_unchanged == shared_remove
	end
	local file, compensate, busy, claim = nil, nil, false, nil
	local owner = {}

	--- Reports outstanding physical or scalar compensation independently of UI.
	--- @return boolean pending
	function owner.pending() return file ~= nil or compensate ~= nil end

	--- Permits replacing a finished host owner only when no exact debt or stack remains.
	--- This does not acknowledge a provider, publication or native cleanup.
	function owner.can_retire() return not busy and claim == nil and not owner.pending() end

	--- Settles only the retained file and scalar inverse phases.
	--- @return boolean settled
	function owner.retry_restore()
		if busy then return false end
		busy = true
		local called, restored = pcall(function()
			if file ~= nil then
				-- Even a withdrawn host may release its exact original native lock.
				-- Only genuine literal effect settlement determines a source inverse.
				if not helpers_current() or settle_file(file) ~= true or not helpers_current() then return false end
				if file.restored ~= true then
					if file.invalid == true or not provider_current() then return false end
					if restore_file(file, files) ~= true then return false end
					file.restored = true
					if not provider_current() then return false end
				end
			end
			if compensate ~= nil then
				if not provider_current() or admitted(compensate) ~= true then return false end
				compensate = nil
			end
			file = nil
			return true
		end)
		busy = false
		return called and restored == true
	end

	--- Requires all previous phases to settle before any new host side effect.
	--- @return boolean ready
	function owner.ready()
		if busy or claim ~= nil then return false end
		if owner.pending() and owner.retry_restore() ~= true then return false end
		busy = true
		local called, current_owner = pcall(provider_current)
		busy = false
		return called and current_owner == true
	end

	--- Claims the whole Finish stack before language or folder callbacks may reenter.
	--- @return table|nil token Exact private host-stack identity.
	function owner.begin()
		if owner.ready() ~= true then return nil end
		claim = {}
		return claim
	end

	--- Releases only the exact completed host stack; physical debt remains retained.
	--- @param token table Token returned by begin.
	--- @return boolean released
	function owner.finish(token)
		if claim == nil or not rawequal(token, claim) then return false end
		claim = nil
		return true
	end

	--- Retains one host's scalar inverse without replacing another capability.
	--- Accepted sub-phases are tracked by that host's original native callback.
	--- @param callback function Exact original scalar compensation owner.
	--- @return boolean retained
	function owner.compensate(callback)
		if busy or type(callback) ~= "function" or compensate ~= nil then return false end
		compensate = callback
		return true
	end

	--- Publishes with the same classified preimage retained for compensation.
	--- Source capture follows destination preparation performed by Answers.commit.
	--- @param path string Exact target path.
	--- @param rows table Validated sparse answer rows.
	--- @return boolean committed
	--- @return string|nil detail
	function owner.write(path, rows)
		if busy or owner.pending() or not provider_current() then
			return false, "the previous wizard publication remains unsettled"
		end
		busy = true
		local called, committed, detail = pcall(function()
			local read_ok, content, status, read_detail = pcall(read, path)
			if not read_ok or not classified(content, status) or not provider_current() then
				return false, tostring(read_ok and read_detail or content or "source capture refused")
			end
			local source = { status = status, content = content }
			local write_ok, written, write_detail, published_content, receipt, candidate = pcall(write, path, rows, source)
			if not write_ok then
				-- No returned capability proves what a throwing provider actually did.
				file = { path = path, source = source, invalid = true }
				return false, tostring(written)
			end
			if receipt ~= nil then
				file = { path = path, source = source, candidate = candidate, verify_absence = true,
					publication_cleanup = type(receipt) == "function" and receipt or nil,
					invalid = type(receipt) ~= "function" or type(candidate) ~= "string" }
				return false, tostring(write_detail or "wizard native publication requires compensation")
			end
			if written ~= true then return false, tostring(write_detail or "write was not confirmed") end
			if not provider_current() then
				file = { path = path, source = source, candidate = published_content, verify_absence = true,
					invalid = type(published_content) ~= "string" }
				return false, "wizard native publication owner was withdrawn"
			end
			return true
		end)
		busy = false
		if not called then return false, tostring(committed) end
		return committed == true, detail
	end

	return owner
end

return M
