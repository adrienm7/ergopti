--- _shared/lua/dynamic_hotstrings/user_code_driver.lua

--- ==============================================================================
--- MODULE: Programmable Hotstrings Driver Lifecycle (Shared)
--- DESCRIPTION:
--- The lifecycle both Lua drivers' modules/dynamic_hotstrings/user_code.lua used
--- to repeat around the shared programmable-hotstring owner
--- (dynamic_hotstrings/user_code.lua): the single started generation, the
--- desired / active / dirty posture, loading the personal source, the
--- missing-versus-failed problem the Hotstrings menu shows, the activation
--- interval, the configuration inverse, and the stop. What a driver supplies is
--- what only it can know: the native input owner and how it answers a capture,
--- a current-ness question, a deferred invocation and a commit.
---
--- FEATURES & RATIONALE:
--- 1. One lifecycle. The rules that keep user code from running unacknowledged
---    (a refused source is closed before a new one opens, a stale operation
---    token abandons its result, a dirty lifecycle refuses to report enabled)
---    live here once, so a fix cannot reach one driver only.
--- 2. Differences are ports, never branches on a platform name. The ones that
---    exist: how the native owner is asked (native_binding), whether it holds
---    the activation interval itself (apply_time), whether a registered magic
---    action pre-empts a suffix (claims), whether a report is deferred out of a
---    running callback (defer_report), what shape a preview takes
---    (preview_view) and how a notification states its severity (notify).
--- 3. Failures of the user's own script are warnings, not driver faults for the
---    error window; the user repairs them.
--- 4. No load-time driver dependency: every collaborator is a port, so the module
---    loads in a test that builds no driver paths.
--- ==============================================================================

local UserCode  = require("dynamic_hotstrings.user_code")
local UserScope = require("dynamic_hotstrings.user_scope")
local Source    = require("dynamic_hotstrings.user_source")
local KEY       = require("config_keys").KEY

local M = {}





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

--- File name of the personal source inside the configuration folder.
M.SOURCE_FILE = "personal_dynamic_hotstrings.lua"

--- Locale key of the notification shown when the personal source fails.
M.ERROR_TEXT_KEY = "menu.hotstrings.user_code.error"

--- Features-manifest path of the default activation interval.
M.TIME_ACTIVATION_KEY = KEY.HOTSTRINGS_DYNAMIC_USER_CODE_TIME_ACTIVATION_SECONDS

--- Failures of the user's own script while it runs: the user repairs them, so
--- they are warnings, not driver faults for the error window.
local USER_SCRIPT_FAILURES = { ["execution-failed"] = true, ["invalid-result"] = true }

--- Port names every driver must supply.
local REQUIRED_PORTS = {
	"read", "write", "config_dir", "translate", "notify", "default_time_seconds", "native_binding",
}

--- Port names a driver may leave out.
local OPTIONAL_PORTS = { "apply_time", "claims", "defer_report", "preview_view" }





-- ==============================
-- ==============================
-- ======= 2/ Public API ========
-- ==============================
-- ==============================

