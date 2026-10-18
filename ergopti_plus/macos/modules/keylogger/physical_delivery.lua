--- modules/keylogger/physical_delivery.lua

--- Delivers decoded physical batches under an explicitly admitted capture owner.
--- Transport framing, native coverage admission and timestamp context belong to callers.
local M = {}
local Wire = require("modules.keylogger.physical_wire")
local Baseline = require("modules.keylogger.physical_baseline")
local Protocol = require("modules.keylogger.physical_protocol")
local Release = require("keylogger.physical_release")
local Position = require("keylogger.physical_position_observation")
local decimal, successor = Wire.decimal, Wire.successor

--- Orders uncounted tally rows by page, usage, keyboard type and reason.
---@param left table Tally row.
---@param right table Tally row.
---@return boolean
local function tally_order(left, right)
	if left.page ~= right.page then return left.page < right.page end
	if left.usage ~= right.usage then return left.usage < right.usage end
	if left.keyboard_type ~= right.keyboard_type then return left.keyboard_type < right.keyboard_type end
	return left.reason < right.reason
end

--- Creates a single-use receiver; a stopped or failed owner cannot be reopened.
--- The keycode callback receives the usage page, the usage, the device's keyboard
--- type and the exact decimal device identity; it returns the macOS keycode, or
--- nil and the reason the press cannot be attributed. An unattributed press is
--- tallied as uncounted coverage, never guessed and never a reason to retire the
--- capture.
--- Explicit holds ports enable matching; legacy diagnostic callers remain press-only.
--- Production capture always supplies convert, interval context and exact-true release emit.
---@param dependencies table admit, context, keycode and emit; batch_limit; optional holds, media and baseline_ready ports.
---@return table receiver
function M.new(dependencies)
	local ports = {}
	for _, name in ipairs({ "admit", "context", "keycode", "emit" }) do
		assert(type(dependencies[name]) == "function", "Missing physical delivery callback: " .. name)
		ports[name] = dependencies[name]
	end
	local baseline_ready = rawget(dependencies, "baseline_ready")
	assert(baseline_ready == nil or type(baseline_ready) == "function", "Invalid physical baseline observer")
	ports.baseline_ready = baseline_ready
	local limit = dependencies.batch_limit
	assert(type(limit) == "number" and limit >= 1 and limit % 1 == 0, "Invalid physical batch limit")
	local state, ownership, sequence = "new", nil, "0"
	local initial
	local held = {}
	local hold_ports
	if dependencies.holds ~= nil then
		assert(type(dependencies.holds) == "table", "Invalid physical hold capability")
		hold_ports = {}
		for _, name in ipairs({ "convert", "context", "emit" }) do
			assert(type(dependencies.holds[name]) == "function", "Missing physical hold port: " .. name)
			hold_ports[name] = dependencies.holds[name]
		end
	end
	local media_ports
	if dependencies.media ~= nil then
		assert(type(dependencies.media) == "table", "Invalid semantic media capability")
		media_ports = {}
		for _, name in ipairs({ "resolve", "is_known", "emit" }) do
			assert(type(dependencies.media[name]) == "function", "Missing semantic media port: " .. name)
			media_ports[name] = dependencies.media[name]
		end
		local emit_release = rawget(dependencies.media, "emit_release")
		assert((emit_release == nil or type(emit_release) == "function")
			and (hold_ports == nil or type(emit_release) == "function"), "Missing semantic media release port")
		media_ports.emit_release = emit_release
	end
	local uncounted = {}
	local receiver = {}
	local observation
	local retired = setmetatable({}, { __mode = "k" })

	local function retire_observation(record)
		if record and record.frames == 0 and record.cancelled then
			if observation == record then observation = nil end
			retired[record.token] = true
		end
	end

	local function revoke_observation()
		if observation then
			observation.cancelled = true
			retire_observation(observation)
		end
	end

	--- Reports original baseline admission without creating a request or native task.
	function receiver.position_available()
		return (state == "active" or state == "delivering") and observation == nil
			and initial ~= nil and initial.position_available() == true
	end

	--- Enrolls one observational request without replacing metric publication ports.
	---@param exact_current function Literal true while the original editor remains current.
	---@param receive function Receives closed detached facts; native identity stays private.
	---@return table|nil token Exact opaque request, never a native transport token.
	function receiver.capture_position(exact_current, receive)
		if type(exact_current) ~= "function" or type(receive) ~= "function"
			or not receiver.position_available() then return nil end
		local record = { token = {}, exact = exact_current, receive = receive, frames = 1 }
		observation = record
		local called, accepted = pcall(exact_current)
		record.frames = 0
		if not called or accepted ~= true or observation ~= record
			or state ~= "active" and state ~= "delivering" or record.cancelled then
			record.cancelled = true
			retire_observation(record)
			return nil
		end
		return record.token
	end

	--- Revokes one exact request now; callback unwind remains acknowledged retry debt.
	---@param token table Original request identity.
	---@return boolean retired Literal true only after its publication frames unwind.
	function receiver.cancel_position(token)
		if type(token) ~= "table" then return false end
		if retired[token] then return true end
		local record = observation
		if not record or not rawequal(record.token, token) then return false end
		record.cancelled = true
		retire_observation(record)
		return retired[token] == true
	end

	local function publish_position(record, prepared)
		if not record or observation ~= record or record.cancelled or record.completed or record.frames > 0 then return end
		for _, press in ipairs(prepared) do
			if observation ~= record or record.cancelled or record.completed or state ~= "active" then break end
			local facts = Position.facts(press)
			if facts then
				record.frames = record.frames + 1
				local called, current = pcall(record.exact)
				if not called or current ~= true then record.cancelled = true end
				if observation == record and not record.cancelled and not record.completed and state == "active" then
					-- One primary press consumes the request, even if the editor refuses it.
					record.completed = true
					pcall(record.receive, facts)
					local checked, still_current = pcall(record.exact)
					if not checked or still_current ~= true then record.cancelled = true end
				end
				record.frames = record.frames - 1
				retire_observation(record)
			end
		end
	end

	--- Returns whether this receiver still owns delivery.
	---@return boolean
	function receiver.active()
		return state == "baselining" or state == "completing" or state == "active" or state == "delivering"
	end

	--- Reports completed initial-state admission, including an owned batch delivery.
	--- During a completion observer this reports the real baseline for exact scope pulls;
	--- raw batch delivery remains fenced until its literal-true acknowledgement.
	--- Opening state alone cannot authorize a history adapter or physical credit.
	---@return boolean ready Whether this exact receiver completed its baseline.
	function receiver.ready() return state == "completing" or state == "active" or state == "delivering" end

	--- Revokes delivery before any successor capture can begin.
	function receiver.stop()
		revoke_observation()
		state, ownership, initial, held = "stopped", nil, nil, {}
	end

	--- Reports the presses delivered but not credited, for the capture's coverage.
	--- Only fully committed batches are included, and privacy-excluded presses never are.
	---@return table rows { page, usage, keyboard_type, reason, count } in a stable order.
	function receiver.uncounted()
		local rows = {}
		for _, entry in pairs(uncounted) do
			rows[#rows + 1] = { page = entry.page, usage = entry.usage,
				keyboard_type = entry.keyboard_type, reason = entry.reason, count = entry.count }
		end
		table.sort(rows, tally_order)
		return rows
	end

	--- Admits a producer envelope through the caller's coverage and privacy owner.
	---@param frame table Decoded opened frame.
	function receiver.open(frame)
		assert(state == "new", "Physical receiver cannot reopen")
		state = "failed"
		assert(type(frame) == "table" and frame.kind == "opened"
			and type(frame.incarnation) == "string" and frame.incarnation ~= ""
			and type(frame.coverage) == "string", "Invalid physical opening envelope")
		Protocol.require_version("opening", frame.version, Protocol.OPENING_VERSION)
		decimal(frame.lease, true)
		initial = Baseline.new(frame.baseline)
		local owner = { incarnation = frame.incarnation, lease = frame.lease, coverage = frame.coverage }
		local capture = ports.admit(frame)
		assert(type(capture) == "string" and capture ~= "", "Physical coverage was not admitted")
		assert(state == "failed", "Physical admission was revoked")
		owner.capture = capture
		ownership = owner
		state = "baselining"
	end

	--- Receives initial-state pages before raw delivery can publish any credit.
	---@param frame table Baseline page or completion marker.
	---@return string|nil cursor Page cursor to acknowledge; completion needs no receipt.
	function receiver.baseline(frame)
		local ok, result = pcall(function()
			assert(state == "baselining", "Physical baseline is not pending")
			assert(type(frame) == "table" and frame.version == 1
				and frame.incarnation == ownership.incarnation and frame.lease == ownership.lease
				and frame.coverage == ownership.coverage, "Physical capture ownership changed or ended")
			local cursor = initial.accept(frame)
			if initial.ready() then
				if ports.baseline_ready then
					local owner = ownership
					state = "completing"
					local accepted = ports.baseline_ready()
					assert(state == "completing" and ownership == owner, "Physical baseline completion was revoked")
					assert(accepted == true, "Physical baseline observer refused completion")
				end
				state = "active"
			end
			return cursor
		end)
		if not ok then revoke_observation(); state, ownership, initial, held = "failed", nil, nil, {}; error(result, 0) end
		return result
	end

	--- Validates the entire batch before publishing any physical press.
	--- A callback failure fences this owner rather than replaying partial publication.
	---@param frame table Decoded batch from the admitted producer session.
	---@return string sequence Last fully committed sequence, suitable for acknowledgement.
	function receiver.deliver(frame)
		if state ~= "active" then
			revoke_observation()
			state, ownership, initial, held = "failed", nil, nil, {}
			error("Physical receiver is not active")
		end
		local owner, request = ownership, observation
		local observations = {}
		state = "delivering"
		local ok, err = pcall(function()
			assert(type(frame) == "table" and frame.version == 1 and frame.kind == "batch"
				and frame.incarnation == owner.incarnation and frame.lease == owner.lease
				and frame.coverage == owner.coverage, "Physical capture ownership changed or ended")
			assert(type(frame.records) == "table" and #frame.records <= limit, "Invalid physical batch")
			local length = #frame.records
			for key in pairs(frame.records) do
				assert(type(key) == "number" and key % 1 == 0 and key >= 1 and key <= length,
					"Physical batch must be a dense array")
			end
			local next_sequence, prepared, pending, pending_uncounted = sequence, {}, {}, {}
			-- Freeze and qualify the whole native batch before invoking any mapping,
			-- privacy or clock callback. A callback cannot repair or rewrite a later row.
			for index = 1, length do
				local row = frame.records[index]
				assert(type(row) == "table", "Missing physical record")
				decimal(row.sequence, true)
				assert(row.sequence == successor(next_sequence), "Physical sequence gap or replay")
				next_sequence = row.sequence
				decimal(row.device, true)
				decimal(row.timestamp, false)
				assert(type(row.has_page) == "boolean" and type(row.has_usage) == "boolean"
					and type(row.page) == "number" and type(row.usage) == "number"
					and row.page % 1 == 0 and row.usage % 1 == 0, "Invalid physical usage")
				local transition = initial.transition(row)
				local element = { device = row.device, cookie = row.cookie, timestamp = row.timestamp,
					page = row.page, usage = row.usage, transition = transition }
				if transition == "press" then
					element.keyboard_type = initial.keyboard_type(element.device)
					if request then element.held = initial.held_keys() end
				end
				prepared[#prepared + 1] = element
			end
			for _, element in ipairs(prepared) do
				local transition = element.transition
				if transition == "press" then
					local keyboard_type = element.keyboard_type
					local keycode, reason = ports.keycode(element.page, element.usage, keyboard_type, element.device)
					assert(state == "delivering" and ownership == owner, "Physical delivery was revoked")
					if keycode ~= nil then
						assert(type(keycode) == "number" and keycode >= 0 and keycode % 1 == 0,
							"Invalid physical keycode")
					else
						assert(type(reason) == "string" and reason ~= "", "Uncounted physical usage has no reason")
					end
					local media_id
					if keycode == nil and media_ports then
						media_id = media_ports.resolve(element.page, element.usage, keyboard_type, element.device)
						assert(state == "delivering" and ownership == owner, "Physical delivery was revoked")
						if media_id ~= nil then
							assert(type(media_id) == "string" and media_id:match("^media%.[a-z][a-z_]+$")
								and media_ports.is_known(media_id) == true,
								"Invalid semantic media identity")
							assert(state == "delivering" and ownership == owner, "Physical delivery was revoked")
						end
					end
					local context = ports.context(element.timestamp, element.device)
					assert(state == "delivering" and ownership == owner, "Physical delivery was revoked")
					assert(type(context) == "table" and type(context.allowed) == "boolean",
						"Physical event context is unavailable")
					if context.allowed then
						if request and keycode ~= nil then
							observations[#observations + 1] = { device = element.device, cookie = element.cookie,
								page = element.page, usage = element.usage, keyboard_type = keyboard_type,
								keycode = keycode, held = element.held }
						end
						if keycode == nil and media_id == nil then
							pending_uncounted[#pending_uncounted + 1] = { page = element.page, usage = element.usage,
								keyboard_type = keyboard_type, reason = reason }
						else
							assert(type(context.app) == "string" and context.app ~= ""
								and type(context.timestamp) == "string" and context.timestamp ~= "",
								"Physical event context is incomplete")
							local press = { capture = owner.capture, device = element.device,
								keycode = keycode, media_id = media_id, app = context.app, timestamp = context.timestamp }
							pending[#pending + 1] = { entry = press, kind = "press", media = media_id ~= nil }
							if hold_ports then
								local observed_ns = hold_ports.convert(element.timestamp)
								assert(state == "delivering" and ownership == owner, "Physical delivery was revoked")
								assert(math.type(observed_ns) == "integer" and observed_ns >= 0, "Invalid physical hold clock")
								local device = held[element.device] or {}
								assert(not device[element.cookie], "Physical hold already owns the element")
								device[element.cookie] = { capture = press.capture, device = press.device, keycode = press.keycode,
									media_id = media_id, app = press.app, timestamp = press.timestamp, ticks = element.timestamp, observed_ns = observed_ns }
								held[element.device] = device
							end
						end
					end
				elseif transition == "release" and hold_ports then
					local device = held[element.device]
					local press = device and device[element.cookie]
					if press then
						device[element.cookie] = nil
						local released_ns = hold_ports.convert(element.timestamp)
						assert(state == "delivering" and ownership == owner, "Physical delivery was revoked")
						assert(math.type(released_ns) == "integer" and released_ns >= press.observed_ns,
							"Invalid physical hold clock")
						local context = hold_ports.context(press.ticks, element.timestamp, element.device)
						assert(state == "delivering" and ownership == owner, "Physical delivery was revoked")
						assert(type(context) == "table" and type(context.allowed) == "boolean", "Physical hold interval is unavailable")
						if context.allowed then
							pending[#pending + 1] = { kind = "release", media = press.media_id ~= nil, entry = { capture = press.capture,
								device = press.device, keycode = press.keycode, media_id = press.media_id, app = press.app, timestamp = press.timestamp,
								hold_ms = Release.duration((released_ns - press.observed_ns) // 1000000) } }
						end
					end
				end
			end
			for _, event in ipairs(pending) do
				assert(state == "delivering" and ownership == owner, "Physical delivery was revoked")
				local emit
				if event.media then emit = event.kind == "press" and media_ports.emit or media_ports.emit_release
				else emit = event.kind == "press" and ports.emit or hold_ports.emit end
				local accepted = emit(event.entry)
				assert(state == "delivering" and ownership == owner, "Physical delivery was revoked")
				assert(accepted == true, "Physical sink refused the " .. event.kind)
			end
			assert(state == "delivering" and ownership == owner, "Physical delivery was revoked")
			for _, press in ipairs(pending_uncounted) do
				local key = table.concat({ press.reason, press.page, press.usage, press.keyboard_type }, ":")
				local entry = uncounted[key]
				if not entry then
					entry = { page = press.page, usage = press.usage, keyboard_type = press.keyboard_type,
						reason = press.reason, count = 0 }
					uncounted[key] = entry
				end
				entry.count = entry.count + 1
			end
			sequence = next_sequence
		end)
		if not ok then
			revoke_observation()
			state, ownership, initial, held = "failed", nil, nil, {}
			error(err, 0)
		end
		state = "active"
		-- Observer failures never invalidate the already committed metric batch.
		-- The request was captured before intake, so reentrant enrollment is not fresh.
		local committed = sequence
		publish_position(request, observations)
		return committed
	end

	return receiver
end

return M
