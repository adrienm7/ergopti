--- infra/personal_file_scope.lua

--- ==============================================================================
--- MODULE: Native Personal File Scope Binding
--- DESCRIPTION:
--- Binds file-labelled callbacks to the current registered owner and configured
--- route. Physical aliases and shared legacy groups refuse before mutation.
--- ==============================================================================

local M = {}
local Policy = require("hotstrings.personal_scope")
local Files = require("hotstrings.personal_files")
local FileSystem = require("adapters.file_system")
local MenuPaths = require("infra.config_paths")

--- Captures an acknowledged registry binding without menu-build filesystem work.
--- @param ctx table Native menu context and actual boot-loaded source records.
--- @param record table|nil Selected loader record.
--- @return function check Exact true only while the captured native binding is owned.
function M.bind(ctx, record)
	local valid = type(record) == "table" and Files.is_descriptor(record.personal_source)
		and type(record.name) == "string" and type(record.path) == "string"
	local selected = valid and { source = Files.copy(record.personal_source), owner = record.name, path = record.path }
	local km = ctx.keymap
	local native = valid and type(km) == "table" and type(km.personal_file_scope_binding) == "function"
		and km.personal_file_scope_binding(record.name) or nil
	return function()
		if not selected or type(native) ~= "table" or type(native.current) ~= "function"
			or native.current() ~= true or type(ctx.personal_root) ~= "string" then return false end
		local root = MenuPaths.get("PersonalHotstringsDir")
		if type(root) ~= "string" then return false end
		root = root:gsub("/+$", "")
		if root ~= ctx.personal_root then return false end
		local evidence, identities, owners = {}, {}, {}
		for _, source in ipairs(ctx.personal_files or {}) do
			if source.personal_source ~= nil then
				if not Files.is_descriptor(source.personal_source) then return false end
				owners[source.name] = (owners[source.name] or 0) + 1
			end
		end
		for _, source in ipairs(ctx.personal_files or {}) do
			if source.personal_source ~= nil then
				local path = root .. "/" .. table.concat(source.personal_source.components, "/")
				if source.path ~= path then return false end
				local status, attributes = FileSystem.path_status(path)
				if status ~= "present" or type(attributes) ~= "table" or attributes.mode ~= "file"
					or attributes.dev == nil or attributes.ino == nil then return false end
				local identity = tostring(attributes.dev) .. ":" .. tostring(attributes.ino)
				if identities[identity] and identities[identity] ~= source.personal_source.id then return false end
				identities[identity] = source.personal_source.id
				local current = km.personal_file_scope_binding(source.name)
				local admitted = type(current) == "table" and current.path == path
					and current.source.id == source.personal_source.id
				evidence[#evidence + 1] = { source = source.personal_source, owner = source.name, path = path,
					admitted = admitted, exclusive = owners[source.name] == 1 }
			end
		end
		local admitted = Policy.admit(evidence, selected)
		if not admitted or native.path ~= selected.path or native.source.id ~= selected.source.id then return false end
		local content, status = FileSystem.read_with_status(selected.path)
		return type(content) == "string" and status == "ok" and native.current() == true
	end
end

return M
