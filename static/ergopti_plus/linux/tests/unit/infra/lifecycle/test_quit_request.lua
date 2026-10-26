--- tests/unit/infra/lifecycle/test_quit_request.lua

--- ==============================================================================
--- MODULE: Tray Quit Request (Linux)
--- DESCRIPTION:
--- Replays the shared quit admission contract and proves the Linux daemon refuses
--- Quit for the same causes as the macOS menu (quit-admission, 2026-10-26): a
--- shutdown or a reload restart that owns the process, a global writer holding a
--- rollback, a pending hotstring publication. A refusal applies no pause layout
--- and starts no shutdown.
--- ==============================================================================

local helpers = require("tests.helpers")
local QuitRequest = require("infra.quit_request")

require("test.quit_admission_contract")(helpers)

--- Builds a handler over recording ports.
--- @param state table Mutable facts: requested, reload, writer, publication.
--- @return function on_quit, table calls
local function build(state)
	local calls = { layout = 0, requests = {} }
	local on_quit = QuitRequest.new({
		shutdown = {
			is_requested = function() return state.requested == true end,
			request = function(reason)
				if state.requested then return false end
				state.requested = true
				calls.requests[#calls.requests + 1] = reason
				return true
			end,
		},
		reload_in_flight = function() return state.reload == true end,
		writer_active = function() return state.writer == true end,
		publication_pending = function() return state.publication == true end,
		apply_pause_layout = function() calls.layout = calls.layout + 1 end,
	})
	return on_quit, calls
end

helpers.describe("Linux tray Quit follows the shared admission (quit-admission)", function()
	helpers.it("admits a quit, applies the pause layout, then starts the shutdown", function()
		local on_quit, calls = build({})
		helpers.assert_eq(on_quit(), true)
		helpers.assert_eq(calls.layout, 1)
		helpers.assert_eq(calls.requests, { "tray quit" })
	end)

	helpers.it("refuses each macOS cause without any effect", function()
		for _, cause in ipairs({ "requested", "reload", "writer", "publication" }) do
			local state = { [cause] = true }
			local on_quit, calls = build(state)
			helpers.assert_eq(on_quit(), false, cause .. " must refuse the quit")
			helpers.assert_eq(calls.layout, 0, cause .. " must not apply the pause layout")
			helpers.assert_eq(calls.requests, {}, cause .. " must not start a shutdown")
		end
	end)

	helpers.it("refuses the second click once the first started the shutdown", function()
		local on_quit, calls = build({})
		helpers.assert_eq(on_quit(), true)
		helpers.assert_eq(on_quit(), false)
		helpers.assert_eq(calls.layout, 1)
	end)

	helpers.it("quits again once the writer, the publication and the reload are settled", function()
		local state = { writer = true }
		local on_quit = build(state)
		helpers.assert_eq(on_quit(), false)
		state.writer = false
		helpers.assert_eq(on_quit(), true)
	end)

	helpers.it("rejects missing ports instead of reading them as idle", function()
		local ok, err = pcall(QuitRequest.new, {})
		helpers.assert_true(not ok and tostring(err):find("shutdown owner", 1, true) ~= nil, tostring(err))
		ok, err = pcall(QuitRequest.new, { shutdown = { is_requested = function() end,
			request = function() end } })
		helpers.assert_true(not ok and tostring(err):find("reload_in_flight", 1, true) ~= nil, tostring(err))
	end)
end)
