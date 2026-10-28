--- tests/unit/modules/updater/lifecycle/test_release_swap_receipts.lua

--- ==============================================================================
--- MODULE: Release Swap Physical Receipts
--- DESCRIPTION:
--- Executes the actual emitted replacement script under the shell, with real
--- temporary app trees and recording command refusals at native boundaries.
--- ==============================================================================

local helpers = require("tests.helpers")

local function quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function write(path, text)
	local file = assert(io.open(path, "wb"))
	assert(file:write(text))
	assert(file:close())
end

local function read(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local text = assert(file:read("*a"))
	assert(file:close())
	return text
end

local function shell(command)
	local pipe = assert(io.popen(command .. " 2>&1; printf '\\n__status=%s\\n' \"$?\""))
	local output = assert(pipe:read("*a"))
	pipe:close()
	return assert(tonumber(output:match("__status=(%d+)%s*$"))), output
end

--- Releases only this scenario's scratch tree even if an assertion raises.
local function with_swap(options, check)
	local dir = os.tmpname()
	assert(os.remove(dir))
	assert(shell("mkdir " .. quote(dir)) == 0)
	local ok, err = xpcall(function()
		local app = dir .. "/ErgoptiPlus.app"
		local staged = dir .. "/stage/ErgoptiPlus.app"
		local previous = dir .. "/ErgoptiPlus.app.previous"
		assert(shell("mkdir -p " .. quote(app) .. " " .. quote(staged)) == 0)
		write(app .. "/marker", "installed")
		write(staged .. "/marker", "chosen")
		if options.no_stage then assert(shell("rm -r " .. quote(staged)) == 0) end
		local opened = dir .. "/opened"
		local open = dir .. "/open"
		write(open, "#!/bin/sh\n" .. 'printf "%s\\n" "$2" >> ' .. quote(opened) .. "\n"
			.. (options.open_refused and "exit 43\n" or "exit 0\n"))
		assert(shell("chmod +x " .. quote(open)) == 0)
		local script = require("modules.updater.release_installer").SWAP_SCRIPT
			:gsub("/usr/bin/open", function() return open end)
		if options.rollback_refused then
			local move = dir .. "/move"
			write(move, "#!/bin/sh\n" .. '[ "$2" = ' .. quote(previous)
				.. ' ] && exit 44' .. "\n" .. 'exec /bin/mv "$@"' .. "\n")
			assert(shell("chmod +x " .. quote(move)) == 0)
			script = script:gsub("/bin/mv", function() return move end)
		end
		local acknowledgement = dir .. "/arming-receipt"
		local receipt_route = options.arming_refused and " 3>&-" or " 3>" .. quote(acknowledgement)
		local status, output = shell("/bin/sh -c " .. quote(script) .. " swap 999999999 "
			.. quote(app) .. " " .. quote(staged) .. " " .. quote(previous) .. receipt_route)
		if not options.arming_refused then
			helpers.assert_eq(read(acknowledgement), "ARMED\n", "the actual worker must acknowledge before moving any app")
		end
		check({ status = status, output = output, app = read(app .. "/marker"),
			previous = read(previous .. "/marker"), opened = read(opened) or "", app_path = app })
	end, debug.traceback)
	local removed = shell("rm -rf " .. quote(dir))
	assert(removed == 0, "The exact replacement scenario scratch tree must retire")
	if not ok then error(err, 0) end
end

helpers.describe("release swap physical command receipts", function()
	helpers.it("refuses a closed arming descriptor before touching applications (release-arming-write-refusal)", function()
		with_swap({ arming_refused = true }, function(result)
			helpers.assert_true(result.status ~= 0, "an unobserved worker must not continue after a refused receipt")
			helpers.assert_eq(result.app, "installed")
			helpers.assert_nil(result.previous)
			helpers.assert_eq(result.opened, "")
		end)
	end)

	helpers.it("reports a refused replacement launch (release-swap-receipts)", function()
		with_swap({ open_refused = true }, function(result)
			helpers.assert_eq(result.app, "chosen")
			helpers.assert_eq(result.previous, "installed")
			helpers.assert_eq(result.opened, result.app_path .. "\n")
			helpers.assert_true(result.status ~= 0, "A failed native launch must not report successful installation")
			helpers.assert_true(result.output:find("could not be opened", 1, true) ~= nil, result.output)
		end)
	end)

	helpers.it("retains the previous app and reports a refused rollback (release-swap-receipts)", function()
		with_swap({ no_stage = true, rollback_refused = true }, function(result)
			helpers.assert_nil(result.app)
			helpers.assert_eq(result.previous, "installed")
			helpers.assert_eq(result.opened, "", "Do not launch an app whose restoration failed")
			helpers.assert_true(result.status ~= 0)
			helpers.assert_true(result.output:find("could not be restored", 1, true) ~= nil, result.output)
			helpers.assert_true(result.output:find("the previous one is back", 1, true) == nil, result.output)
		end)
	end)

	helpers.it("keeps a successful replacement and launch (release-swap-receipts)", function()
		with_swap({}, function(result)
			helpers.assert_eq(result.status, 0, result.output)
			helpers.assert_eq(result.app, "chosen")
			helpers.assert_eq(result.previous, "installed")
			helpers.assert_eq(result.opened, result.app_path .. "\n")
		end)
	end)

	helpers.it("restores and opens the previous app after refused publication (release-swap-receipts)", function()
		with_swap({ no_stage = true }, function(result)
			helpers.assert_eq(result.status, 6, result.output)
			helpers.assert_eq(result.app, "installed")
			helpers.assert_nil(result.previous)
			helpers.assert_eq(result.opened, result.app_path .. "\n")
		end)
	end)
end)