--- Builds one driver's programmable-hotstring module.
--- @param ports table {
---   logger, log, platform ("macos" | "linux"),
---   read(path) / write(path, content, expected): the classified file ports the
---     source loader reads and the example writer publishes through,
---   config_dir() -> string,
---   translate(key) -> string, notify(text, severity) -> any (severity is
---     "error" or "warning"),
---   default_time_seconds() -> number: the manifest default of the interval,
---   native_binding(native) -> table { capture(rule, seconds), current(capture),
---     publication_current(capture), publication_cached(capture),
---     invoke(rule, context, done, capture), retire(capture, rule) | nil,
---     commit(result, capture, rule, publication) },
---   apply_time(native, seconds) -> boolean | nil: the native owner's interval,
---   claims(native, buffer) -> boolean | nil: true when a native action owns the buffer,
---   defer_report(report, kind, id) -> any | nil: a non-nil answer means the
---     report was deferred out of a running callback and is already settled,
---   preview_view(row) -> any | nil: the shape the driver's consumer reads.
--- }
--- @return table module
function M.new(ports)
	assert(type(ports) == "table" and type(ports.logger) == "table" and type(ports.log) == "string"
		and type(ports.platform) == "string", "user_code_driver needs a logger, a log tag and a platform")
	for _, name in ipairs(REQUIRED_PORTS) do
		assert(type(ports[name]) == "function", "user_code_driver port missing: " .. name)
	end
	for _, name in ipairs(OPTIONAL_PORTS) do
		assert(ports[name] == nil or type(ports[name]) == "function", "invalid user_code_driver port: " .. name)
	end

	local Logger, LOG = ports.logger, ports.log
	local module = {}
	local _owner, _native, _path
	local _desired_enabled = false
	local _time_activation
	local _active_enabled, _lifecycle_dirty = false, false
	local _scope, set_time
	-- Why the last load of the personal source did not publish: "missing" or
	-- "failed", with the refusal class that set it; nil once a load publishes or
	-- the feature is switched off. The Hotstrings menu shows it on its row.
	local _problem, _problem_kind = nil, nil

	--- Reports failure classes without persisting source or generated user text.
	--- @param kind string Failure class.
	--- @param id string|nil Descriptor identifier.
	--- @return boolean reported
	local function report(kind, id)
		if ports.defer_report then
			local deferred = ports.defer_report(report, kind, id)
			if deferred ~= nil then return deferred == true end
		end
		if USER_SCRIPT_FAILURES[kind] then
			Logger.warn(LOG, "Programmable hotstring script failed (%s; rule=%s; content withheld).",
				tostring(kind), tostring(id or "source"))
		else
			Logger.error(LOG, "Programmable hotstring refused (%s; rule=%s; content withheld).",
				tostring(kind), tostring(id or "source"))
		end
		return ports.notify(ports.translate(M.ERROR_TEXT_KEY), "error") == true
	end

	--- Returns the configured user-source route.
	--- @return string path
	function module.source_path()
		return ports.config_dir() .. "/" .. M.SOURCE_FILE
	end

	--- Records a load the personal source refused. A missing file is a state the
	--- menu offers to repair (create the example): one warning, no notification.
	--- An unreadable or failing script is the user's to fix: one warning and a
	--- non-modal notification. Neither is a driver error. Repeating the same
	--- refusal logs nothing more.
	--- @param kind string Source refusal class from the loader.
	local function source_refused(kind)
		local problem = kind == "source-absent" and "missing" or "failed"
		local repeated = _problem == problem and _problem_kind == kind
		_problem, _problem_kind = problem, kind
		if repeated then return end
		if problem == "missing" then
			Logger.warn(LOG, "Programmable hotstrings are on but %s does not exist — the Hotstrings menu offers to create an example.",
				module.source_path())
			return
		end
		Logger.warn(LOG, "Programmable source refused (%s; content withheld) — the Hotstrings menu offers to open it.",
			tostring(kind))
		ports.notify(ports.translate(M.ERROR_TEXT_KEY), "warning")
	end

	--- Why the personal source is not running, for the Hotstrings menu.
	--- @return string|nil problem "missing", "failed", or nil when nothing is wrong.
	function module.problem() return _problem end

	--- Creates a user-requested example only at an absent configured route.
	--- @return boolean created
	function module.create_example()
		return Source.create_example(ports.read, ports.write, module.source_path())
	end

	--- Loads the user factory from the configured directory without creating it.
	--- @return boolean loaded
	local function reload(token)
		if not _owner or not _scope.current(token) then return false end
		_active_enabled = false
		_lifecycle_dirty = _owner.refuse_source() ~= true
		if _lifecycle_dirty then return false end
		local path = module.source_path()
		local rules, receipt, problem = Source.load(ports.read, path, { platform = ports.platform })
		if not _scope.current(token) then return false end
		if not rules or receipt.present ~= true then
			_lifecycle_dirty = _owner.refuse_source() ~= true
			source_refused(problem or "source-absent")
			return false
		end
		_path = path
		local committed = _owner.reload(rules, receipt) == true and _owner.set_enabled(_desired_enabled) == true
		if not _scope.current(token) then return false end
		_active_enabled = committed and _desired_enabled
		-- A published source has nothing left to repair.
		if committed then _problem, _problem_kind = nil, nil end
		return committed
	end

	--- Reloads source under one operation-owned configuration revision.
	--- @return boolean loaded
	--- @return table revision Exact revision assigned to this operation.
	function module.reload()
		local token = _scope.begin()
		return reload(token), token
	end

	--- Starts one generation bound to the driver's native owner.
	--- @param native table The driver's native input owner.
	--- @return boolean started
	function module.start(native)
		if _owner then return _native == native end
		_scope.begin()
		_native = native
		local binding = ports.native_binding(native)

		--- Whether this generation is still the one bound to the configured route.
		local function attached()
			return _native == native and _path == module.source_path()
		end
		local function source_current(receipt)
			return Source.current(ports.read, receipt) == true
		end

		_owner = UserCode.new({
			capture = function(rule) return binding.capture(rule, _time_activation) end,
			current = function(capture, receipt)
				return attached() and binding.current(capture) == true and source_current(receipt)
			end,
			publication_current = function(capture, receipt)
				return attached() and binding.publication_current(capture) == true
					and source_current(receipt)
					and attached() and binding.publication_cached(capture) == true
			end,
			publication_cached = function(capture)
				return attached() and binding.publication_cached(capture) == true
			end,
			invoke = binding.invoke,
			retire = binding.retire,
			commit = binding.commit,
			report = report,
		})
		_path = module.source_path()
		local receipt, problem = Source.read(ports.read, _path)
		if not receipt then
			-- Boot runs no user code: enabling loads the source and reports its state.
			Logger.warn(LOG, "Programmable source unreadable at start (%s) — it is read again when enabled.",
				tostring(problem))
			return true
		end
		-- Reading source at closed boot does not admit executable factory metadata.
		return _owner.refuse_source() == true
	end

	--- Applies the canonical gate after the user factory has loaded successfully.
	--- @param enabled boolean Requested posture.
	--- @return boolean committed
	function module.set_enabled(enabled)
		local token = _scope.begin()
		if not _owner or type(enabled) ~= "boolean" then return false, token end
		-- A switched-off source has no problem to show.
		if not enabled then _problem, _problem_kind = nil, nil end
		if not enabled and not _desired_enabled and not _active_enabled and not _lifecycle_dirty then
			return true, token
		end
		if enabled and _active_enabled and not _lifecycle_dirty then
			local receipt = _owner.scope_snapshot().source
			local admitted = receipt and receipt.path == module.source_path()
				and Source.current(ports.read, receipt) == true
			if not _scope.current(token) then return false, token end
			if admitted then return true, token end
		end
		if enabled and _time_activation == nil then
			local ready = set_time(ports.default_time_seconds(), token)
			if ready ~= true or not _scope.current(token) then return false, token end
		end
		if not enabled then
			_desired_enabled, _active_enabled = false, false
			_lifecycle_dirty = _owner.set_enabled(false) ~= true
			return not _lifecycle_dirty and _scope.current(token), token
		end
		_desired_enabled = true
		if reload(token) == true then return true, token end
		if _scope.current(token) then _desired_enabled = false end
		return false, token
	end

	--- Commits the canonical interval without evaluating the user factory.
	--- @param seconds number Nonnegative activation interval.
	--- @return boolean committed
	set_time = function(seconds, token)
		if not _owner or type(seconds) ~= "number" or seconds < 0 or seconds ~= seconds or seconds >= math.huge then
			return false
		end
		if _time_activation == seconds and not _lifecycle_dirty then return true end
		_lifecycle_dirty = _owner.invalidate("activation interval") ~= true
		if _lifecycle_dirty or not _scope.current(token) then return false end
		if ports.apply_time
			and (ports.apply_time(_native, seconds) ~= true or not _scope.current(token)) then
			return false
		end
		_time_activation = seconds
		return true
	end

	--- Applies an interval under this call's exact configuration operation receipt.
	--- @param seconds number Nonnegative activation interval.
	--- @return boolean committed
	--- @return table revision Revision assigned before validation or native calls.
	function module.set_time_activation(seconds)
		local token = _scope.begin()
		return set_time(seconds, token), token
	end

	--- Requests a suffix only after builtin owners declined it.
	--- @param buffer string Observed text before the magic key.
	--- @return boolean accepted
	function module.request(buffer)
		if ports.claims and _native and ports.claims(_native, buffer) then return false end
		return _owner ~= nil and _owner.request(buffer) == true
	end

	--- Returns static metadata without evaluating any callback.
	--- @param buffer string Observed text before the magic key.
	--- @return any|nil preview The static descriptor, in the shape the driver reads.
	function module.preview(buffer)
		if ports.claims and _native and ports.claims(_native, buffer) then return nil end
		local row = _owner and _owner.preview(buffer)
		if row == nil then return nil end
		if ports.preview_view then return ports.preview_view(row) end
		return row
	end

	--- Counts admitted metadata independently of the activation gate.
	--- @return number count
	function module.count() return _owner and _owner.admitted_count() or 0 end

	--- Retires pending user work at a native lifecycle transition.
	--- @param reason string Lifecycle transition.
	--- @return boolean retired
	function module.invalidate(reason)
		if not _owner then return true end
		_lifecycle_dirty = _owner.invalidate(reason) ~= true
		return not _lifecycle_dirty
	end

	--- Returns the acknowledged execution gate without invoking user code.
	--- @return boolean enabled
	function module.is_enabled() return _owner ~= nil and _active_enabled and not _lifecycle_dirty end

	--- Returns the current native activation interval.
	--- @return number|nil seconds
	function module.time_activation() return _time_activation end

	--- Retires the generation before releasing native ownership.
	--- @return boolean stopped
	function module.stop()
		if not _owner then return true end
		_scope.begin()
		_active_enabled = false
		_lifecycle_dirty = _owner.stop() ~= true
		if _lifecycle_dirty then return false end
		_owner, _native, _path, _desired_enabled = nil, nil, nil, false
		_time_activation, _problem, _problem_kind = nil, nil, nil
		return true
	end

	--- Captures native lifecycle, callbacks, source and scalar posture for a scope.
	--- @return table|nil snapshot Exact configuration inverse.
	function module.scope_snapshot() return _scope.capture() end

	--- Checks a retained inverse before any enclosing runtime or file restoration.
	--- @param snapshot table Exact configuration inverse.
	--- @return boolean current
	function module.scope_current(snapshot) return _scope.current_snapshot(snapshot) end

	--- Adopts controls only for the scope's expected operation revision.
	--- @param snapshot table Retained configuration inverse.
	--- @param seconds number Nonnegative activation interval.
	--- @param enabled boolean Requested callback gate.
	--- @return boolean adopted
	function module.scope_adopt(snapshot, seconds, enabled) return _scope.adopt(snapshot, seconds, enabled) end

	--- Restores retained callbacks without evaluating the user factory again.
	--- @param snapshot table Exact configuration inverse.
	--- @return boolean restored
	function module.scope_restore(snapshot) return _scope.restore(snapshot) end

	_scope = UserScope.new({
		identity = function() return _owner, _native end,
		read_source = function() return Source.read(ports.read, module.source_path()) end,
		source_current = function(receipt)
			return receipt.path == module.source_path() and Source.current(ports.read, receipt) == true
		end,
		policy = function() return _owner.scope_snapshot() end,
		quiescent = function() return not _lifecycle_dirty and _owner.scope_snapshot().quiescent == true end,
		seconds = function() return _time_activation end,
		enabled = module.is_enabled,
		desired = function() return _desired_enabled end,
		set_seconds = module.set_time_activation,
		set_enabled = module.set_enabled,
		restore = function(snapshot, token)
			_lifecycle_dirty = _owner.invalidate("configuration inverse") ~= true
			if _lifecycle_dirty or not _scope.current(token) then return false end
			if ports.apply_time and ports.apply_time(_native, snapshot.seconds) ~= true then return false end
			if not _scope.current(token) or _owner.scope_restore(snapshot.policy) ~= true then return false end
			if not _scope.current(token) then return false end
			_time_activation, _desired_enabled = snapshot.seconds, snapshot.desired
			_active_enabled, _lifecycle_dirty = snapshot.enabled, false
			return true
		end,
	})

	return module
end

return M
