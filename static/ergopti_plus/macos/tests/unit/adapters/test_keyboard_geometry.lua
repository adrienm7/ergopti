--- tests/unit/adapters/test_keyboard_geometry.lua

--- ==============================================================================
--- MODULE: Immutable Native Keyboard Geometry
--- DESCRIPTION:
--- Exercises the actual adapter over a JSON/event boundary without native input.
--- Missing geometry must never alias the ambiguous ISO/ANSI physical-key pair.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local MODULES = { "adapters.keyboard_geometry", "adapters.json_codec", "infra.logger" }
local ENVIRONMENT = "ERGOPTI_KEYBOARD_GEOMETRY_V1"
local PROPERTY = 42

local function map()
	return { version = 1, maximum = 32767, ranges = {
		{ first = 0, last = 0, form = "ansi" },
		{ first = 1, last = 1, form = "iso" },
		{ first = 2, last = 2, form = "jis" },
		{ first = 3, last = 32766, form = "unknown" },
		{ first = 32767, last = 32767, form = "iso" },
	} }
end

local function with_geometry(value, callback, missing_property)
	return helpers.with_fresh_modules(MODULES, function()
		local old_hs, old_getenv = hs, os.getenv
		local state = { environment = 0, decode = 0, event_reads = 0 }
		local raw = value ~= nil and Json.encode(value) or nil
		_G.hs = { json = { decode = function(text)
			state.decode = state.decode + 1
			state.decoded = Json.decode(text)
			return state.decoded
		end }, eventtap = { event = { properties = {
			keyboardEventKeyboardType = not missing_property and PROPERTY or nil,
		} } } }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		os.getenv = function(key)
			helpers.assert_eq(key, ENVIRONMENT)
			state.environment = state.environment + 1
			return raw
		end
		local result = table.pack(xpcall(function()
			local geometry = require("adapters.keyboard_geometry")
			callback(geometry, state)
		end, debug.traceback))
		_G.hs, os.getenv = old_hs, old_getenv
		if not result[1] then error(result[2], 0) end
	end)
end

