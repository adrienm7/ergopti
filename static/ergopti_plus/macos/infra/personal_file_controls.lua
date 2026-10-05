--- infra/personal_file_controls.lua

--- ==============================================================================
--- MODULE: Personal File Metadata Controller
--- DESCRIPTION:
--- Publishes source-owned metadata through captured native registry receipts.
--- Failed file inverses retain the configuration lease until exact cleanup.
--- ==============================================================================
local M = {}
local Files = require("hotstrings.personal_files")
local Loader = require("infra.personal_hotstrings")
local Config = require("modules.hotstrings.hotstrings_config")
local FileSystem = require("adapters.file_system")
local Paths = require("infra.config_paths")
local pending

local Recovery = require("hotstrings.publication_recovery")
local Logger = require("infra.logger")

local function same(a, b)
	return a.status == b.status and (a.status ~= "ok" or a.content == b.content)
end

local function held(progress)
	local root = Paths.get("PersonalHotstringsDir")
	return type(progress.scope_current) == "function" and progress.scope_current() == true
		and progress.native_owner.current() == true and type(root) == "string"
		and root:gsub("/+$", "") == progress.binding.root
end

local function physical_matches(record, source)
	local content, status = FileSystem.read_with_status(record.path, record.on_error)
	return status == source.status and (status ~= "ok" or content == source.content)
end

local function lease(progress, record)
	return Recovery.lease({ files = FileSystem, native = record.native, path = record.path,
		expected = record.expected, candidate = record.candidate, on_error = record.on_error,
		current = function() return held(progress) end })
end

local function publication_current(progress, content)
	return held(progress) and Loader.publication_current(progress.current_record, content) == true and held(progress)
end

--- Reserves the exact invocation before entering a fallible native publisher.
local function publish(progress, key, path, expected, candidate)
	if not held(progress) or progress[key] then return false end
	local record = { path = path, expected = expected, candidate = candidate,
		on_error = function(category)
			Logger.error("personal.metadata", "Native publication refused: %s.", tostring(category))
		end }
	progress[key] = record
	local called, acknowledged, detail, native = pcall(FileSystem.write_if_unchanged,
		path, candidate, expected, record.on_error)
	record.acknowledged, record.native, record.detail = called and acknowledged == true, native, detail
	if not held(progress) then return false end
	if native ~= nil then
		local bound = lease(progress, record)
		local view = bound and bound.view()
		if not bound or not view or bound.matches_source() ~= true then return false end
		if key == "source_forward" or key == "source_inverse" then
			if not publication_current(progress, view.source.content) then return false end
		end
		return record.acknowledged and bound.is_settled() == true and held(progress)
	end
	if record.acknowledged then return physical_matches(record, { status = "ok", content = candidate }) and held(progress) end
	-- Compatibility test/native ports without the capability cannot leave a
	-- mutex receipt. Their unchanged/foreign source is never inverse authority.
	if type(FileSystem.publication_receipt_view) ~= "function" then
		local content, status = FileSystem.read_with_status(path, record.on_error)
		if held(progress) and (same({ status = status, content = content }, expected)
			or status == "ok" and content ~= candidate and content ~= expected.content) then progress[key] = nil end
	end
	return false
end

--- Settles a native forward receipt before preparing its separately owned inverse.
local function inverse(progress, forward_key, inverse_key, source)
	local forward = progress[forward_key]
	if not forward then return true end
	if not held(progress) then return false end
	if not progress[inverse_key] then
		local expected
		if forward.native ~= nil then
			local bound = lease(progress, forward)
			if not bound or bound.settle() ~= true then return false end
			local view = bound.view()
			if not view then return false end
			if source and not publication_current(progress, view.source.content) then return false end
			if not view.published then progress[forward_key] = nil; return true end
			expected = view.source
		elseif forward.acknowledged then
			expected = { status = "ok", content = forward.candidate }
			if type(FileSystem.publication_receipt_view) == "function"
				and not physical_matches(forward, expected) or not held(progress) then return false end
		else return false end
		if forward.expected.status ~= "ok" then return false end
		publish(progress, inverse_key, forward.path, expected, forward.expected.content)
	end
	local backward = progress[inverse_key]
	if not backward or not held(progress) then return false end
	if backward.native == nil and backward.acknowledged ~= true
		and type(FileSystem.publication_receipt_view) ~= "function"
		and physical_matches(backward, backward.expected) and held(progress) then
		progress[inverse_key] = nil
		return inverse(progress, forward_key, inverse_key, source)
	end
	if backward.native ~= nil then
		local bound = lease(progress, backward)
		if not bound or bound.settle() ~= true then return false end
		local view = bound.view()
		if not view or view.source.status ~= "ok" or view.source.content ~= forward.expected.content then
			-- A release-only inverse receipt settles resources without proving
			-- restoration. Retry publication from its exact unchanged candidate.
			if view and view.published == false then progress[inverse_key] = nil end
			return false
		end
	elseif not backward.acknowledged or type(FileSystem.publication_receipt_view) == "function"
		and not physical_matches(backward, forward.expected) then return false end
	if source then
		progress.source_restored = true
		if not publication_current(progress, forward.expected.content)
			or Loader.adopt_published_source(progress.current_record, forward.expected.content) ~= true
			or not held(progress) then return false end
		progress.current_record = Loader.adoption(progress.binding.record.owner)
		if not progress.current_record or Loader.adoption_current(progress.current_record) ~= true or not held(progress) then return false end
	end
	progress[forward_key], progress[inverse_key] = nil, nil
	return true
