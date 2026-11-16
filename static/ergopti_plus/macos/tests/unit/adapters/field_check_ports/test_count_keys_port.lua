--- tests/unit/adapters/field_check_ports/test_count_keys_port.lua

--- ==============================================================================
--- MODULE: Field Check Key Counter Port (macOS)
--- DESCRIPTION:
--- The passive key counter sorts every key-down it counts by provenance, read
--- without claiming the event: the 2026-11-15 field run saw 12 presses for the
--- typing selftest's 4 keys, and the bare total could not say whether one key
--- was delivered three times or the driver's own output was counted too.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "core.logger.engine.logger", "adapters.field_check_ports", "core.events.timer_scheduler",
	"adapters.event_provenance" }

--- A fake key-down whose provenance the stubbed classifier reads from it.
--- @param provenance table { status, metadata }.
--- @param autorepeat boolean|nil True for an autorepeat.
--- @return table event
local function key_down(provenance, autorepeat)
	return {
		provenance = provenance,
		getProperty = function(_, property)
			if property == hs.eventtap.event.properties.keyboardEventAutorepeat then return autorepeat and 1 or 0 end
			return nil
		end,
	}
end

helpers.describe("field check key counter", function()
	helpers.it("(key-count-classes-2026-11-15) names repeated selftest deliveries apart from other events", function()
		helpers.with_stub_scope(MODULES, function()
			package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
			local claims = {}
			package.loaded["adapters.event_provenance"] = {
				STATUS_OWNED = "owned", STATUS_FOREIGN = "foreign", STATUS_UNREADABLE = "unreadable",
				classify = function(event, consumer_id)
					claims[#claims + 1] = consumer_id == nil and "read" or consumer_id
					if event.provenance.raises then error("unreadable user data") end
					return event.provenance.metadata, event.provenance.status
				end,
			}
			local finish = nil
			package.loaded["core.events.timer_scheduler"] = {
				after = function(_, fn) finish = fn; return {}, true end, cancel = function() return true end,
			}
			local tap_fn = nil
			local real_new = hs.eventtap.new
			hs.eventtap.new = function(types, fn)
				tap_fn = fn
				return real_new(types, fn)
			end
			local ok, err = pcall(function()
				package.loaded["adapters.field_check_ports"] = nil
				local counted = nil
				require("adapters.field_check_ports").count_keys(6, function(counts) counted = counts end)
				helpers.assert_true(type(tap_fn) == "function", "the counter installs a tap")
				local selftest = function(tag)
					return { status = "owned", metadata = { selftest = true, tag = tag } }
				end
				-- One selftest key delivered three times, another once, the driver's
				-- own output, a foreign key, an unreadable one and an autorepeat.
				for _, provenance in ipairs({ selftest(7), selftest(7), selftest(7), selftest(9),
					{ status = "owned", metadata = { selftest = false, tag = 11 } },
					{ status = "foreign" }, { raises = true } }) do
					helpers.assert_eq(tap_fn(key_down(provenance)), false, "the counter never consumes an event")
				end
				helpers.assert_eq(tap_fn(key_down({ status = "foreign" }, true)), false)
				finish()
				helpers.assert_true(type(counted) == "table")
				helpers.assert_eq(counted.tap_running, true)
				helpers.assert_eq(counted.presses, 7, "an autorepeat is not a press")
				helpers.assert_eq(counted.autorepeats, 1)
				helpers.assert_eq(counted.selftest, 4, "every delivery of a selftest key is counted")
				helpers.assert_eq(counted.selftest_distinct, 2, "a key delivered three times is one key")
				helpers.assert_eq(counted.owned, 1)
				helpers.assert_eq(counted.foreign, 1)
				helpers.assert_eq(counted.unreadable, 1)
				for _, claim in ipairs(claims) do
					helpers.assert_eq(claim, "read", "the counter must never claim a consumer's dedupe slot")
				end
			end)
			hs.eventtap.new = real_new
			if not ok then error(err, 0) end
		end)
	end)
end)
