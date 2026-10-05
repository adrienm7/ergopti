--- _shared/lua/config_file_inverse.lua

--- ==============================================================================
--- MODULE: Exact Configuration File Inverse
--- DESCRIPTION:
--- Retains conditional publication effects and native cleanup before restoring
--- an owner's exact source. Retries settle the original receipt before another
--- write, and never replace a source another writer changed in the meantime.
--- ==============================================================================

local M = {}
local Writer = require("toml_codec.writer")

--- Settles the forward publication's native receipt before runtime compensation.
--- A proven no-effect refusal owes no source mutation, even if a successor exists.
--- @param file table Private path, source, candidate and publication receipt.
--- @return boolean settled
function M.settle_publication(file)
	if file.publication_cleanup == nil then return true end
	local settled, _, published = Writer.retry_publication_cleanup(file)
	if settled ~= true then return false end
	if published == false then file.restored = true end
	return true
end

--- Restores a private exact source while retaining all refused native effects.
--- @param file table Private source/candidate, effect state and optional verify_absence policy.
--- @param files table Classified native adapter.
--- @return boolean restored
function M.restore(file, files)
	if M.settle_publication(file) ~= true then return false end
	if file.restored == true then return true end
	if file.inverse_receipt ~= nil then
		local settled, _, published = Writer.retry_publication_cleanup(file.inverse_receipt)
		if settled ~= true then return false end
		if published == true then
			-- The inverse already wrote. Verify its target; repeating it would
			-- replace a later source or lose the exact terminal receipt.
			local current, status = Writer.read_classified(file.path, files)
			local verified = status == file.source.status
				and (status ~= "ok" or current == file.source.content)
			if verified then file.inverse_receipt = nil end
			return verified
		end
		file.inverse_receipt = nil
	end
	if file.removal_effect == true then
		local _, status = Writer.read_classified(file.path, files)
		return status == "absent"
	end
	if file.removal_cleanup ~= nil then
		local call_ok, settled, _, removed = pcall(file.removal_cleanup)
		if not call_ok or settled ~= true or type(removed) ~= "boolean" then return false end
		file.removal_cleanup = nil
		if removed == true then
			if file.verify_absence ~= true then return true end
			file.removal_effect = true
			local _, status = Writer.read_classified(file.path, files)
			return status == "absent"
		end
		local _, status = Writer.read_classified(file.path, files)
		if status == "absent" then return true end
	end
	local expected = { status = "ok", content = file.candidate }
	if file.source.status == "absent" then
		local removal_adapter = files
		if type(file.remove) == "function" and not (type(files) == "table"
			and type(files.remove_if_unchanged) == "function") then
			removal_adapter = { read_with_status = function(path) return Writer.read_classified(path, files) end,
				remove_exact = file.remove }
		end
		local removed, _, retry_cleanup = Writer.remove_if_unchanged(file.path, removal_adapter, expected)
		if type(retry_cleanup) == "function" then file.removal_cleanup = retry_cleanup end
		if removed == true and file.verify_absence == true then
			file.removal_effect = true
			local _, status = Writer.read_classified(file.path, files)
			return status == "absent"
		end
		return removed == true
	end
	local restored, _, retry_cleanup = Writer.publish_if_unchanged(file.path, file.source.content, files, expected)
	if type(retry_cleanup) == "function" then
		file.inverse_receipt = { publication_cleanup = retry_cleanup }
	end
	return restored == true
end

return M
