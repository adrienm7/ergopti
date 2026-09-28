--- linux/tests/unit/meta/test_update_schedule_vectors.lua

--- ==============================================================================
--- MODULE: Update-Check Schedule Vectors (Linux)
--- DESCRIPTION:
--- Replays _shared/modules/updater/schedule_vectors.json through the shared Lua
--- port (updater.schedule) with the real timing of defaults.json. The
--- JavaScript module and the AHK port replay the same file, so the drivers
--- cannot disagree on when an automatic check is due, how a retired interval
--- snaps, or how a check updates the persisted record.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local SHARED = helpers.driver_root() .. "/../_shared/modules/updater/"

local function read_json(name)
	local handle = assert(io.open(SHARED .. name, "rb"))
	local raw = handle:read("*a")
	handle:close()
	return assert(Json.decode(raw), name .. " must decode")
end

local function load_schedule()
	package.loaded["updater.schedule"] = nil
	return require("updater.schedule")
end

--- Compares two flat records key by key.
local function same_record(a, b)
	for key, value in pairs(a) do
		if b[key] ~= value then return false end
	end
	for key, value in pairs(b) do
		if a[key] ~= value then return false end
	end
	return true
end

local function describe_record(record)
	local keys = {}
	for key in pairs(record) do keys[#keys + 1] = key end
	table.sort(keys)
	local parts = {}
	for _, key in ipairs(keys) do parts[#parts + 1] = key .. "=" .. tostring(record[key]) end
	return "{" .. table.concat(parts, ", ") .. "}"
end

helpers.describe("updater.schedule — shared vectors (Linux)", function()
	local vectors = read_json("schedule_vectors.json")
	local timing = read_json("defaults.json").timing
	local Schedule = load_schedule()

	helpers.it("accepts the timing of defaults.json", function()
		local ok, err = Schedule.validate_timing(timing)
		helpers.assert_true(ok == true, "timing must validate: " .. tostring(err))
	end)

	helpers.it("decides every due vector like the other drivers", function()
		helpers.assert_true(#vectors.due >= 15, "the due vectors must be present")
		for _, v in ipairs(vectors.due) do
			local due_at, reason = Schedule.next_due({
				now = v.now, started_at = v.started_at, interval = v.interval,
				state = v.state, timing = timing,
			})
			helpers.assert_eq(reason, v.expect.reason, "due vector " .. v.id .. " reason")
			helpers.assert_eq(due_at, v.expect.due_at, "due vector " .. v.id .. " due_at")
		end
	end)

	helpers.it("computes the same deterministic jitter", function()
		helpers.assert_true(#vectors.jitter >= 8, "the jitter vectors must be present")
		for _, v in ipairs(vectors.jitter) do
			helpers.assert_eq(Schedule.jitter_seconds(v.seed, v.anchor, v.interval, timing), v.expect,
				"jitter vector " .. v.id)
		end
	end)

	helpers.it("snaps retired intervals to the nearest preset", function()
		helpers.assert_true(#vectors.snap >= 10, "the snap vectors must be present")
		for _, v in ipairs(vectors.snap) do
			local seconds, code, snapped = Schedule.snap_interval(v.seconds, timing)
			helpers.assert_eq(seconds, v.expect, "snap vector " .. v.id .. " seconds")
			helpers.assert_eq(code, v.code, "snap vector " .. v.id .. " code")
			helpers.assert_eq(snapped, v.snapped, "snap vector " .. v.id .. " snapped")
		end
	end)

	helpers.it("keeps only the valid fields of a stored record", function()
		helpers.assert_true(#vectors.sanitize >= 6, "the sanitize vectors must be present")
		for _, v in ipairs(vectors.sanitize) do
			local state, dropped = Schedule.sanitize_state(v.raw)
			helpers.assert_true(same_record(state, v.expect),
				"sanitize vector " .. v.id .. ": got " .. describe_record(state))
			helpers.assert_eq(dropped, v.dropped, "sanitize vector " .. v.id .. " dropped")
		end
	end)

	helpers.it("records a check without touching the given record", function()
		helpers.assert_true(#vectors.record >= 4, "the record vectors must be present")
		for _, v in ipairs(vectors.record) do
			local before = describe_record(v.state)
			local next_state = Schedule.record_check(v.state, v.now, v.ok)
			helpers.assert_true(same_record(next_state, v.expect),
				"record vector " .. v.id .. ": got " .. describe_record(next_state))
			helpers.assert_eq(describe_record(v.state), before, "record vector " .. v.id .. " mutated its input")
		end
	end)

	helpers.it("bounds every timer by the re-evaluation period", function()
		helpers.assert_true(#vectors.delay >= 4, "the delay vectors must be present")
		for _, v in ipairs(vectors.delay) do
			helpers.assert_eq(Schedule.delay_until(v.due_at, v.now, timing), v.expect, "delay vector " .. v.id)
		end
	end)

	helpers.it("refuses a preset list without the never preset", function()
		local broken = read_json("defaults.json").timing
		table.remove(broken.check_interval_presets)
		local ok, err = Schedule.validate_timing(broken)
		helpers.assert_true(ok ~= true, "a preset list without never must be refused")
		helpers.assert_contains(tostring(err), "never")
	end)
end)
