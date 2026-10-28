--- tests/unit/infra/control/test_reload_outcome.lua

--- ==============================================================================
--- MODULE: Hotstring Reload Outcome
--- DESCRIPTION:
--- A reload the loader refused (second value false, for example
--- `personal-source-pending`) must not be logged as "Hotstrings reloaded" nor
--- answered `completed` by the local reload control.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Policy = require("control.driver_control")
local DriverControl = require("infra.driver_control")
local Outcome = require("infra.reload_outcome")

local shared = helpers.driver_root() .. "/../_shared"

local function read(path)
	local file = assert(io.open(path, "rb"))
	local text = assert(file:read("*a"))
	assert(file:close())
	return text
end

local SPEC = Policy.validate(Json.decode(read(shared .. "/modules/control/driver_control.json")))
local TOKEN = Json.decode(read(shared .. "/tests/corpus/control/driver_control.json")).token
local FOLDER = "/run/user/1000/ergopti_plus/control"

helpers.describe("hotstring reload outcome", function()
	helpers.it("reports a published catalogue as reloaded", function()
		local reloaded, why, count = Outcome.run(function() return 12, true, nil end)
		helpers.assert_eq(reloaded, true)
		helpers.assert_nil(why)
		helpers.assert_eq(count, 12)
	end)

	helpers.it("reports a loader refusal as refused, never as reloaded", function()
		local reloaded, why = Outcome.run(function() return 7, false, "personal-source-pending" end)
		helpers.assert_eq(reloaded, false)
		helpers.assert_eq(why, "refused")
	end)

	helpers.it("reports a raised error as failed", function()
		local reloaded, why = Outcome.run(function() error("boom") end)
		helpers.assert_eq(reloaded, false)
		helpers.assert_eq(why, "failed")
	end)

	helpers.it("makes the local control answer refused, not completed, when the loader refused", function()
		local files = {}
		local ports = {
			read = function(path) return files[path] end,
			write = function(path, text) files[path] = text; return true end,
			remove = function(path) files[path] = nil; return true end,
			rename = function(from, to) files[to] = files[from]; files[from] = nil; return true end,
			exists = function(path) return files[path] ~= nil end,
			private_dir = function() return true end,
			random_hex = function() return TOKEN end,
		}
		local session = DriverControl.new({ spec = SPEC, folder = FOLDER, pid = 4242, ports = ports,
			reload = function()
				return Outcome.run(function() return 3, false, "personal-source-pending" end)
			end })
		session:start()
		files[FOLDER .. "/reload.request"] = string.format('{"schema":1,"token":"%s","request_id":"r1"}', TOKEN)
		helpers.assert_eq(session:handle(), false)
		helpers.assert_eq(files[FOLDER .. "/reload.result"],
			'{"schema":1,"request_id":"r1","state":"refused","driver_pid":4242,"reason":"refused"}\n')
	end)
end)
