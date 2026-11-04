--- _shared/lua/test/feature_notice_contract.lua

--- ==============================================================================
--- MODULE: Feature And Refusal Notices Contract
--- DESCRIPTION:
--- Proves the one behaviour the macOS and Linux menus share for a feature switch
--- notice and for the quit refusal: the log line, the success/error level, the
--- survival of a failing notifier, and the presence of the strings in every
--- locale.
--- ==============================================================================

return function(helpers, json, shared_root)
	local FeatureNotice = require("feature_notice")

	--- Builds ports that record every call.
	--- @param send_behaviour function|nil Replaces the send port.
	--- @return table ports, table record
	local function recording_ports(send_behaviour)
		local record = { sent = {}, info = {}, warn = {} }
		return {
			send = send_behaviour or function(text, level)
				record.sent[#record.sent + 1] = { text = text, level = level }
				return true
			end,
			info = function(fmt, ...) record.info[#record.info + 1] = string.format(fmt, ...) end,
			warn = function(fmt, ...) record.warn[#record.warn + 1] = string.format(fmt, ...) end,
		}, record
	end

	helpers.describe("Feature and refusal notices", function()
		helpers.it("sends a success notice and logs the switch when a feature is enabled", function()
			local ports, record = recording_ports()
			FeatureNotice.feature(ports, "Hotstrings", true)
			helpers.assert_eq(record.sent, { { text = "Hotstrings", level = "success" } })
			helpers.assert_eq(record.info, { "Feature toggled from the menu: 'Hotstrings' → enabled." })
		end)

		helpers.it("sends an error-level notice when a feature is disabled", function()
			local ports, record = recording_ports()
			FeatureNotice.feature(ports, "Gestures", false)
			helpers.assert_eq(record.sent, { { text = "Gestures", level = "error" } })
			helpers.assert_eq(record.info, { "Feature toggled from the menu: 'Gestures' → disabled." })
		end)

		helpers.it("treats a non-boolean state as disabled instead of guessing", function()
			local ports, record = recording_ports()
			FeatureNotice.feature(ports, "X", nil)
			helpers.assert_eq(record.sent[1].level, "error")
		end)

		helpers.it("logs a warning, and does not raise, when the notifier raises", function()
			local ports, record = recording_ports(function() error("no daemon") end)
			FeatureNotice.feature(ports, "Shortcuts", true)
			helpers.assert_eq(#record.warn, 1)
			helpers.assert_true(record.warn[1]:find("no daemon", 1, true) ~= nil, record.warn[1])
		end)

		helpers.it("logs a warning when the notifier reports that nothing was shown", function()
			local ports, record = recording_ports(function() return false end)
			FeatureNotice.feature(ports, "Shortcuts", true)
			helpers.assert_eq(record.warn, { "Feature toggle notification was not shown." })
		end)

		helpers.it("tells the user why Quit did nothing", function()
			local ports, record = recording_ports()
			FeatureNotice.quit_refused(ports, function(key) return "T:" .. key end)
			helpers.assert_eq(record.sent, { { text = "T:notify.quit_refused", level = "error" } })
			helpers.assert_eq(#record.warn, 1)
		end)

		helpers.it("refuses missing ports and a missing locale lookup", function()
			helpers.assert_eq(pcall(FeatureNotice.feature, {}, "X", true), false)
			local ports = recording_ports()
			helpers.assert_eq(pcall(FeatureNotice.quit_refused, ports, nil), false)
		end)

		helpers.it("has the quit refusal string in every locale", function()
			local file = assert(io.open(shared_root .. "/data/locale_order.json", "rb"))
			local order = json.decode(file:read("*a")).order
			file:close()
			helpers.assert_eq(#order, 21)
			for _, locale in ipairs(order) do
				local strings_file = assert(io.open(shared_root .. "/data/locales/" .. locale .. ".json", "rb"))
				local strings = json.decode(strings_file:read("*a"))
				strings_file:close()
				helpers.assert_true(type(strings[FeatureNotice.QUIT_REFUSED_KEY]) == "string"
					and strings[FeatureNotice.QUIT_REFUSED_KEY] ~= "", locale .. ": quit refusal")
			end
		end)
	end)
end
