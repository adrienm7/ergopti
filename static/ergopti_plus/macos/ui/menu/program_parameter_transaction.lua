--- ui/menu/program_parameter_transaction.lua

--- ==============================================================================
--- MODULE: Private Program Parameter Transaction
--- DESCRIPTION:
--- Reuses the global writer fence and ordinary save checkpoint for all program
--- selectors. A refused inverse retains the fence and exact preimages; retries
--- never overwrite a foreign source, parameter snapshot or checkpoint revision.
--- ==============================================================================

local M = {}
local Logger = require("infra.logger")
local Codec = require("toml_codec")
local Writer = require("toml_codec.writer")
local Assignment = require("shortcuts.assignment")
local Manifest = require("infra.manifest_reader")
local LOG = "menu.program_parameter_transaction"

local function copy(source)
	local result = {}
	for key, value in pairs(source) do result[key] = value end
	return result
end

local function equal(left, right)
	if type(left) ~= "table" or type(right) ~= "table" then return false end
	for key, value in pairs(left) do if right[key] ~= value then return false end end
	for key, value in pairs(right) do if left[key] ~= value then return false end end
	return true
end

local function deep_equal(left, right)
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in pairs(left) do if not deep_equal(value, right[key]) then return false end end
	for key in pairs(right) do if left[key] == nil then return false end end
	return true
end

