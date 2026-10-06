-- tools/diagnostics/hs_script_scope_native.lua
-- Proves the native SDK setter and real Script participant on unique aliases.
-- The standalone bootstrap owns the process; no managed driver is initialized.

local M = {}
local GLOBAL_KEY = "__ergopti_native_script_scope_probe"

local function same_views(left, right)
	for _, key in ipairs({ "locale", "locale_backend", "log_level", "error_dialog" }) do
		if left[key] ~= right[key] then return false end
	end
	return true
end

--- Runs the real standalone participant under one bounded diagnostic intent.
--- Feature failures are reported through the existing conditional file publisher;
--- failures of that publisher itself remain errors owned by the native bootstrap.
--- @param receipt_path string Initially absent result receipt path.
--- @param destination string Initially absent private TOML source path.
--- @param nonce string Exact lower-case 32-digit native owner nonce.
--- @return string nonce Identity of the settled or explicitly incomplete result.
function M.run(receipt_path, destination, nonce)
	assert(type(receipt_path) == "string" and receipt_path ~= "" and not receipt_path:find("\0", 1, true))
	assert(type(destination) == "string" and destination ~= "" and destination ~= receipt_path and not destination:find("\0", 1, true))
	assert(type(nonce) == "string" and #nonce == 32 and nonce:match("^[0-9a-f]+$"), "Invalid native Script probe nonce")
	assert(_G[GLOBAL_KEY] == nil, "A native Script probe already owns its participant")
	local owner = { nonce = nonce }
	_G[GLOBAL_KEY] = owner
	local Json = require("json")
	local FileSystem = require("adapters.file_system")
	local Writer = require("toml_codec.writer")
	local Scope, Runtime, Manifest, I18n, Locale, Logger, Dialog, Preferences, Checkpoint, Storage
	local info = hs.processInfo
	local identity = {
		schema_version = 1, contract = "script.scope-native", nonce = nonce,
		pid = info.processID, executable = info.executablePath,
		bundle_id = info.bundleID, version = info.version,
	}
	local result = {}
	for key, value in pairs(identity) do result[key] = value end
	for _, key in ipairs({ "sdk_void_set", "sdk_readback", "sdk_clear", "participant_applied",
		"participant_reverted", "source_restored", "native_aliases_restored", "runtime_restored", "complete" }) do result[key] = false end
	result.aliases, result.runtime_views, result.errors = Json.array({}), {}, Json.array({})
	local native, set, get, clear = hs.settings, hs.settings.set, hs.settings.get, hs.settings.clear
	local prefix = "ergopti.scope_probe." .. nonce .. "."
	local primitive = prefix .. "sdk_primitive"
	local participant, claim_published, primitive_attempted = nil, false, false
	local before, aliases, cells = nil, nil, {}
	local function error_receipt(detail)
		if #result.errors < 16 then result.errors[#result.errors + 1] = tostring(detail):sub(1, 4096) end
	end
	local function current_native()
		return rawequal(hs.settings, native) and rawequal(hs.settings.set, set)
			and rawequal(hs.settings.get, get) and rawequal(hs.settings.clear, clear)
	end
	local function publish(path, value)
		local bytes = assert(Json.encode(value)) .. "\n"
		local acknowledged, detail, cleanup = Writer.publish_if_unchanged(path, bytes, FileSystem, { status = "absent" })
		local effect = { path = path, content = bytes, publication_cleanup = cleanup }
		assert(Writer.retry_publication_cleanup(effect) == true, "Diagnostic publication cleanup remains pending")
		assert(acknowledged == true, "Diagnostic publication refused: " .. tostring(detail))
		local actual, status = FileSystem.read_with_status(path)
		assert(status == "ok" and actual == bytes, "Diagnostic receipt readback differs")
	end
	local function views()
		local value = { locale = I18n.get_locale(), locale_backend = Locale.current_locale(),
			log_level = Logger.current_level, error_dialog = Dialog.is_enabled() }
		assert(type(value.locale) == "string" and #value.locale > 0 and #value.locale <= 64)
		assert(type(value.locale_backend) == "string" and value.locale == value.locale_backend, "Native locale getters disagree")
		assert(type(value.log_level) == "number" and value.log_level == value.log_level
			and value.log_level ~= math.huge and value.log_level ~= -math.huge)
		local declared = false
		for _, level in pairs(Logger.LEVELS) do declared = declared or level == value.log_level end
		assert(declared and type(value.error_dialog) == "boolean", "Native runtime getters are not declared scalars")
		return value
	end
	local function aliases_absent()
		if not aliases then return false end
		for _, row in ipairs(result.aliases) do if get(row.key) ~= nil then return false end end
		return current_native()
	end
	local function primitive_cleanup()
		if not primitive_attempted then return true end
		assert(current_native(), "Native settings provider changed before primitive cleanup")
		local current = get(primitive)
		if current == nil then return true end
		assert(current == nonce, "Foreign primitive successor preserved")
		assert(clear(primitive) == true and get(primitive) == nil and current_native(), "Native primitive cleanup refused")
		return true
	end
	local okay, failure = xpcall(function()
		Scope = require("infra.script_scope")
		Runtime = require("script_scope_runtime")
		Manifest = require("infra.manifest_reader")
		I18n = require("infra.i18n")
		Locale = require("infra.locale")
		Logger = require("infra.logger")
		Dialog = require("ui.error_dialog")
		Preferences = require("infra.preferences")
		Checkpoint = require("ui.menu.preferences_transaction")
		Storage = require("adapters.storage")
		assert(current_native(), "Native settings provider differs")
		local _, source_status = FileSystem.read_with_status(destination)
		assert(source_status == "absent", "Private Script source must initially be absent")
		-- Only the standalone bootstrap initializes these native locale owners.
		assert(package.loaded["modules.keymap"] == nil and package.loaded["ui.menu"] == nil,
			"The managed driver must not own this standalone native probe")
		I18n.set_locale_injector(function(code) Locale.set_locale(code) end)
		I18n.init()
		before = views(); result.runtime_views.before = before
		aliases = Scope.native_aliases()
		local plan, paths = Runtime.plan(Manifest, "hs", aliases, "recommended")
		for _, row in ipairs(plan.operations) do
			local path = row.section .. "." .. row.key
			local value = row.value
			if row.delete then value = Manifest.default_for(path) end
			cells[path] = { present = true, value = value }
		end
		local claim = {}
		for key, value in pairs(identity) do claim[key] = value end
		claim.contract, claim.entries = "script.scope-claim", Json.array({})
		claim.entries[1] = { key = primitive, before = { present = false }, allowed_values = Json.array({ nonce }) }
		assert(get(primitive) == nil, "Native primitive key already exists")
		for index, path in ipairs(paths) do
			local descriptor = aliases[path]
			descriptor.alias = "scope_probe." .. nonce .. ".alias_" .. index
			local physical = "ergopti." .. descriptor.alias
			assert(get(physical) == nil, "Native Script alias already exists")
			result.aliases[#result.aliases + 1] = { path = path, alias = descriptor.alias, key = physical, publication = cells[path] }
			claim.entries[#claim.entries + 1] = { key = physical, before = { present = false }, allowed_values = Json.array({ cells[path].value }) }
		end
		assert(#paths > 0 and current_native(), "Native Script alias metadata unavailable")
		publish(destination .. ".settings-claim.json", claim)
		claim_published = true
		-- The durable intent precedes every effect; a newly inserted value is
		-- refused rather than replaced after the earlier absence preview.
		for _, entry in ipairs(claim.entries) do assert(get(entry.key) == nil, "Native claim key acquired a foreign successor") end
		assert(current_native(), "Native settings provider changed after claim publication")
		primitive_attempted = true
		local returned = set(primitive, nonce)
		result.sdk_void_set = returned == nil
		result.sdk_readback = get(primitive) == nonce and current_native()
		assert(result.sdk_void_set and result.sdk_readback, "Native SDK void setter or exact readback differs")
		result.sdk_clear = clear(primitive) == true and get(primitive) == nil and current_native()
		assert(result.sdk_clear, "Native SDK clear did not return its Boolean receipt")
		local _, loaded = Preferences.load(destination)
		assert(loaded == "absent", "Native private source classification differs")
		local state = {}
		local _, checkpoint = Checkpoint.bind(Preferences, { state = state, initial_state = {}, initial_preferences = {} })
		participant = Scope.new({ path = destination, files = FileSystem, state = state,
			preferences = Preferences, checkpoint = checkpoint, aliases = aliases, storage = Storage,
			capture_preferences = function() return Preferences.snapshot(state, {}, {}) end,
			admission = function(_, callback) return callback() == true end, paused = function() return false end,
			backup_path = function() return destination .. ".config-backup" end,
			storage_backup_path = function() return destination .. ".settings-backup" end })
		assert(aliases_absent() and get(primitive) == nil and current_native(), "Native aliases changed before participant admission")
		result.participant_applied = participant.apply("recommended") == true
		assert(result.participant_applied and participant.pending() == false, "Actual Script participant publication refused")
		result.runtime_views.applied = views()
		for _, row in ipairs(result.aliases) do
			assert(get(row.key) == row.publication.value and current_native(), "Actual native alias publication differs")
			local provider = aliases[row.path].native
			local effective = row.publication.value
			if rawequal(provider, I18n) then
				assert(result.runtime_views.applied.locale == effective and result.runtime_views.applied.locale_backend == effective)
			elseif rawequal(provider, Logger) then assert(result.runtime_views.applied.log_level == Logger.LEVELS[effective])
			elseif rawequal(provider, Dialog) then assert(result.runtime_views.applied.error_dialog == effective)
			else error("Declared native field has no diagnostic getter") end
		end
		result.participant_reverted = participant.revert() == true
		assert(result.participant_reverted and participant.pending() == false, "Actual Script participant inverse refused")
		assert(participant.release() == true and participant.pending() == false, "Actual Script participant finalization refused")
		participant = nil
	end, debug.traceback)
	if not okay then error_receipt(failure) end
	-- The real participant retains its own conditional inverse on failure;
	-- never replace it with direct alias clears or blind runtime setters.
	if participant then
		local cleaned, cleanup_failure = xpcall(function()
			if participant.pending() then assert(participant.retry_restore() == true, "Script participant compensation remains pending") end
			if result.participant_applied and not result.participant_reverted then
				local _, status = FileSystem.read_with_status(destination)
				local restored = status == "absent" and aliases_absent() and same_views(before, views())
				result.participant_reverted = restored or participant.revert() == true
				assert(result.participant_reverted, "Script participant retained inverse refused")
			end
			assert(participant.pending() == false and participant.release() == true, "Script participant cleanup remains pending")
		end, debug.traceback)
		if not cleaned then error_receipt(cleanup_failure) end
	end
	local cleaned, cleanup_failure = xpcall(primitive_cleanup, debug.traceback)
	if not cleaned then error_receipt(cleanup_failure) end
	local observed, observation_failure = xpcall(function()
		local _, status = FileSystem.read_with_status(destination)
		result.source_restored = status == "absent"
		result.native_aliases_restored = claim_published and aliases_absent() and get(primitive) == nil
		if before then result.runtime_views.restored = views(); result.runtime_restored = same_views(before, result.runtime_views.restored) end
	end, debug.traceback)
	if not observed then error_receipt(observation_failure) end
	result.complete = okay and #result.errors == 0
	for _, flag in ipairs({ "sdk_void_set", "sdk_readback", "sdk_clear", "participant_applied",
		"participant_reverted", "source_restored", "native_aliases_restored", "runtime_restored" }) do result.complete = result.complete and result[flag] end
	publish(receipt_path, result)
	if result.complete then _G[GLOBAL_KEY] = nil end
	return nonce
end

return M
