--- _shared/lua/config_scope_file.lua

--- ==============================================================================
--- MODULE: Scope Secondary File (Shared)
--- DESCRIPTION:
--- Owns one additional file of a scope transaction beside config.toml: it
--- prepares the candidate from the exact source, backs that source up and
--- reads the backup back, publishes only while the source is unchanged, and
--- puts the exact source back when a later step of the scope is refused.
---
--- WHY A PARTICIPANT RATHER THAN A SECOND TRANSACTION:
--- One user command changes both files. Two independent transactions could each
--- succeed or fail on their own and leave half a scope applied; the shared
--- coordinator keeps one inverse, and this participant is part of it.
--- ==============================================================================

local M = {}
local Writer = require("toml_codec.writer")
local FileInverse = require("config_file_inverse")

--- Creates the participant for one transaction.
--- @param options table { path, backup_path, remove = function(path) -> boolean,
---   files = platform file adapter or nil for the writer's own I/O }.
--- @return table participant
function M.new(options)
	assert(type(options) == "table" and type(options.path) == "string" and options.path ~= ""
		and type(options.backup_path) == "string" and options.backup_path ~= options.path
		and type(options.remove) == "function", "scope file participant ports are incomplete")
	assert(options.files == nil or type(options.files) == "table", "scope file adapter must be a table")
	local files = options.files
	local participant = {}
	local source, candidate, published = nil, nil, false
	local inverse, backup_receipt, publication_debt = nil, nil, false

	--- Whether the candidate differs from the exact source it was prepared from.
	--- @return boolean
	local function changed()
		if source.status == "absent" then return candidate ~= "" end
		return candidate ~= source.content
	end

	--- Prepares the candidate from the file as it is now.
	--- @param rows table Batch writer rows.
	--- @return boolean prepared
	--- @return string|nil reason
	function participant.prepare(rows)
		assert(source == nil, "a scope file is prepared once")
		local prepared, detail, content, exact = Writer.prepare_batch(options.path, rows, files)
		if prepared ~= true then return false, detail end
		source, candidate = exact, content
		inverse = { path = options.path, source = exact, candidate = content, remove = options.remove }
		return true
	end

	--- The candidate bytes, or nil before preparation.
	--- @return string|nil
	function participant.candidate() return candidate end

	--- The exact classified source the candidate was prepared from.
	--- @return table|nil `{ status = "ok", content }` or `{ status = "absent" }`
	function participant.source()
		if source == nil then return nil end
		if source.status ~= "ok" then return { status = source.status } end
		return { status = "ok", content = source.content }
	end

	--- The classified source the file holds once the candidate is published.
	--- @return table `{ status = "ok"|"absent", content }`
	function participant.target()
		assert(source ~= nil, "a scope file must be prepared before its target is known")
		if not changed() then return participant.source() end
		return { status = "ok", content = candidate }
	end

	--- Backs up the exact source bytes and verifies the copy before any change.
	--- @return boolean backed_up
	--- @return string|nil reason
	function participant.backup()
		assert(source ~= nil, "a scope file must be prepared before its backup")
		if source.status ~= "ok" or not changed() then return true end
		local written, detail, retry_cleanup = Writer.publish_if_unchanged(options.backup_path, source.content, files,
			{ status = "absent" })
		if type(retry_cleanup) == "function" then backup_receipt = { publication_cleanup = retry_cleanup } end
		if written ~= true then return false, "backup refused: " .. tostring(detail) end
		local observed, status = Writer.read_classified(options.backup_path, files)
		if status ~= "ok" or observed ~= source.content then return false, "backup verification failed" end
		return true
	end

	--- Publishes the candidate while the file still holds its exact source.
	--- @return boolean published
	--- @return string|nil reason
	function participant.publish()
		assert(source ~= nil, "a scope file must be prepared before its publication")
		if not changed() then return true end
		local written, detail, retry_cleanup = Writer.publish_if_unchanged(options.path, candidate, files, source)
		if type(retry_cleanup) == "function" then
			inverse.publication_cleanup, publication_debt = retry_cleanup, true
		end
		if written ~= true then return false, detail end
		published = true
		return true
	end

	--- Puts the exact source back when the candidate is still what the file holds.
	--- A file another writer changed since is left alone and reported.
	--- @return boolean restored
	function participant.restore()
		if backup_receipt ~= nil then
			if Writer.retry_publication_cleanup(backup_receipt) ~= true then return false end
			backup_receipt = nil
		end
		if inverse and inverse.publication_cleanup ~= nil then
			if FileInverse.settle_publication(inverse) ~= true then return false end
			published = inverse.restored ~= true
		end
		if not published then publication_debt = false; return true end
		local restored = FileInverse.restore(inverse, files)
		if restored then published, publication_debt = false, false else publication_debt = true end
		return restored
	end

	--- Whether a refused native publication or inverse still owns cleanup.
	--- @return boolean pending
	function participant.pending()
		return publication_debt or backup_receipt ~= nil or (inverse ~= nil and (inverse.publication_cleanup ~= nil
			or inverse.inverse_receipt ~= nil or inverse.removal_cleanup ~= nil))
	end

	return participant
end

return M
