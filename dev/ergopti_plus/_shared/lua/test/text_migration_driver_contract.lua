--- _shared/lua/test/text_migration_driver_contract.lua

--- ==============================================================================
--- MODULE: Typed-Text Migration Driver Surface Contract
--- DESCRIPTION:
--- Drives keystats/text_migration_driver over scripted ports, once for the
--- unsliced Linux shape (the owner ticks pump()) and once for the sliced macOS
--- shape (a scheduler arms each slice), and pins the shared batch composition
--- that both drivers' backends rely on. Both drivers replay these cases.
--- ==============================================================================

local M = {}

--- Registers the contract cases.
--- @param helpers table The driver's test helpers.
function M.register(helpers)
	local Driver = require("keystats.text_migration_driver")
	local Plan = require("keystats.text_migration")
	local TextCrypto = require("keystats.text_crypto")

	local IV = string.rep("a", TextCrypto.IV_HEX_LENGTH or 32)
	local DEVICE = "local-device"

	local function quiet_logger()
		local logger = {}
		for _, level in ipairs({ "start", "success", "info", "debug", "warn", "error" }) do
			logger[level] = function() end
		end
		return logger
	end

	local cipher = {
		encrypt = function(_, _, value) return TextCrypto.wrap(IV, "w:" .. value) end,
		decrypt = function(value) return (value:gsub("^.*w:", "")) end,
	}

	--- An in-memory backend over `count` rows, recording the devices it saw.
	local function backend(count)
		local rows = {}
		for id = 1, count do rows[id] = { id = id, values = { text = "t" .. id, events_json = "[" .. id .. "]" } } end
		local store = { rows = rows, devices = {}, cursor = nil }
		store.port = {
			available = function() return true end,
			count = function() return #rows end,
			get_cursor = function() return store.cursor end,
			-- Both real backends acknowledge committed cursor writes explicitly.
			set_cursor = function(value) store.cursor = value; return true end,
			fetch = function(device, after, limit)
				store.devices[#store.devices + 1] = device
				local out = {}
				for _, row in ipairs(rows) do
					if row.id > after and #out < limit then out[#out + 1] = row end
				end
				return out
			end,
			apply = function(_, updates)
				for _, update in ipairs(updates) do
					for _, assignment in ipairs(update.assignments) do
						rows[update.id].values[assignment.name] = assignment.value
					end
				end
				return true
			end,
		}
		return store
	end

	--- A scheduler that queues callbacks and runs them on demand.
	local function scheduler()
		local queue, cancelled = {}, 0
		local double = { queue = queue, gap_sec = 0.05 }
		double.after = function(_, fn)
			local handle = { fn = fn }
			queue[#queue + 1] = handle
			return handle
		end
		double.cancel = function(handle)
			handle.dead = true
			cancelled = cancelled + 1
			return true
		end
		double.cancelled = function() return cancelled end
		--- Runs queued slices until none is left alive.
		double.run = function()
			local guard = 0
			while true do
				local handle
				for index, candidate in ipairs(queue) do
					if not candidate.dead then handle = candidate; table.remove(queue, index); break end
				end
				if not handle then return guard end
				guard = guard + 1
				assert(guard < 50, "the slices never ended")
				handle.fn()
			end
		end
		return double
	end

	local function build(store, extra)
		local ports = { logger = quiet_logger(), log_tag = "TEST", cipher = cipher, backend = store.port }
		for name, value in pairs(extra or {}) do ports[name] = value end
		return assert(Driver.new(ports))
	end

	helpers.describe("typed-text migration driver surface (text-migration-driver-contract)", function()
		helpers.it("(text-migration-driver-contract) is built only from complete ports", function()
			helpers.assert_eq(Driver.new(nil), nil)
			helpers.assert_eq(Driver.new({}), nil, "no logger, cipher or backend")
			local store = backend(1)
			local module, err = Driver.new({ logger = quiet_logger(), log_tag = "T", cipher = cipher,
				backend = store.port, scheduler = { after = function() end } })
			helpers.assert_eq(module, nil)
			helpers.assert_contains(err, "scheduler")
		end)

		helpers.it("(text-migration-driver-contract) unsliced: the owner pumps and nothing is scheduled", function()
			local store = backend(450)
			local module = build(store)
			helpers.assert_eq(module.start_for_posture, nil, "no posture entry point without a scheduler")
			helpers.assert_true(module.start(Plan.MODE_ENCRYPT, DEVICE))
			local pumps = 0
			while module.pump() do
				pumps = pumps + 1
				assert(pumps < 50, "the pass never finished")
			end
			helpers.assert_eq(module.is_running(), false)
			helpers.assert_true(TextCrypto.is_encrypted(store.rows[450].values.text))
			helpers.assert_eq(store.devices[1], DEVICE)
		end)

		helpers.it("(text-migration-driver-contract) sliced: each slice arms the next until the pass ends", function()
			local store = backend(450)
			local clock = scheduler()
			local module = build(store, {
				scheduler = clock, device_id = function() return "writer-device" end,
			})
			helpers.assert_true(module.start(Plan.MODE_ENCRYPT))
			helpers.assert_eq(#clock.queue, 1, "the first slice is armed by start")
			local slices = clock.run()
			helpers.assert_true(slices >= 2, "a 450-row history takes several slices")
			helpers.assert_eq(module.is_running(), false)
			helpers.assert_true(TextCrypto.is_encrypted(store.rows[1].values.text))
			helpers.assert_eq(store.devices[1], "writer-device", "the device defaults to the port's")
		end)

		helpers.it("(text-migration-driver-contract) sliced: cancel stops the armed slice and keeps the cursor", function()
			local store = backend(450)
			local clock = scheduler()
			local module = build(store, { scheduler = clock, device_id = function() return DEVICE end })
			helpers.assert_true(module.start(Plan.MODE_ENCRYPT))
			table.remove(clock.queue, 1).fn()
			module.cancel()
			helpers.assert_eq(module.is_running(), false)
			helpers.assert_eq(clock.run(), 0, "no slice survives a cancel")
			helpers.assert_eq(store.cursor, "encrypt:" .. Plan.DEFAULT_BATCH_SIZE)
			helpers.assert_true(TextCrypto.is_encrypted(store.rows[1].values.text), "converted rows stay converted")
			helpers.assert_eq(TextCrypto.is_encrypted(store.rows[450].values.text), false)
		end)

		helpers.it("(text-migration-driver-contract) sliced: restarting cancels the previous pass first", function()
			local store = backend(450)
			local clock = scheduler()
			local module = build(store, { scheduler = clock, device_id = function() return DEVICE end })
			helpers.assert_true(module.start(Plan.MODE_ENCRYPT))
			local first = clock.queue[1]
			helpers.assert_true(module.start(Plan.MODE_ENCRYPT))
			helpers.assert_true(first.dead, "the first pass's slice was cancelled")
		end)

		helpers.it("(text-migration-driver-contract) sliced: a posture picks the direction and resume needs an unfinished pass", function()
			local store = backend(3)
			local clock = scheduler()
			local module = build(store, { scheduler = clock, device_id = function() return DEVICE end })
			helpers.assert_eq(module.resume_for_posture(true), false, "nothing unfinished to resume")
			helpers.assert_true(module.start_for_posture(true))
			clock.run()
			helpers.assert_true(TextCrypto.is_encrypted(store.rows[1].values.text))
			helpers.assert_true(module.start_for_posture(false))
			clock.run()
			helpers.assert_eq(store.rows[1].values.text, "t1", "decrypt restores the original bytes")
		end)

		helpers.it("(text-migration-driver-contract) the backend seam swaps and restores the real backend", function()
			local real, fake = backend(2), backend(2)
			local module = build(real)
			module._set_backend(fake.port)
			helpers.assert_true(module.start(Plan.MODE_ENCRYPT, DEVICE))
			while module.pump() do end
			helpers.assert_true(TextCrypto.is_encrypted(fake.rows[1].values.text))
			helpers.assert_eq(real.rows[1].values.text, "t1", "the real backend was not touched")
			module._set_backend(nil)
			helpers.assert_true(module.start(Plan.MODE_ENCRYPT, DEVICE))
			while module.pump() do end
			helpers.assert_true(TextCrypto.is_encrypted(real.rows[1].values.text))
		end)

		helpers.it("(text-migration-driver-contract) a batch with one row without a statement is refused whole", function()
			local statements, refused = Plan.update_statements(DEVICE, {
				{ id = 1, assignments = { { name = "text", value = "x" } } },
				{ id = 2, assignments = {} },
			})
			helpers.assert_eq(statements, nil)
			helpers.assert_eq(refused, 2)
			local bad_column = Plan.update_statements(DEVICE, {
				{ id = 3, assignments = { { name = "total_count", value = "x" } } },
			})
			helpers.assert_eq(bad_column, nil, "an aggregate column is never written")
			local ok = Plan.update_statements(DEVICE, {
				{ id = 1, assignments = { { name = "text", value = "a'b" } } },
				{ id = 2, assignments = { { name = "text", value = "c" } } },
			})
			helpers.assert_eq(#ok, 2)
			helpers.assert_contains(ok[1], "a''b")
		end)
	end)
end

return M