helpers.describe("native keyboard geometry adapter", function()
	helpers.it("loads the complete map once and resolves exact domain boundaries", function()
		with_geometry(map(), function(owner, state)
			helpers.assert_true(owner.initialize())
			helpers.assert_eq(state.environment, 1)
			helpers.assert_eq(state.decode, 1)
			helpers.assert_eq(owner.form(0), "ansi")
			helpers.assert_eq(owner.form(1), "iso")
			helpers.assert_eq(owner.form(2), "jis")
			helpers.assert_eq(owner.form(3), "unknown")
			helpers.assert_eq(owner.form(32766), "unknown")
			helpers.assert_eq(owner.form(32767), "iso")
		end)
	end)

	helpers.it("rejects duplicate initialization without rereading its environment", function()
		with_geometry(map(), function(owner, state)
			helpers.assert_true(owner.initialize())
			local ok, reason = pcall(owner.initialize)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(reason):find("keyboard geometry is already initialized", 1, true) ~= nil)
			helpers.assert_eq(state.environment, 1)
			helpers.assert_eq(state.decode, 1)
			helpers.assert_eq(owner.form(1), "iso")
		end)
	end)

	helpers.it("leaves the ambiguous pair native before initialization and with a missing map", function()
		with_geometry(nil, function(owner, state)
			helpers.assert_nil(owner.native_code(50, 10, 0))
			helpers.assert_eq(owner.initialize(), false)
			helpers.assert_nil(owner.native_code(50, 10, 0))
			helpers.assert_nil(owner.native_code(10, 50, 1))
			helpers.assert_eq(owner.native_code(12, 12, nil), 12)
			helpers.assert_eq(state.environment, 1)
			helpers.assert_eq(state.decode, 0)
			local ok, reason = pcall(owner.initialize)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(reason):find("keyboard geometry is already initialized", 1, true) ~= nil)
			helpers.assert_eq(state.environment, 1)
		end)
	end)

	helpers.it("retains its admitted range copy after the native decoder result changes", function()
		with_geometry(map(), function(owner, state)
			helpers.assert_true(owner.initialize())
			state.decoded.ranges[1].form = "iso"
			state.decoded.ranges[2].first = 0
			helpers.assert_eq(owner.form(0), "ansi")
			helpers.assert_eq(owner.form(1), "iso")
			helpers.assert_eq(owner.native_code(50, 10, 0), 50)
		end)
	end)

	helpers.it("selects one swapped code and refuses JIS unknown and out-of-domain models", function()
		with_geometry(map(), function(owner)
			helpers.assert_true(owner.initialize())
			helpers.assert_eq(owner.native_code(50, 10, 0), 50)
			helpers.assert_eq(owner.native_code(50, 10, 1), 10)
			helpers.assert_eq(owner.native_code(10, 50, 0), 10)
			helpers.assert_eq(owner.native_code(10, 50, 1), 50)
			for _, model in ipairs({ 2, 3, -1, 32768, 65535, 1.5, "1", false }) do
				helpers.assert_nil(owner.native_code(50, 10, model), "unknown model must not gain swapped-key authority")
			end
			helpers.assert_nil(owner.native_code(50, 10, nil))
			helpers.assert_eq(owner.physical_code({ hs = 50, macos_iso = { hs = 10 } }, 1), 10)
		end)
	end)

	helpers.it("reads the actual event property and performs no environment JSON or file IO on the input path", function()
		with_geometry(map(), function(owner, state)
			helpers.assert_true(owner.initialize())
			local old_open, old_popen, old_execute = io.open, io.popen, os.execute
			local external_reads = 0
			local function forbidden() external_reads = external_reads + 1; error("event-path IO") end
			io.open, io.popen, os.execute = forbidden, forbidden, forbidden
			local result = table.pack(xpcall(function()
				local event = { getProperty = function(_, property)
					helpers.assert_eq(property, PROPERTY)
					state.event_reads = state.event_reads + 1
					return 1
				end }
				helpers.assert_eq(owner.native_code(50, 10, owner.event_type(event)), 10)
				helpers.assert_eq(state.event_reads, 1)
				helpers.assert_eq(state.environment, 1)
				helpers.assert_eq(state.decode, 1)
				helpers.assert_eq(external_reads, 0)
			end, debug.traceback))
			io.open, io.popen, os.execute = old_open, old_popen, old_execute
			if not result[1] then error(result[2], 0) end
		end)
	end)

	helpers.it("refuses missing throwing and invalid event model properties", function()
		with_geometry(map(), function(owner)
			helpers.assert_true(owner.initialize())
			helpers.assert_nil(owner.event_type(nil))
			helpers.assert_nil(owner.event_type({}))
			helpers.assert_nil(owner.event_type({ getProperty = function() error("event property refused") end }))
			for _, value in ipairs({ -1, 32768, 65535, 0.25, "40", false }) do
				helpers.assert_nil(owner.event_type({ getProperty = function() return value end }))
			end
		end)
		with_geometry(map(), function(owner)
			helpers.assert_true(owner.initialize())
			local reads = 0
			helpers.assert_nil(owner.event_type({ getProperty = function() reads = reads + 1; return 1 end }))
			helpers.assert_eq(reads, 0)
		end, true)
	end)

	for _, vector in ipairs({
		{ label = "wrong version", mutate = function(value) value.version = 2 end },
		{ label = "wrong maximum", mutate = function(value) value.maximum = 65535 end },
		{ label = "missing ranges", mutate = function(value) value.ranges = nil end },
		{ label = "empty ranges", mutate = function(value) value.ranges = {} end },
		{ label = "incomplete lower bound", mutate = function(value) value.ranges[1].first = 1 end },
		{ label = "incomplete upper bound", mutate = function(value) value.ranges[5].last = 32766 end },
		{ label = "range gap", mutate = function(value) value.ranges[4].first = 4 end },
		{ label = "range overlap", mutate = function(value) value.ranges[4].first = 2 end },
		{ label = "reversed range", mutate = function(value) value.ranges[4].last = 2 end },
		{ label = "fractional model", mutate = function(value) value.ranges[4].last = 32766.5 end },
		{ label = "unknown form", mutate = function(value) value.ranges[1].form = "fallback" end },
		{ label = "unfused adjacent ranges", mutate = function(value) value.ranges[2].form = "ansi" end },
		{ label = "unexpected envelope field", mutate = function(value) value.authority = true end },
		{ label = "unexpected range field", mutate = function(value) value.ranges[1].authority = true end },
	}) do
		helpers.it("refuses " .. vector.label .. " without admitting ambiguous keys", function()
			local value = map()
			vector.mutate(value)
			with_geometry(value, function(owner)
				helpers.assert_eq(owner.initialize(), false)
				helpers.assert_nil(owner.native_code(50, 10, 0))
				helpers.assert_nil(owner.native_code(10, 50, 1))
			end)
		end)
	end

	helpers.it("refuses a native JSON null hole after a complete prefix without ignoring retained tail rows", function()
		local value = assert(Json.decode_lossless([[{"version":1,"maximum":32767,"ranges":[
			{"first":0,"last":32767,"form":"ansi"},null,
			{"first":0,"last":32767,"form":"iso"},
			{"first":0,"last":32767,"form":"jis"}]}]]))
		with_geometry(value, function(owner, state)
			-- LuaSkin's native array bridge erases JSON null to nil. The real
			-- JsonCodec.as_tree still copies its retained numeric tail via pairs.
			local function native_value(item)
				if Json.is_null(item) then return nil end
				if type(item) ~= "table" then return item end
				local copy = {}
				for key, nested in pairs(item) do copy[key] = native_value(nested) end
				return copy
			end
			hs.json.decode = function(raw)
				state.decode = state.decode + 1
				return native_value(assert(Json.decode_lossless(raw)))
			end
			local decoded, detail = require("adapters.json_codec").decode(Json.encode(value))
			helpers.assert_nil(detail)
			helpers.assert_eq(#decoded.ranges, 4, "the actual adapter copy must reach the old length-census branch")
			helpers.assert_nil(decoded.ranges[2])
			helpers.assert_eq(decoded.ranges[1].last, 32767)
			helpers.assert_eq(decoded.ranges[3].form, "iso")
			helpers.assert_eq(decoded.ranges[4].form, "jis")
			helpers.assert_eq(getmetatable(decoded.ranges), nil, "no synthetic length metatable participates")
			helpers.assert_eq(owner.initialize(), false)
			helpers.assert_eq(state.environment, 1)
			helpers.assert_eq(state.decode, 2)
			helpers.assert_nil(owner.native_code(50, 10, 0))
		end)
	end)
end)