end

local function release_owned(progress)
	if type(progress.scope_current) ~= "function" or progress.scope_current() ~= true then return false end
	if not progress.native_released then
		if progress.native_owner.release() ~= true then return false end
		progress.native_released = true
	end
	return Config.release(progress.owner) == true
end

--- Releases only proven native and file inverses. Foreign owners retain debt.
--- @return boolean released
function M.retry_cleanup()
	if not pending then return true end
	if pending.release_only then
		if release_owned(pending) ~= true then return false end
		pending = nil; return true
	end
	if pending.native_owner.retry_inverse() ~= true or not held(pending) then return false end
	local source_restored = inverse(pending, "source_forward", "source_inverse", true) == true
	if not source_restored and pending.source_restored ~= true then return false end
	if inverse(pending, "override_forward", "override_inverse", false) ~= true then return false end
	if not source_restored then return false end
	pending.release_only = true
	if release_owned(pending) ~= true then return false end
	pending = nil
	return true
end

--- Captures the real registry owner; a descriptor from the UI is never enough.
--- @param id string Canonical additional-personal descriptor identity.
--- @return table|nil binding Captured source, registry and configured-root owners.
function M.capture(id)
	if pending or not Files.components(id) then return nil end
	local record = Loader.adoption(id)
	local keymap = require("modules.keymap")
	local native = record and type(keymap.personal_file_scope_binding) == "function"
		and keymap.personal_file_scope_binding(id)
	if not record or record.admitted ~= true or type(native) ~= "table" or type(native.current) ~= "function"
		or native.current() ~= true or Loader.adoption_current(record) ~= true then return nil end
	local root = Paths.get("PersonalHotstringsDir")
	if type(root) ~= "string" then return nil end
	root = root:gsub("/+$", "")
	if record.path ~= root .. "/" .. table.concat(record.source.components, "/") then return nil end
	return { record = record, native = native, root = root }
end

local function current(binding, registry)
	local root = Paths.get("PersonalHotstringsDir")
	return not pending and type(binding) == "table" and type(root) == "string"
		and root:gsub("/+$", "") == binding.root
		and (not registry or binding.native.current() == true)
		and Loader.adoption_current(binding.record) == true
end

--- Stages native mappings first; conditional source replacement publishes last.
--- @param binding table Captured admitted native binding.
--- @param section string|nil Literal declared section, or nil for file metadata.
--- @param field string Existing metadata control.
--- @param value any Validated candidate or nil to clear.
--- @return boolean committed
function M.apply(binding, section, field, value)
	if M.retry_cleanup() ~= true or not current(binding, true) then return false end
	local owner = {}
	if Config.acquire(owner) ~= true then return false end
	local native_owner = require("modules.keymap").capture_publication_owner()
	local scope_current = Config.capture_scope_owner(owner)
	if not native_owner or not scope_current then Config.release(owner); return false end
	local plan = Config.prepare_personal_metadata(owner, binding.record, section, field, value)
	if not plan then Config.release(owner); return false end
	local progress = { owner = owner, plan = plan, binding = binding, current_record = binding.record,
		native_owner = native_owner, scope_current = scope_current }
	local ok, committed = pcall(function()
		return native_owner.run(function()
		return Config.adopt_scope_source(owner, plan.override_target, function()
			return require("modules.keymap").replace_personal_source(binding.record.owner,
				binding.record.path, plan.content, function()
					if not current(binding, false) then return false end
					if value ~= nil then
						local effective = Config.personal_catalogue_effective(binding.record, section)
						if not effective or effective[field] ~= value then return false end
					end
					if native_owner.capture_current() ~= true or scope_current() ~= true then return false end
					if not same(plan.override_source, plan.override_target) then
						if publish(progress, "override_forward", plan.override_path,
							plan.override_source, plan.override_target.content) ~= true then return false end
					end
					if not current(binding, false) then return false end
					if publish(progress, "source_forward", binding.record.path,
						{ status = "ok", content = binding.record.content }, plan.content) ~= true then return false end
					if Loader.adopt_published_source(binding.record, plan.content) ~= true or not held(progress) then return false end
					progress.current_record = Loader.adoption(binding.record.owner)
					return progress.current_record ~= nil and Loader.adoption_current(progress.current_record) == true and held(progress)
				end, plan) == true
		end) == true
		end)
	end)
	if not ok or committed ~= true then
		pending = progress
		M.retry_cleanup()
		return false
	end
	progress.scope_current, progress.release_only = Config.capture_scope_owner(owner), true
	if not progress.scope_current or release_owned(progress) ~= true then pending = progress; return false end
	return true
end

return M
