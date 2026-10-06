--- infra/metrics_scope.lua

--- Coordinates collector and readouts through the canonical scope transaction.
--- Historical databases and widget positions are outside preference ownership.
local M = {}
local Manifest = require("infra.manifest_reader")
local Preferences = require("infra.metrics_preferences")
local Transaction = require("config_scope_transaction")
local FencedTransaction = require("config_scope_fenced_transaction")
local Codec = require("toml_codec")
local Logger = require("logger.shim")
local LOG = "infra.metrics_scope"
local _owner, _sequence = nil, 0

--- Builds one recoverable transaction with acknowledged native compensation.
--- @param options table Configuration path, backup path and runtime owners.
--- @return table owner Apply, pending and retry operations.
function M.new(options)
	local collector, widget, readout = options.collector, options.widget, options.readout
	assert(type(collector) == "table" and type(widget) == "table" and type(readout) == "table",
		"metrics scope requires all runtime owners")
	local function capture(source)
		if source then Preferences.resolve(Codec.decode(source.content or "")) end
		local state = { collector = collector.configuration_snapshot(),
			widget = widget.configuration_snapshot(), readout = readout.configuration_snapshot() }
		for _, key in ipairs({ "collector", "widget", "readout" }) do
			if type(state[key]) ~= "table" then return nil end
		end
		return state
	end
	local function apply_state(state)
		-- Stop collection before any other boundary. The exact final consent is
		-- published only after both native surfaces have acknowledged their state.
		local paused = {}
		for key, value in pairs(state.collector) do paused[key] = value end
		paused.enabled = false
		if collector.apply_configuration(paused) ~= true then return false end
		if widget.apply_configuration(state.widget) ~= true then return false end
		if readout.apply_configuration(state.readout) ~= true then return false end
		return collector.apply_configuration(state.collector) == true
	end
	local transaction = Transaction.new({
		path = options.path, backup_path = options.backup_path,
		files = options.files or require("adapters.file_system"), manifest = Manifest,
		capture = capture,
		apply = function(config, updates)
			local touched = {}
			for _, operation in ipairs(updates) do touched[operation.section .. "." .. operation.key] = true end
			local values, state = Preferences.resolve(config, nil, touched), capture()
			if not state then return false end
			for key in pairs(state.collector) do
				local path = "metrics." .. key
				if touched[path] then state.collector[key] = values[path] end
			end
			if touched["metrics.encrypt"] then state.collector.cipher_enabled = values["metrics.encrypt"] end
			local widget_paths = { running = "metrics.wpm_widget_visible",
				use_source_colors = "metrics.wpm_widget_colors", graph = "metrics.wpm_widget_graph" }
			for key, path in pairs(widget_paths) do
				if touched[path] then state.widget[key] = values[path]; state.widget.shown = false end
			end
			state.widget.last_draw_s = nil
			local tray_paths = { running = "metrics.wpm_menubar_visible", use_colors = "metrics.wpm_menubar_colors" }
			for key, path in pairs(tray_paths) do
				if touched[path] then state.readout[key] = values[path]; state.readout.presentation = nil end
			end
			state.readout.last_update_s, state.readout.last_key = nil, nil
			return apply_state(state)
		end,
		restore = apply_state,
	})
	-- Native preferences admit release from the primary compensation predicate;
	-- the distinct public journal retains busy and release debt until settled.
	local owner, native_token = {}, { pending = transaction.pending }
	return FencedTransaction.new({ owner = owner, native_token = native_token, transaction = transaction,
		scope = "metrics", fences = { { acquire = Preferences.acquire, release = Preferences.release } },
		available = function() return true end })
end

--- Executes a menu request, retaining any failed inverse for the next retry.
--- @param mode string Recommended or clear.
--- @param is_paused function Live pause getter.
--- @return boolean committed
--- @return string|nil detail
function M.apply(mode, is_paused)
	if mode ~= "recommended" and mode ~= "clear" then return false, "invalid metrics scope mode" end
	if type(is_paused) ~= "function" or is_paused() then return false, "metrics configuration is paused" end
	if _owner and _owner.pending() and _owner.retry_restore() ~= true then return false, "metrics rollback is pending" end
	_sequence = _sequence + 1
	local path = require("infra.config_paths").config("config.toml")
	_owner = M.new({ path = path, backup_path = path .. ".metrics-" .. os.date("%Y%m%d-%H%M%S") .. "-" .. _sequence .. ".bak",
		collector = require("modules.keylogger.keylogger"), widget = require("ui.wpm.widget"),
		readout = require("ui.wpm.tray_readout") })
	Logger.info(LOG, "Metrics scope '%s' started.", mode)
	local committed, detail = _owner.apply(mode)
	if committed then Logger.info(LOG, "Metrics scope '%s' completed.", mode)
	else Logger.error(LOG, "Metrics scope '%s' refused: %s.", mode, tostring(detail)) end
	return committed, detail
end

--- The metrics participant of a composed scope, bound to the retained owner.
--- @param is_paused function Live pause getter.
--- @return table participant See config_scope_composition.
function M.participant(is_paused)
	return require("config_scope_participant").synchronous({
		apply = function(mode) return M.apply(mode, is_paused) end,
		owner = function() return _owner end,
	})
end

return M
