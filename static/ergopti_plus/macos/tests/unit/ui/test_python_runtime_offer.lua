--- tests/unit/ui/test_python_runtime_offer.lua

--- ==============================================================================
--- MODULE: Native Python Offer Tests (hardening-h-python-offer)
--- DESCRIPTION:
--- An action refused for want of a native Python must tell the user which
--- interpreters were found and for which processor, and carry the buttons that
--- install one: Apple's command line tools installer, or the python.org page.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the offer with recording dialog, deferral and process doubles.
--- @param answer integer|nil Index the dialog answers.
--- @return table offer, table record
local function load(answer)
	local record = { dialogs = {}, spawns = {} }
	local offer = helpers.load_with_stubs("ui.python_runtime_offer")
	package.loaded["infra.dialog_util"] = {
		choose = function(title, message, choices, cancel_label)
			record.dialogs[#record.dialogs + 1] = { title = title, message = message, choices = choices,
				cancel = cancel_label }
			return answer
		end,
	}
	package.loaded["infra.deferred_work"] = {
		after = function(_, callback) callback(); return true end,
	}
	package.loaded["adapters.shell_runner"] = {
		spawn = function(executable, args)
			record.spawns[#record.spawns + 1] = executable .. " " .. table.concat(args, " ")
			return { start = function() return true end }
		end,
	}
	-- The stub echoes a key; the format arguments are what the text shows.
	package.loaded["infra.i18n"] = {
		get = function(key) return key end,
		format = function(key, ...)
			local parts = {}
			for index = 1, select("#", ...) do parts[index] = tostring((select(index, ...))) end
			return key .. "(" .. table.concat(parts, "|") .. ")"
		end,
	}
	offer.reset()
	return offer, record
end

-- Modules the doubles replace; every test restores them (suite order).
local OWNED = {
	"ui.python_runtime_offer", "infra.dialog_util", "infra.deferred_work", "adapters.shell_runner", "infra.i18n",
}

--- Runs one case with the doubled modules restored afterwards.
--- @param name string
--- @param body function
local function it_scoped(name, body)
	helpers.it(name, function() helpers.with_fresh_modules(OWNED, body) end)
end

local NOT_NATIVE = {
	kind = "python_not_native", native = "arm64",
	found = {
		{ path = "/Library/Developer/CommandLineTools/usr/bin/python3", archs = { "x86_64" } },
		{ path = "/usr/local/bin/python3", archs = { "x86_64" } },
	},
}

helpers.describe("hardening-h-python-offer", function()
	it_scoped("names every Intel interpreter found and the processor this Mac needs", function()
		local offer = load(nil)
		local title, body = offer.message_for(NOT_NATIVE)
		helpers.assert_eq(title, "python.not_native_title")
		helpers.assert_contains(body, "mlx.machine_apple_silicon")
		helpers.assert_contains(body, "/Library/Developer/CommandLineTools/usr/bin/python3 (x86_64)")
		helpers.assert_contains(body, "/usr/local/bin/python3 (x86_64)")
		helpers.assert_contains(body, "python.install_action")
		local missing_title, missing_body = offer.message_for({ kind = "python_missing", found = {} })
		helpers.assert_eq(missing_title, "python.missing_title")
		helpers.assert_contains(missing_body, "python.missing_body")
	end)

	it_scoped("installs Apple's command line tools from the first button", function()
		local offer, record = load(1)
		helpers.assert_true(offer.offer(NOT_NATIVE))
		helpers.assert_eq(#record.dialogs, 1)
		helpers.assert_eq(record.dialogs[1].choices[1], "python.install_tools_button")
		helpers.assert_eq(record.dialogs[1].choices[2], "python.download_button")
		helpers.assert_eq(record.spawns[1], "/usr/bin/xcode-select --install")
	end)

	it_scoped("opens the python.org download page from the second button", function()
		local offer, record = load(2)
		helpers.assert_true(offer.offer(NOT_NATIVE))
		helpers.assert_eq(record.spawns[1], "/usr/bin/open https://www.python.org/downloads/macos/")
	end)

	it_scoped("starts nothing when the user declines", function()
		local offer, record = load(nil)
		helpers.assert_true(offer.offer(NOT_NATIVE))
		helpers.assert_eq(#record.dialogs, 1)
		helpers.assert_eq(#record.spawns, 0)
	end)
end)