--- Creates one session owner shared by every program selector.
--- @param options table Existing admission, preference, native and file owners.
--- @return table owner Apply and retained compensation operations.
function M.new(options)
	local gestures, preferences, checkpoint = options.gestures, options.preferences, options.checkpoint
	for _, name in ipairs({ "admission", "paused", "save_prefs", "current_path", "capture_checkpoint_candidate" }) do
		assert(type(options[name]) == "function", "program transaction port missing: " .. name)
	end
	local debt, owner, claim = nil, {}, {}
	local function private_reporter()
		Logger.error(LOG, "Private program publication was refused.")
	end
	local function invoke(label, callback, ...)
		local called, receipt = pcall(callback, ...)
		if not called or receipt ~= true then
			-- Receipts and exceptions can contain the private program scalar.
			Logger.error(LOG, "Private program %s was not acknowledged.", label)
			return false
		end
		return true
	end
	local function current_path() return options.current_path() == options.path end
	local function physical()
		local content, status = Writer.read_classified(options.path, options.files, private_reporter)
		return { content = content, status = status }
	end
	local function matches(left, right) return preferences.source_matches(left, right) == true end
	local function allowed_source(saved, source)
		for _, value in ipairs(saved.sources) do if matches(value, source) then return true end end
		return false
	end
	-- This observer crosses providers which deliberately coerce native boolean
	-- results. Preferences issues the envelope only after native capability proof.
	local function accept_publication(event)
		local saved = debt
		if not saved or type(event) ~= "table" or event.path ~= options.path
			or not allowed_source(saved, event.expected) or type(event.source) ~= "table"
			or type(event.adopt) ~= "function" or type(event.native) ~= "table"
			or type(event.native.matches_source) ~= "function" or type(event.native.retry) ~= "function"
			or type(event.native.is_settled) ~= "function" then return false end
		saved.sources[#saved.sources + 1] = { status = event.source.status, content = event.source.content }
		if event.acknowledged ~= true or event.native.is_settled() ~= true then
			saved.native_publications = saved.native_publications or {}
			saved.native_publications[#saved.native_publications + 1] = event
		end
		return true
	end
	local function assignment_source(source, mutation, action)
		if mutation.publishes_assignment ~= true then return source end
		local row
		if mutation.section == "shortcuts.keyboard" then
			row = Assignment.operation(mutation.key, action, function(key) return key == mutation.key end, gestures.is_assignable)
		else
			row = Manifest.sparse_operation(mutation.section .. "." .. mutation.key, action)
		end
		local rows = preferences.prepare_shortcut_updates(source, { row }, { mutation.section:match("[^.]+$") })
		local prepared, _, content = Writer.prepare_batch(options.path, rows, options.files, source, private_reporter)
		if prepared ~= true then return nil end
		return { status = "ok", content = content }
	end
	local function guard(saved)
		if not current_path() or not deep_equal(checkpoint.capture(), saved.checkpoint)
			or not deep_equal(preferences.publication_receipt(options.path), saved.receipt) then return false end
		local observed_action = saved.mutation.read()
		if saved.assignment_restored or not saved.assignment_attempted then
			if observed_action ~= saved.previous then return false end
		elseif observed_action ~= saved.previous and observed_action ~= "run_program" then return false end
		if saved.mutation.read_menu then
			local menu_action = saved.mutation.read_menu()
			if saved.assignment_restored or not saved.assignment_attempted then
				if menu_action ~= saved.previous then return false end
			elseif menu_action ~= saved.previous and menu_action ~= "run_program" then return false end
		end
		local parameters = gestures.get_all_action_parameters()
		if saved.parameters_restored then
			if not equal(parameters, saved.parameters) then return false end
		elseif not equal(parameters, saved.parameters) and not equal(parameters, saved.candidate_parameters) then return false end
		local loaded = preferences.source_snapshot(options.path)
		local disk = physical()
		if not allowed_source(saved, loaded) then return false end
		if saved.disk_restored then return matches(disk, saved.source), loaded end
		return matches(loaded, disk), loaded
	end
	-- A full save can publish before a cache or commit callback throws. Adopt
	-- only that exact publication and the precisely predicted checkpoint, before
	-- testing its terminal acknowledgement or private persisted value.
	local function adopt_publication(saved, candidate)
		if not current_path() then return false end
		local publication = preferences.publication_receipt(options.path)
		local loaded, observed = preferences.source_snapshot(options.path), checkpoint.capture()
		if type(publication) ~= "table" or publication.id ~= saved.receipt.id + 1
			or not matches(loaded, publication.source) or not matches(loaded, physical()) then return false end
		local advanced = { revision = saved.prior_checkpoint.revision + 1,
			state = candidate.state, preferences = candidate.preferences }
		if not deep_equal(observed, saved.prior_checkpoint) and not deep_equal(observed, advanced) then return false end
		saved.sources[#saved.sources + 1] = loaded
		saved.receipt, saved.checkpoint = publication, observed
		saved.checkpoint_advanced = deep_equal(observed, advanced)
		saved.publication_adopted = true
		return true
	end
	local function adopt_removal(saved)
		local receipt = saved.removal_receipt
		if not current_path() or saved.source.status ~= "absent" or type(receipt) ~= "table"
			or receipt.removed ~= true or receipt.path ~= options.path
			or type(receipt.retry) ~= "function" or type(receipt.is_settled) ~= "function"
			or type(receipt.matches_source) ~= "function"
			or receipt.matches_source() ~= true or not matches(physical(), saved.source) then return false end
		saved.disk_restored = true
		return true
	end
	local function adopt_disk_publication(saved)
		local receipt = saved.disk_publication
		if not current_path() or type(receipt) ~= "table" or receipt.matches_source() ~= true
			or not matches(physical(), saved.source) then return false end
		saved.disk_restored = true
		return true
	end
	local function restore()
		local saved = debt
		if not saved then return true end
		if saved.publication_attempted and not saved.publication_adopted then
			adopt_publication(saved, saved.candidate_checkpoint)
		end
		for _, publication in ipairs(saved.native_publications or {}) do
			if not publication.adopted then publication.adopted = publication.adopt() == true end
		end
		if saved.removal_receipt and not saved.disk_restored then adopt_removal(saved) end
		if saved.disk_publication and not saved.disk_restored then adopt_disk_publication(saved) end
		local guarded, loaded = guard(saved)
		if not guarded then
			Logger.error(LOG, "Private program compensation remains fenced because its preimage changed.")
			return false
		end
		for _, publication in ipairs(saved.native_publications or {}) do
			if publication.native.is_settled() ~= true then
				if publication.native.matches_source() ~= true
					or not invoke("native publication release", publication.native.retry)
					or publication.native.is_settled() ~= true then return false end
			end
			if not guard(saved) then return false end
		end
		if saved.disk_native and saved.disk_native.is_settled() ~= true then
			if saved.disk_native.matches_source() ~= true
				or not invoke("native inverse release", saved.disk_native.retry)
				or saved.disk_native.is_settled() ~= true then return false end
			if not guard(saved) then return false end
		end
		if not saved.parameters_restored then
			if not invoke("parameter compensation", gestures.replace_action_parameters, saved.parameters) then return false end
			if not equal(gestures.get_all_action_parameters(), saved.parameters) then return false end
			saved.parameters_restored = true
		end
		guarded, loaded = guard(saved)
		if not guarded then return false end
		if saved.assignment_attempted and not saved.assignment_restored then
			local inverse = assignment_source(loaded, saved.mutation, saved.previous)
			if not inverse then return false end
			saved.sources[#saved.sources + 1] = inverse
			if not invoke("assignment compensation", saved.mutation.restore, saved.previous, private_reporter, accept_publication) then return false end
			if saved.mutation.read() ~= saved.previous
				or (saved.mutation.read_menu and saved.mutation.read_menu() ~= saved.previous) then return false end
			saved.assignment_restored = true
		end
		guarded, loaded = guard(saved)
		if not guarded then return false end
		if not saved.disk_restored then
			if not matches(loaded, saved.source) then
				local restored, removal_receipt
				if saved.source.status == "absent" then
					local detail
					restored, detail, removal_receipt = Writer.remove_if_unchanged(options.path, options.files, loaded,
						{ require_conditional = true, on_error = private_reporter })
					if type(removal_receipt) ~= "table" or removal_receipt.removed ~= true
						or removal_receipt.path ~= options.path or not matches(removal_receipt.expected, loaded)
						or type(removal_receipt.retry) ~= "function" or type(removal_receipt.is_settled) ~= "function"
						or type(removal_receipt.matches_source) ~= "function" then return false end
					saved.removal_receipt = removal_receipt
					if not adopt_removal(saved) then return false end
				else
					local detail, native
					restored, detail, native = Writer.publish_if_unchanged(options.path, saved.source.content, options.files, loaded, private_reporter)
					if type(native) == "table" and type(options.files.publication_receipt_view) == "function" then
						local verified = options.files.publication_receipt_view(native, options.path, loaded, saved.source.content, private_reporter)
						if verified then
							saved.disk_native = native
							if verified.published == true then
								saved.disk_publication = native
								if not adopt_disk_publication(saved) then return false end
							end
						end
					end
				end
				if restored ~= true then return false end
			end
			saved.disk_restored = true
		end
		guarded, loaded = guard(saved)
		if not guarded then return false end
		if saved.disk_publication and saved.disk_publication.is_settled() ~= true then
			if saved.disk_publication.matches_source() ~= true
				or not invoke("native inverse publication release", saved.disk_publication.retry)
				or saved.disk_publication.is_settled() ~= true then return false end
		end
		guarded, loaded = guard(saved)
		if not guarded then return false end
		if saved.removal_receipt and saved.removal_receipt.is_settled() ~= true
			and not invoke("physical inverse release", saved.removal_receipt.retry) then return false end
		if saved.removal_receipt and saved.removal_receipt.is_settled() ~= true then return false end
		guarded, loaded = guard(saved)
		if not guarded then return false end
		if not matches(loaded, saved.source)
			and not invoke("source compensation", preferences.replace_source, options.path, loaded, saved.source) then return false end
		guarded, loaded = guard(saved)
		if not guarded then return false end
		if saved.checkpoint_advanced and not saved.checkpoint_restored then
			local expected = { revision = saved.checkpoint.revision + 1,
				state = saved.prior_checkpoint.state, preferences = saved.prior_checkpoint.preferences }
			local acknowledged = invoke("checkpoint compensation", checkpoint.restore, saved.checkpoint, saved.prior_checkpoint)
			local observed = checkpoint.capture()
			if deep_equal(observed, expected) then saved.checkpoint = observed end
			if not acknowledged or not deep_equal(observed, expected) then return false end
			saved.checkpoint_restored = true
		end
		guarded, loaded = guard(saved)
		if not guarded or not matches(loaded, saved.source) or not matches(physical(), saved.source)
			or saved.mutation.read() ~= saved.previous
			or (saved.mutation.read_menu and saved.mutation.read_menu() ~= saved.previous)
			or not equal(gestures.get_all_action_parameters(), saved.parameters)
			or not deep_equal(saved.checkpoint.state, saved.prior_checkpoint.state)
			or not deep_equal(saved.checkpoint.preferences, saved.prior_checkpoint.preferences) then return false end
		for _, publication in ipairs(saved.native_publications or {}) do
			if publication.native.is_settled() ~= true then return false end
		end
		if saved.disk_native and saved.disk_native.is_settled() ~= true then return false end
		debt = nil
		return true
	end
	function claim.pending() return debt ~= nil end
	function claim.retry_restore()
		local called, restored = pcall(restore)
		if not called or restored ~= true then
			Logger.error(LOG, "Private program compensation remains pending.")
			return false
		end
		return true
	end
	function owner.pending() return claim.pending() end
	function owner.retry_restore()
		return options.admission("Private program recovery", claim.retry_restore, claim) == true
	end
	--- Publishes one scalar and assignment only with exact native and disk receipts.
	--- @param binding string Canonical invoker identifier.
	--- @param action string Program action identifier.
	--- @param value string Validated private program scalar.
	--- @param mutation table Assignment read, apply and restore ports, plus disk section/key.
	--- @return boolean committed
	function owner.apply(binding, action, value, mutation)
		if action ~= "run_program" or type(binding) ~= "string" or type(value) ~= "string"
			or type(mutation) ~= "table" then return false end
		for _, name in ipairs({ "read", "apply", "restore" }) do if type(mutation[name]) ~= "function" then return false end end
		return options.admission("Private program parameter edit", function()
			if options.paused() ~= false or not current_path() then return false end
			if claim.pending() and claim.retry_restore() ~= true then return false end
			local stage = "capture"
			local called, committed = pcall(function()
				local source = preferences.source_snapshot(options.path)
				if not matches(source, physical()) then return false end
				local previous, parameters = mutation.read(), gestures.get_all_action_parameters()
				if mutation.read_menu and mutation.read_menu() ~= previous then return false end
				local revision = checkpoint.capture()
				local receipt = preferences.publication_receipt(options.path)
				if type(previous) ~= "string" or type(parameters) ~= "table" or type(revision) ~= "table" or type(revision.revision) ~= "number" then return false end
				local candidate_source = assignment_source(source, mutation, action)
				if not candidate_source or not current_path() then return false end
				local candidate = copy(parameters)
				candidate[binding .. "__" .. action] = value
				debt = { mutation = mutation, previous = previous, parameters = copy(parameters), candidate_parameters = candidate,
					source = source, sources = { source, candidate_source }, checkpoint = revision, prior_checkpoint = revision, receipt = receipt }
				stage = "parameter"
				if not invoke("parameter mutation", gestures.set_action_parameter, binding, action, value) then return false end
				if not equal(gestures.get_all_action_parameters(), candidate) then return false end
				stage = "assignment"
				if not guard(debt) then return false end
				debt.assignment_attempted = true
				if not invoke("assignment mutation", mutation.apply, private_reporter, accept_publication) or mutation.read() ~= action
					or (mutation.read_menu and mutation.read_menu() ~= action) then return false end
				stage = "source-guard"
				if not guard(debt) then return false end
				stage = "publication"
				local candidate_checkpoint = options.capture_checkpoint_candidate()
				if type(candidate_checkpoint) ~= "table" or type(candidate_checkpoint.state) ~= "table"
					or type(candidate_checkpoint.preferences) ~= "table" or not guard(debt) then return false end
				debt.candidate_checkpoint, debt.publication_attempted = candidate_checkpoint, true
				local acknowledged = invoke("preference publication", options.save_prefs, private_reporter, accept_publication)
				stage = "receipt"
				local adopted = adopt_publication(debt, candidate_checkpoint)
				if not acknowledged or not adopted or not debt.checkpoint_advanced or not guard(debt) then return false end
				local loaded = preferences.source_snapshot(options.path)
				stage = "durable-value"
				local decoded = Codec.decode(loaded.content)
				local section = decoded
				for segment in mutation.section:gmatch("[^.]+") do section = type(section) == "table" and section[segment] or nil end
				if type(section) ~= "table" or section[mutation.key] ~= action
					or type(decoded.gestures) ~= "table" or type(decoded.gestures.action_parameters) ~= "table"
					or decoded.gestures.action_parameters[binding .. "__" .. action] ~= value then return false end
				if not guard(debt) or mutation.read() ~= action
					or (mutation.read_menu and mutation.read_menu() ~= action)
					or not equal(gestures.get_all_action_parameters(), candidate) then return false end
				debt = nil
				return true
			end)
			if not called or committed ~= true then
				Logger.error(LOG, "Private program edit did not commit (%s).", stage)
				claim.retry_restore()
				return false
			end
			return true
		end, claim) == true
	end
	return owner
end

return M
