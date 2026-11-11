--- macos/tests/unit/modules/updater/test_release_installer.lua

--- ==============================================================================
--- MODULE: Chosen Release Installer (macOS)
--- DESCRIPTION:
--- The Versions window installs a chosen release through
--- modules/updater/release_installer.lua, because Sparkle refuses to install a
--- lower build number. These cases pin its checks: the exact repository asset
--- and its SHA-256, a staging script that stops at the first failed check
--- (download, digest, version, code signature) and a replacement that only
--- happens after the launcher quit and puts the previous app back when it
--- fails. The two scripts run for real under /bin/sh with the macOS tools
--- replaced by recording fakes; nothing is downloaded or installed.
--- ==============================================================================

local helpers = require("tests.helpers")

local TAG = "v0.0.0-dev.139"
local DIGEST = string.rep("ab", 32)
local URL = "https://github.com/adrienm7/ergopti/releases/download/" .. TAG .. "/ErgoptiPlus.app.zip"
local IDS = { owner = "adrienm7", repo = "ergopti", asset = "ErgoptiPlus.app.zip",
	archives = { { name = "ErgoptiPlus.app.zip", format = "zip" } } }

--- Runs a shell command and returns its exit status and output.
--- @param command string
--- @return number status
--- @return string output
local function sh(command)
	local pipe = assert(io.popen(command .. " 2>&1; echo \"__status=$?\""))
	local output = pipe:read("*a")
	pipe:close()
	local status = tonumber(output:match("__status=(%d+)%s*$"))
	return status, (output:gsub("__status=%d+%s*$", ""))
end

--- A fresh installer module, so each suite's seams start from the defaults.
local function fresh_installer()
	package.loaded["modules.updater.release_installer"] = nil
	return require("modules.updater.release_installer")
end

local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end

local function read(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

local function write(path, text)
	local handle = assert(io.open(path, "wb"))
	handle:write(text)
	handle:close()
end

--- A fresh scratch folder under TMPDIR.
local function scratch()
	local base = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
	local dir = base .. "/ergopti-installer-test-" .. tostring(os.time()) .. "-" .. tostring(math.random(1e6))
	assert(sh("mkdir -p " .. quote(dir)) == 0)
	return dir
end

--- Writes an executable fake tool.
local function fake(dir, name, body)
	local path = dir .. "/" .. name
	write(path, "#!/bin/sh\n" .. body .. "\n")
	assert(sh("chmod +x " .. quote(path)) == 0)
	return path
end

helpers.describe("release_installer: the authenticated asset", function()
	local Installer = fresh_installer()

	local function release(asset)
		return { tag_name = TAG, assets = { { name = "other.zip" }, asset } }
	end

	helpers.it("binds the exact repository URL and GitHub's SHA-256", function()
		local asset = Installer.find_asset(release({ name = IDS.asset, browser_download_url = URL,
			digest = "sha256:" .. DIGEST:upper() }), IDS)
		helpers.assert_eq(asset.url, URL)
		helpers.assert_eq(asset.digest, DIGEST, "the digest is compared in lower case")
		helpers.assert_eq(asset.version, "0.0.0-dev.139")
	end)

	helpers.it("refuses an archive without its digest, at another URL, or absent", function()
		helpers.assert_nil(Installer.find_asset(release({ name = IDS.asset, browser_download_url = URL }), IDS))
		helpers.assert_nil(Installer.find_asset(release({ name = IDS.asset,
			browser_download_url = "https://evil.example/ErgoptiPlus.app.zip", digest = "sha256:" .. DIGEST }), IDS))
		helpers.assert_nil(Installer.find_asset(release({ name = IDS.asset, browser_download_url = URL,
			digest = "md5:0" }), IDS))
		helpers.assert_nil(Installer.find_asset({ tag_name = TAG, assets = {} }, IDS))
		helpers.assert_nil(Installer.find_asset({ tag_name = "v1; rm -rf /", assets = {} }, IDS))
	end)

	helpers.it("names the declared macOS archive from the shared defaults", function()
		local handle = assert(io.open(helpers.shared("modules/updater/defaults.json"), "rb"))
		local defaults = require("json").decode(handle:read("*a"))
		handle:close()
		helpers.assert_eq(defaults.release_assets.macos_bundle, IDS.asset)
	end)
end)

-- The Versions session holds a release whose quit was refused for exactly the
-- swap worker's own wait; a second copy of that bound would drift (MUR-001).
helpers.describe("release_installer: the held-install wait (release-restart-pending)", function()
	helpers.it("reads the launcher wait from the swap script it emits", function()
		local Installer = fresh_installer()
		helpers.assert_eq(Installer.SWAP_WAIT_SECONDS, Installer.SWAP_WAIT_TICKS / 10)
		helpers.assert_true(Installer.SWAP_WAIT_SECONDS >= 60, "the worker waits at least a minute")
		helpers.assert_true(Installer.SWAP_SCRIPT:find('[ "$waited" -gt ' .. Installer.SWAP_WAIT_TICKS .. ' ]', 1, true) ~= nil,
			"the emitted loop counts the same ticks")
		helpers.assert_true(Installer.SWAP_SCRIPT:find("/bin/sleep 0.1", 1, true) ~= nil, "each tick sleeps 0.1 s")
	end)
end)

helpers.describe("release_installer: staging and replacement dispatch", function()
	local Installer = fresh_installer()
	local env = {
		ERGOPTI_LAUNCHER_EXECUTABLE = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus",
		ERGOPTI_LAUNCHER_PID = "4242",
		TMPDIR = "/private/tmp/user",
	}
	Installer._getenv = function(name) return env[name] end

	helpers.it("reads the installed app and the launcher from the launcher's environment", function()
		helpers.assert_eq(Installer.app_bundle(), "/Applications/ErgoptiPlus.app")
		helpers.assert_eq(Installer.launcher_pid(), "4242")
	end)

	helpers.it("passes every release value as an argument and classifies the exit", function()
		local spawned = {}
		Installer._spawn = function(executable, args, on_done)
			spawned[#spawned + 1] = { executable = executable, args = args, on_done = on_done }
			return { start = function() return true end }
		end
		local asset = { tag = TAG, version = "0.0.0-dev.139", url = URL, digest = DIGEST, format = "zip" }
		local results = {}
		helpers.assert_true(Installer.stage(asset, function(...) results[#results + 1] = { ... } end))
		local call = spawned[1]
		helpers.assert_eq(call.executable, "/bin/sh")
		helpers.assert_eq(call.args[2], Installer.STAGE_SCRIPT, "the script text is a constant")
		helpers.assert_eq(call.args[4], URL)
		helpers.assert_eq(call.args[5], DIGEST)
		helpers.assert_eq(call.args[7], "0.0.0-dev.139")
		helpers.assert_eq(call.args[8], "/Applications/ErgoptiPlus.app")
		helpers.assert_true(call.args[6]:match("^/Applications/%.ergopti%-release%-install%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%d+$") ~= nil, "the private stage belongs to the destination parent, regardless of TMPDIR")
		call.on_done(0, "READY " .. call.args[6] .. "/app/ErgoptiPlus.app\n", "")
		call.on_done(10, "", "curl: (6) Could not resolve host")
		call.on_done(21, "", "")
		call.on_done(27, "", "code object is not signed")
		helpers.assert_eq(results[1][1], call.args[6] .. "/app/ErgoptiPlus.app")
		helpers.assert_eq(results[2][2], "download")
		helpers.assert_eq(results[3][2], "verify")
		helpers.assert_eq(results[4][2], "verify")
		helpers.assert_nil(results[4][1])
	end)

	helpers.it("refuses a stage receipt naming a different application", function()
		local callback, result
		Installer._spawn = function(_, _, on_done)
			callback = on_done
			return { start = function() return true end }
		end
		local asset = { tag = TAG, version = "0.0.0-dev.139", url = URL, digest = DIGEST, format = "zip" }
		helpers.assert_true(Installer.stage(asset, function(...) result = { ... } end))
		callback(0, "READY /private/tmp/foreign/app/ErgoptiPlus.app\n", "")
		helpers.assert_nil(result[1], "a foreign receipt must not reach the swap owner")
		helpers.assert_eq(result[2], "verify")
	end)

	helpers.it("uses distinct stages for retries started in the same second", function()
		local paths = {}
		Installer._spawn = function(_, args)
			paths[#paths + 1] = args[6]
			return { start = function() return true end }
		end
		local old_date = os.date
		os.date = function() return "20261104-120000" end
		local ok, err = xpcall(function()
			local asset = { tag = TAG, version = "0.0.0-dev.139", url = URL, digest = DIGEST, format = "zip" }
			helpers.assert_true(Installer.stage(asset, function() end))
			helpers.assert_true(Installer.stage(asset, function() end))
			helpers.assert_true(paths[1] ~= paths[2], "a retry must not reuse the first stage")
		end, debug.traceback)
		os.date = old_date
		if not ok then error(err, 0) end
	end)

	helpers.it("requires system curl only for an explicit proxy route", function()
		local previous = package.loaded["adapters.system_curl"]
		local checks, starts, child_environment, curl_available = 0, 0, nil, false
		package.loaded["adapters.system_curl"] = { check = function() checks = checks + 1; return curl_available end }
		Installer._spawn = function(_, _, _, _, environment)
			child_environment = environment
			return { start = function() starts = starts + 1; return true end }
		end
		local asset = { tag = TAG, version = "0.0.0-dev.139", url = URL, digest = DIGEST, format = "zip" }
		local ok, err = pcall(function()
			helpers.assert_true(Installer.stage(asset, function() end), "native stage does not run curl")
			helpers.assert_eq(checks, 0)
			helpers.assert_eq(child_environment.https_proxy, "", "the child receives the admitted proxy snapshot")
			env.https_proxy = "http://proxy.example:3128"
			helpers.assert_eq(Installer.stage(asset, function() end), false, "the explicit proxy uses curl")
			helpers.assert_eq(checks, 1)
			helpers.assert_eq(starts, 1)
			curl_available = true
			helpers.assert_true(Installer.stage(asset, function() end))
			helpers.assert_eq(child_environment.https_proxy, env.https_proxy)
		end)
		env.https_proxy = nil
		package.loaded["adapters.system_curl"] = previous
		if not ok then error(err, 0) end
	end)

	helpers.it("arms the replacement detached, with the previous app kept aside", function()
		local ran, observed = {}, {}
		Installer._run = function(executable, args, completed)
			ran[#ran + 1] = { executable = executable, args = args, completed = completed }
			return true
		end
		helpers.assert_true(Installer.arm_swap("/private/tmp/user/x/app/ErgoptiPlus.app", function(armed)
			observed[#observed + 1] = armed
		end))
		helpers.assert_eq(observed, {}, "dispatch alone must not acknowledge the detached installer")
		ran[1].completed(true, "ARMED", "")
		helpers.assert_eq(observed, { true })
		local args = ran[1].args
		helpers.assert_eq(ran[1].executable, "/bin/sh")
		helpers.assert_true(args[2]:find("nohup", 1, true) ~= nil, "the replacement outlives this process")
		helpers.assert_eq(args[4], Installer.SWAP_SCRIPT)
		helpers.assert_eq(args[5], "4242")
		helpers.assert_eq(args[6], "/Applications/ErgoptiPlus.app")
		helpers.assert_eq(args[7], "/private/tmp/user/x/app/ErgoptiPlus.app")
		helpers.assert_eq(args[8], "/Applications/ErgoptiPlus.app.previous")
		helpers.assert_eq(args[9], "/private/tmp/user/x/swap.log")
		helpers.assert_eq(select(1, Installer.arm_swap("/etc/passwd", function() end)), false, "only a staged app is accepted")
	end)

	helpers.it("refuses outside a packaged launch", function()
		env.ERGOPTI_LAUNCHER_EXECUTABLE = nil
		helpers.assert_nil(Installer.app_bundle())
		helpers.assert_eq(Installer.stage({ tag = TAG }, function() end), false)
		helpers.assert_eq(select(1, Installer.arm_swap("/private/tmp/user/x/app/ErgoptiPlus.app", function() end)), false)
	end)
end)

helpers.describe("release_installer: the staging script under /bin/sh", function()
	local Installer = fresh_installer()

	--- Runs the staging script with fake tools; returns status and output.
	local function stage(opts)
		local dir = scratch()
		local tools = dir .. "/tools"
		assert(sh("mkdir -p " .. quote(tools)) == 0)
		local payload = dir .. "/payload.zip"
		write(payload, "archive bytes")
		local digest = opts.digest or select(2, sh("sha256sum " .. quote(payload))):match("^(%x+)")
		local calls = dir .. "/calls"
		local curl = fake(tools, "curl", 'echo curl >> ' .. quote(calls) .. '\nout=""; while [ $# -gt 0 ]; do'
			.. ' [ "$1" = "--output" ] && out=$2; shift; done; '
			.. (opts.curl_fails and "exit 22" or "cp " .. quote(payload) .. ' "$out"'))
		local shasum = fake(tools, "shasum", 'sha256sum "$3"')
		local ditto = fake(tools, "ditto", 'echo ditto >> ' .. quote(calls) .. '\nmkdir -p "$4/ErgoptiPlus.app/Contents"')
		local tar = fake(tools, "tar", 'echo tar >> ' .. quote(calls) .. '\n'
			.. (opts.extract_fails and "exit 1" or 'mkdir -p "$4/ErgoptiPlus.app/Contents"'))
		local plist = fake(tools, "PlistBuddy", 'echo ' .. quote(opts.version or "0.0.0-dev.139"))
		local codesign = fake(tools, "codesign", 'echo "codesign $1" >> ' .. quote(calls)
			.. '\nif [ "$1" = "-d" ]; then echo "designated => identifier \\"com.ergoptiplus.app\\""; exit 0; fi\n'
			.. (opts.unsigned and "exit 1" or "exit 0"))
		local script = Installer.STAGE_SCRIPT
			:gsub("/usr/bin/curl", curl):gsub("/usr/bin/shasum", shasum):gsub("/usr/bin/ditto", ditto)
			:gsub("/usr/libexec/PlistBuddy", plist):gsub("/usr/bin/codesign", codesign):gsub("/usr/bin/tar", tar)
		if opts.archive_retirement_refused then
			local rm = fake(tools, "rm", 'exit 46')
			script = script:gsub("/bin/rm", function() return rm end)
		end
		if opts.parent_readonly then assert(sh("chmod 500 " .. quote(dir)) == 0) end
		local status, output = sh("sh -c " .. quote(script) .. " stage " .. quote(URL) .. " " .. quote(digest)
			.. " " .. quote(dir .. "/stage") .. " 0.0.0-dev.139 /Applications/ErgoptiPlus.app "
			.. quote(opts.format or "zip") .. " " .. quote(opts.bundle or "ErgoptiPlus.app"))
		if opts.parent_readonly then assert(sh("chmod 700 " .. quote(dir)) == 0) end
		local called = read(calls) or ""
		local retained_archive = read(dir .. "/stage/release." .. (opts.format or "zip"))
		local _, permissions = sh("if [ -d " .. quote(dir .. "/stage") .. " ]; then python3 -c "
			.. quote("import os,stat,sys; print(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))") .. " " .. quote(dir .. "/stage") .. "; fi")
		sh("rm -rf " .. quote(dir))
		return status, output, called, retained_archive, permissions
	end

	helpers.it("retires only the verified owned archive before READY and refuses failed retirement", function()
		local status, output, _, archive, permissions = stage({})
		helpers.assert_eq(permissions, "448\n", "the actual stage must be private mode 0700")
		helpers.assert_eq(status, 0, output)
		helpers.assert_nil(archive, "a successful private stage must not retain the downloaded archive")
		local refused, text, _, retained = stage({ archive_retirement_refused = true })
		helpers.assert_eq(refused, 28, text)
		helpers.assert_eq(retained, "archive bytes")
		helpers.assert_true(text:find("READY", 1, true) == nil, text)
	end)

	helpers.it("refuses a destination parent without write access before downloading", function()
		local status, output, calls = stage({ parent_readonly = true })
		helpers.assert_eq(status, Installer.EXIT_DOWNLOAD, output)
		helpers.assert_eq(calls, "", "an unallocatable private stage must not acquire a download")
		helpers.assert_true(output:find("READY", 1, true) == nil, output)
	end)

	helpers.it("prints READY only after the digest, the version and the signature pass", function()
		local status, output, called = stage({})
		helpers.assert_eq(status, 0, output)
		helpers.assert_true(output:match("^READY /.+/stage/app/ErgoptiPlus%.app") ~= nil, output)
		helpers.assert_eq(called, "curl\nditto\ncodesign -d\ncodesign --verify\n")
	end)

	helpers.it("uses only the declared tar extractor after integrity verification", function()
		local status, output, called = stage({ format = "tar.xz" })
		helpers.assert_eq(status, 0, output)
		helpers.assert_true(output:match("^READY /.+/stage/app/ErgoptiPlus%.app") ~= nil, output)
		helpers.assert_eq(called, "curl\ntar\ncodesign -d\ncodesign --verify\n")
		local rejected, text, before = stage({ format = "tar.xz", digest = string.rep("0", 64) })
		helpers.assert_eq(rejected, 21)
		helpers.assert_true(text:find("READY", 1, true) == nil)
		helpers.assert_eq(before, "curl\n", "the preferred format does not bypass SHA-256")
	end)

	helpers.it("refuses tar extraction, version and signing failures without READY", function()
		for _, case in ipairs({
			{ options = { format = "tar.xz", extract_fails = true }, status = 22, calls = "curl\ntar\n" },
			{ options = { format = "tar.xz", version = "0.0.0-dev.138" }, status = 25, calls = "curl\ntar\n" },
			{ options = { format = "tar.xz", unsigned = true }, status = 27,
				calls = "curl\ntar\ncodesign -d\ncodesign --verify\n" },
		}) do
			local status, output, called = stage(case.options)
			helpers.assert_eq(status, case.status)
			helpers.assert_true(output:find("READY", 1, true) == nil)
			helpers.assert_eq(called, case.calls)
		end
	end)

	helpers.it("refuses undeclared formats and foreign bundle paths before download", function()
		for _, options in ipairs({ { format = "tar.gz" }, { format = "unowned" },
			{ bundle = "../ErgoptiPlus.app" }, { bundle = "/ErgoptiPlus.app" }, { bundle = "" },
			{ bundle = "." }, { bundle = "foreign" } }) do
			local status, output, called = stage(options)
			helpers.assert_eq(status, 20)
			helpers.assert_true(output:find("READY", 1, true) == nil)
			helpers.assert_eq(called, "", "an invalid invocation never acquires network work")
		end
	end)

	helpers.it("stops at a failed download", function()
		local status, _, called = stage({ curl_fails = true })
		helpers.assert_eq(status, Installer.EXIT_DOWNLOAD)
		helpers.assert_eq(called, "curl\n")
	end)

	helpers.it("never extracts an archive whose SHA-256 differs", function()
		local status, output, called = stage({ digest = string.rep("0", 64) })
		helpers.assert_eq(status, 21)
		helpers.assert_true(output:find("READY", 1, true) == nil)
		helpers.assert_eq(called, "curl\n")
	end)

	helpers.it("refuses an archive carrying another version", function()
		local status = stage({ version = "0.0.0-dev.138" })
		helpers.assert_eq(status, 25)
	end)

	helpers.it("refuses an app its signing identity does not match", function()
		local status, output = stage({ unsigned = true })
		helpers.assert_eq(status, 27)
		helpers.assert_true(output:find("READY", 1, true) == nil)
	end)
end)

helpers.describe("release_installer: the replacement script under /bin/sh", function()
	local Installer = fresh_installer()

	local function swap(opts)
		local dir = scratch()
		local app, staged, previous = dir .. "/ErgoptiPlus.app", dir .. "/stage/app/ErgoptiPlus.app", dir .. "/ErgoptiPlus.app.previous"
		assert(sh("mkdir -p " .. quote(app) .. " " .. quote(staged)) == 0)
		write(app .. "/marker", "installed")
		write(staged .. "/marker", "chosen")
		if opts.previous == "directory" then
			assert(sh("mkdir -p " .. quote(previous)) == 0)
			write(previous .. "/marker", "user backup")
		elseif opts.previous == "file" then
			write(previous, "user backup")
		elseif opts.previous == "symlink" then
			assert(sh("ln -s missing " .. quote(previous)) == 0)
		end

		if opts.ready_capable then
			local capability = staged .. Installer.BOOT_READY_CAPABILITY
			assert(sh("mkdir -p " .. quote(capability:match("^(.*)/[^/]+$"))) == 0)
			write(capability, "-- boot reporter\n")
		end
		-- The fake open records each launch; opened with a boot-ready token it
		-- plays the successor: it reports the pid in successor_pid, or nothing.
		local opened = dir .. "/opened"
		local reported = dir .. "/successor_pid"
		if opts.successor_pid then write(reported, opts.successor_pid) end
		if opts.quit_later then write(dir .. "/quit_later", "") end
		local open = fake(dir, "open", table.concat({
			'if [ "$1" = --env ]; then',
			'	echo "ready $4" >> ' .. quote(opened),
			'	token=${2#ERGOPTI_UPDATER_BOOT_READY=}',
			'	if [ -f ' .. quote(reported) .. ' ]; then cp ' .. quote(reported) .. ' "$token.tmp" && mv "$token.tmp" "$token"; fi',
			-- A Quit during the probation: the boot rewrites its token with quit.
			'	if [ -f ' .. quote(dir .. "/quit_later") .. ' ]; then (sleep 0.2; echo quit > "$token.tmp" && mv "$token.tmp" "$token") & fi',
			'else',
			'	echo "$2" >> ' .. quote(opened),
			'fi',
		}, "\n"))
		local no_processes = fake(dir, "ps", "exit 0")
		local script = Installer.SWAP_SCRIPT:gsub("/usr/bin/open", open):gsub("/bin/ps ", no_processes .. " ")
		-- A wait of a few ticks keeps the silent successor case short.
		script = script:gsub('%[ "%$ready_ticks" %-gt %d+ %]', '[ "$ready_ticks" -gt 3 ]')
		script = require("tests.support.release_swap_ports").observe(script, dir)
		if opts.publication_refused then
			local move = fake(dir, "move", '[ "$2" = ' .. quote(staged) .. ' ] && exit 45\nexec ' .. require("tests.support.release_swap_ports").command() .. ' --release-rename move "$2" "$3"')
			script = script:gsub('%"%$launcher%" %"%$rename_flag%" move', function() return move .. " --" end)
		end
		local pid = opts.pid or "999999999"
		local acknowledgement = dir .. "/arming-receipt"
		local status, output = sh(require("tests.support.release_swap_ports").command() .. " --release-rename lock " .. quote(app)
			.. " " .. quote(script) .. " " .. pid .. " " .. quote(staged) .. " " .. quote(previous)
			.. " 3>" .. quote(acknowledgement))
		helpers.assert_eq(read(acknowledgement), opts.previous and "" or "ARMED\n",
			"an occupied backup must refuse before the driver quits")
		local result = {
			status = status, output = output,
			app = read(app .. "/marker"), previous = read(previous .. "/marker"), opened = read(opened) or "",
			previous_file = read(previous), previous_link = sh("test -L " .. quote(previous)) == 0,
			app_path = app,
			failed = read(app .. ".failed-" .. (output:match("new one is at .-%.failed%-(%d+)") or "none") .. "/marker"),
		}
		sh("rm -rf " .. quote(dir))
		return result
	end

	helpers.it("waits for the launcher, keeps the previous app and opens the chosen one", function()
		-- Keep the shell parent alive to reap its sleeper while the swap waits.
		local producer = assert(io.popen([[sleep 0.4 >/dev/null 2>&1 & sleeper=$!; printf '%s\n' "$sleeper"; wait "$sleeper"]]))
		local completed, result = pcall(function()
			local sleeper = producer:read("*l")
			assert(sleeper and sleeper:match("^[1-9]%d*$"), "The retained sleeper must publish its exact PID")
			return swap({ pid = sleeper })
		end)
		-- Close this exact producer even if PID admission or swap failed. All
		-- original result assertions run only after the parent has been reaped.
		local close_completed, closed = pcall(producer.close, producer)
		if not completed then error(result, 0) end
		assert(close_completed and closed == true, "The retained sleeper parent must retire successfully")
		helpers.assert_eq(result.status, 0, result.output)
		helpers.assert_eq(result.app, "chosen")
		helpers.assert_eq(result.previous, "installed")
		helpers.assert_eq(result.opened, result.app_path .. "\n")
	end)

	helpers.it("preserves a pre-existing backup and refuses before arming", function()
		for _, kind in ipairs({ "directory", "file", "symlink" }) do
			local result = swap({ previous = kind })
			helpers.assert_eq(result.status, 1)
			helpers.assert_eq(result.app, "installed")
			helpers.assert_eq(result.opened, "")
			if kind == "directory" then helpers.assert_eq(result.previous, "user backup") end
			if kind == "file" then helpers.assert_eq(result.previous_file, "user backup") end
			if kind == "symlink" then helpers.assert_true(result.previous_link) end
			helpers.assert_true(result.output:find("Move the existing backup", 1, true) ~= nil)
		end
	end)

	--- Runs one swap whose launcher has already quit and whose successor is the given process.
	--- @param opts table swap() options.
	--- @return table result
	local function swap_with_live_pid(opts)
		local producer = assert(io.popen([[sleep 3 >/dev/null 2>&1 & sleeper=$!; printf '%s\n' "$sleeper"; wait "$sleeper"]]))
		local sleeper = producer:read("*l")
		assert(sleeper and sleeper:match("^[1-9]%d*$"), "The successor double must publish its exact PID")
		opts.successor_pid = opts.successor_pid or sleeper
		local completed, result = pcall(swap, opts)
		sh("kill " .. sleeper)
		producer:close()
		if not completed then error(result, 0) end
		return result
	end

	-- The Windows swap keeps a new build only once it signals boot-ready and
	-- survives its probation; the macOS swap only renamed and opened.
	helpers.it("keeps the chosen app once its boot reports ready and survives the probation", function()
		local result = swap_with_live_pid({ ready_capable = true })
		helpers.assert_eq(result.status, 0, result.output)
		helpers.assert_eq(result.app, "chosen")
		helpers.assert_eq(result.previous, "installed")
		helpers.assert_eq(result.opened, "ready " .. result.app_path .. "\n", "opened once, with the boot-ready token")
		helpers.assert_contains(result.output, "reported a healthy start")
	end)

	helpers.it("puts the previous app back when the chosen one never reports its boot", function()
		local result = swap({ ready_capable = true })
		helpers.assert_eq(result.status, 9, result.output)
		helpers.assert_eq(result.app, "installed", "the previous app is back in place")
		helpers.assert_eq(result.failed, "chosen", "the build that did not start is kept aside, not deleted")
		helpers.assert_eq(result.opened, "ready " .. result.app_path .. "\n" .. result.app_path .. "\n",
			"the chosen app was opened with its token, then the previous one")
		helpers.assert_contains(result.output, "did not start (no boot report)")
	end)

	helpers.it("puts the previous app back when the chosen one quits during the probation", function()
		local result = swap({ ready_capable = true, successor_pid = "999999999" })
		helpers.assert_eq(result.status, 9, result.output)
		helpers.assert_eq(result.app, "installed")
		helpers.assert_eq(result.failed, "chosen")
		helpers.assert_contains(result.output, "quit during the probation")
	end)

	helpers.it("(update-quit-kept) keeps the chosen app and opens nothing when it is quit before its report", function()
		local result = swap({ ready_capable = true, successor_pid = "quit" })
		helpers.assert_eq(result.status, 0, result.output)
		helpers.assert_eq(result.app, "chosen", "the update stays installed")
		helpers.assert_eq(result.previous, "installed")
		helpers.assert_eq(result.opened, "ready " .. result.app_path .. "\n", "the previous app is not opened")
		helpers.assert_contains(result.output, "quit before it reported ready")
	end)

	helpers.it("(update-quit-kept) keeps the chosen app when it is quit during the probation", function()
		local result = swap({ ready_capable = true, successor_pid = "999999999", quit_later = true })
		helpers.assert_eq(result.status, 0, result.output)
		helpers.assert_eq(result.app, "chosen", "the update stays installed")
		helpers.assert_eq(result.opened, "ready " .. result.app_path .. "\n", "the previous app is not opened")
		helpers.assert_contains(result.output, "quit during its probation")
	end)

	helpers.it("refuses an invalid boot report like a missing one", function()
		local result = swap({ ready_capable = true, successor_pid = "12x" })
		helpers.assert_eq(result.status, 9, result.output)
		helpers.assert_eq(result.app, "installed")
		helpers.assert_contains(result.output, "an invalid boot report")
	end)

	helpers.it("only opens a chosen release that predates the boot report", function()
		local result = swap({})
		helpers.assert_eq(result.status, 0, result.output)
		helpers.assert_eq(result.app, "chosen", "an older build cannot report and is kept as before")
		helpers.assert_eq(result.opened, result.app_path .. "\n")
	end)

	helpers.it("puts the previous app back and opens it when the chosen one cannot move in", function()
		local result = swap({ publication_refused = true })
		helpers.assert_eq(result.status, 6)
		helpers.assert_eq(result.app, "installed")
		helpers.assert_eq(result.opened, result.app_path .. "\n")
	end)
end)


helpers.describe("release_installer: declared archive preference and historical compatibility", function()
	local Installer = fresh_installer()
	local Archives = require("updater.release_assets")

	helpers.it("uses actual shared declarations against independent exact release records", function()
		local corpus = require("json").decode(assert(read(helpers.shared("tests/corpus/updater/release_archives.json"))))
		helpers.assert_eq(#corpus.cases, 14, "the independent refusal corpus is complete")
		for _, case in ipairs(corpus.cases) do
			local selected = Installer.find_asset(case.release)
			if case.refused then helpers.assert_nil(selected, case.name)
			else helpers.assert_eq(selected, case.expected, case.name) end
			local _, reason = Archives.select(case.release, Installer._identity())
			helpers.assert_eq(reason, case.reason, case.name)
		end
	end)

	helpers.it("preserves other platform assets and requires declared format-key bindings", function()
		local defaults = require("json").decode(assert(read(helpers.shared("modules/updater/defaults.json"))))
		helpers.assert_eq(defaults.release_assets.linux_bundle, "ergopti-plus-linux.tar.gz")
		helpers.assert_eq(defaults.release_assets.macos_bundle, "ErgoptiPlus.app.zip", "current producers retain ZIP")
		local identity = assert(Archives.resolve(defaults))
		helpers.assert_eq(identity.archives, {
			{ name = "ErgoptiPlus.app.tar.xz", format = "tar.xz" },
			{ name = "ErgoptiPlus.app.zip", format = "zip" },
		})
		for _, mutate in ipairs({
			function(value) value.release_install.macos_archives[1].format = "unowned" end,
			function(value) value.release_install.macos_archives[1].asset_key = "missing" end,
			function(value) value.release_install.macos_archives[1].format = "zip" end,
			function(value) value.release_install.macos_archives[2] = value.release_install.macos_archives[1] end,
			function(value)
				value.release_assets.extra_zip = "Other.app.zip"
				value.release_install.macos_archives[1] = { asset_key = "extra_zip", format = "zip" }
			end,
			function(value) value.release_install.macos_archives.future = {} end,
			function(value) value.github.owner = "../foreign" end,
		}) do
			local changed = require("json").decode(assert(read(helpers.shared("modules/updater/defaults.json"))))
			mutate(changed)
			helpers.assert_nil(Archives.resolve(changed), "malformed policy never selects a fallback")
		end
	end)

	helpers.it("passes the admitted format to the actual native stage and refuses unknown formats before dispatch", function()
		local environment = {
			ERGOPTI_LAUNCHER_EXECUTABLE = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus",
			TMPDIR = "/private/tmp/user",
		}
		Installer._getenv = function(name) return environment[name] end
		local calls = {}
		Installer._spawn = function(executable, args)
			calls[#calls + 1] = { executable = executable, args = args }
			return { start = function() return true end }
		end
		for _, format in ipairs({ "zip", "tar.xz" }) do
			local asset = { tag = TAG, version = "0.0.0-dev.139", url = URL, digest = DIGEST, format = format }
			helpers.assert_eq(Installer.stage(asset, function() end), true)
			helpers.assert_eq(calls[#calls].args[9], format)
			helpers.assert_eq(calls[#calls].args[10], "ErgoptiPlus.app")
		end
		for _, format in ipairs({ "unowned", false, 2 }) do
			helpers.assert_eq(Installer.stage({ tag = TAG, format = format }, function() end), false)
		end
		helpers.assert_eq(Installer.stage({ tag = TAG }, function() end), false)
		helpers.assert_eq(#calls, 2, "invalid formats never dispatch native work")
	end)
end)

helpers.describe("release_installer: the native stage request", function()
	local Installer = fresh_installer()
	Installer._getenv = function(name)
		if name == "ERGOPTI_LAUNCHER_EXECUTABLE" then return "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus" end
		if name == "TMPDIR" then return "/private/tmp/user" end
	end

	helpers.it("binds a bounded request to the original arguments and child environment", function()
		local captured
		Installer._spawn = function(executable, args, on_done, on_chunk, environment)
			captured = { executable = executable, args = args, on_chunk = on_chunk, environment = environment }
			return { start = function() return true end }
		end
		local asset = { tag = TAG, version = "0.0.0-dev.139", url = URL, digest = DIGEST, format = "tar.xz" }
		helpers.assert_true(Installer.stage(asset, function() end))
		helpers.assert_eq(captured.executable, "/bin/sh")
		helpers.assert_nil(captured.on_chunk)
		local raw = captured.environment.ERGOPTI_RELEASE_STAGE_REQUEST
		helpers.assert_true(type(raw) == "string" and #raw < 65536)
		local request = require("adapters.json_codec").decode(raw)
		helpers.assert_eq(request.version, 1)
		helpers.assert_eq(request.url, URL)
		helpers.assert_eq(request.sha256, DIGEST)
		helpers.assert_eq(request.output, captured.args[6] .. "/release.tar.xz")
		helpers.assert_eq(request.timeout_ms, 900000)
		local count = 0
		for _ in pairs(request) do count = count + 1 end
		helpers.assert_eq(count, 5)
		helpers.assert_eq(asset.format, "tar.xz")
	end)
	helpers.it("refuses failed or oversized serialization before native acquisition", function()
		local Codec = require("adapters.json_codec")
		local original = Codec.encode
		local calls = 0
		Installer._spawn = function() calls = calls + 1; return nil end
		for _, encode in ipairs({
			function() return nil, "authored serialization refusal" end,
			function() return string.rep("x", 65536), nil end,
			function() return "", nil end,
		}) do
			Codec.encode = encode
			local ok, dispatched = pcall(Installer.stage,
				{ tag = TAG, version = "0.0.0-dev.139", url = URL, digest = DIGEST, format = "zip" }, function() end)
			Codec.encode = original
			helpers.assert_true(ok)
			helpers.assert_eq(dispatched, false)
		end
		helpers.assert_eq(calls, 0)
	end)

end)

helpers.describe("release_installer: filesystem publication admission", function()
	helpers.it("executes real filesystem refusals and preserves every owned original", function()
		local dir = scratch()
		local ok, err = xpcall(function()
			local probe = helpers.driver_root() .. "tests/support/release_swap_physical_probe.py"
			local source = dir .. "/release-swap-source.lua"
			write(source, assert(helpers.read_driver_unit("M.SWAP_SCRIPT = table.concat({")))
			local status, output = sh("python3 -B " .. quote(probe) .. " controls " .. quote(source) .. " " .. quote(dir .. "/controls"))
			helpers.assert_eq(status, 0, output)
			local receipt = assert(require("json").decode(output))
			helpers.assert_eq(#receipt.parser_refusals, 25, "the literal parser must refuse every malformed authority")
			helpers.assert_eq(#receipt.cases, 8, "all independent physical refusals and healthy controls execute")
			local emitted, program = sh("python3 -B " .. quote(probe) .. " emit " .. quote(source))
			helpers.assert_eq(emitted, 0, program)
			helpers.assert_eq(program, fresh_installer().SWAP_SCRIPT, "the shared extractor must equal actual production Lua bytes")
		end, debug.traceback)
		assert(sh("rm -rf " .. quote(dir)) == 0)
		if not ok then error(err, 0) end
	end)
end)


helpers.describe("release_installer: concurrent filesystem publication", function()
	helpers.it("refuses racing destinations and serializes detached installers before arming (release-exclusive-publication)", function()
		local dir = scratch()
		local ok, err = xpcall(function()
			local probe = helpers.driver_root() .. "tests/support/release_swap_concurrent_probe.py"
			local status, output = sh("python3 -B " .. quote(probe) .. " " .. quote(helpers.driver_root()) .. " " .. quote(dir))
			helpers.assert_eq(status, 0, output)
			local receipt = assert(require("json").decode(output))
			helpers.assert_eq(#receipt.cases, 4, "all three native boundaries and the two-installer transaction execute")
			local names = {}
			for _, case in ipairs(receipt.cases) do names[#names + 1] = case.name end
			helpers.assert_eq(names, { "backup", "publish", "rollback", "two-installers-before-arming" })
			for index = 1, 3 do
				helpers.assert_eq(receipt.cases[index].foreign_identity_preserved, true)
				helpers.assert_eq(receipt.cases[index].nested_source, false)
			end
			helpers.assert_eq(receipt.cases[4].original_restored, true)
		end, debug.traceback)
		assert(sh("rm -rf " .. quote(dir)) == 0)
		if not ok then error(err, 0) end
	end)
end)


helpers.describe("release_installer: complete literal extraction", function()
	helpers.it("rejects four valid Lua suffix expressions on both literal authorities", function()
		local dir = scratch()
		local ok, err = xpcall(function()
			local source = assert(helpers.read_driver_unit("M.SWAP_SCRIPT = table.concat({"))
			local original = fresh_installer().SWAP_SCRIPT
			local binding = "M.SWAP_SCRIPT = table.concat({"
			local first, last_binding = assert(source:find(binding, 1, true))
			helpers.assert_nil(source:find(binding, last_binding + 1, true), "the script has one literal authority")
			local _, swap_end = assert(source:find([=[}, "\n")]=], first, true))
			local _, receipt_end = assert(source:find('local ARMING_RECEIPT = "ARMED"', 1, true))
			local changed_receipt, count = original:gsub("ARMED", "ARMEDX")
			helpers.assert_eq(count, 1, "the worker must emit exactly one arming receipt")
			local authorities = {
				{ ending = swap_end, suffix = [=[ .. "\nexit 42"]=], expected = original .. "\nexit 42" },
				{ ending = receipt_end, suffix = [=[ .. "X"]=], expected = changed_receipt },
			}
			for index, authority in ipairs(authorities) do
				for variant, prefix in ipairs({ "", "\n" }) do
					local path = dir .. "/continued-" .. index .. "-" .. variant .. ".lua"
					write(path, source:sub(1, authority.ending) .. prefix .. authority.suffix .. source:sub(authority.ending + 1))
					local evaluated = assert(loadfile(path))()
					helpers.assert_eq(evaluated.SWAP_SCRIPT, authority.expected,
						"the control must be valid Lua that changes the actual worker bytes")
					local status, output = sh("python3 -B " .. quote(helpers.driver_root() .. "tests/support/release_swap_physical_probe.py")
						.. " emit " .. quote(path))
					helpers.assert_true(status ~= 0, "the extractor must refuse the complete changed expression: " .. output)
				end
			end
			local suffix_literal = assert(source:match('\nlocal EXECUTABLE_SUFFIX = ("[^"\n]+")'))
			local suffix = assert(load("return " .. suffix_literal))()
			local changed_suffix = suffix .. ".fixture"
			local changed_source, changed_count = source:gsub('\nlocal EXECUTABLE_SUFFIX = "[^"\n]+"', function()
				return "\nlocal EXECUTABLE_SUFFIX = " .. string.format("%q", changed_suffix)
			end)
			helpers.assert_eq(changed_count, 1, "the executable has one declared authority")
			local path = dir .. "/changed-executable-suffix.lua"
			write(path, changed_source)
			local evaluated = assert(loadfile(path))()
			local suffix_pattern = suffix:gsub("([^%w])", "%%%1")
			local expected, replacements = original:gsub(suffix_pattern, function() return changed_suffix end)
			helpers.assert_eq(replacements, 2, "both worker launch paths consume the executable authority")
			helpers.assert_eq(evaluated.SWAP_SCRIPT, expected)
			local status, output = sh("python3 -B " .. quote(helpers.driver_root() .. "tests/support/release_swap_physical_probe.py")
				.. " emit " .. quote(path))
			helpers.assert_eq(status, 0, output)
			helpers.assert_eq(output, evaluated.SWAP_SCRIPT, "the extractor must read a changed declared suffix rather than a fallback")
		end, debug.traceback)
		assert(sh("rm -rf " .. quote(dir)) == 0)
		if not ok then error(err, 0) end
	end)
end)


helpers.describe("release_installer: explicit native script observation", function()
	helpers.it("executes only the explicit script observer without discovering Lua (release-native-script-scope)", function()
		local dir = scratch()
		local ok, err = xpcall(function()
			local probe = helpers.driver_root() .. "tests/support/release_swap_concurrent_probe.py"
			local command = "LUA=" .. quote(dir .. "/missing-lua") .. " python3 -B " .. quote(probe)
				.. " " .. quote(helpers.driver_root()) .. " " .. quote(dir)
			local status, output = sh(command .. " --emission-source strict-source")
			helpers.assert_eq(status, 0, output)
			local receipt = assert(require("json").decode(output))
			helpers.assert_eq(receipt.emission_source, "strict-source")
			helpers.assert_eq(receipt.execution_scope, "script-only/source-parser")
			helpers.assert_eq(#receipt.cases, 4, "the explicit observer must still execute every physical boundary")
			local rejected, detail = sh(command)
			helpers.assert_true(rejected ~= 0, "the default mode must fail without its required Lua")
			helpers.assert_true(detail:find("Lua 5.4 is required", 1, true) ~= nil)
		end, debug.traceback)
		assert(sh("rm -rf " .. quote(dir)) == 0)
		if not ok then error(err, 0) end
	end)

	helpers.it("binds both extracted scripts and complete argv to actual Lua emission (release-native-script-scope)", function()
		local dir = scratch()
		local ok, err = xpcall(function()
			local probe = helpers.driver_root() .. "tests/support/release_swap_concurrent_probe.py"
			local status, output = sh("python3 -B " .. quote(probe) .. " " .. quote(helpers.driver_root())
				.. " " .. quote(dir) .. " --emission-controls")
			helpers.assert_eq(status, 0, output)
			local receipt = assert(require("json").decode(output))
			helpers.assert_eq(receipt.emission_source, "actual-lua-compared-with-strict-source")
			helpers.assert_eq(#receipt.commands, 3, "each complete argv and both scripts must match real Lua")
			helpers.assert_eq(#receipt.parser_refusals, 10, "every malformed detach authority must refuse")
			for _, command in ipairs(receipt.commands) do
				helpers.assert_eq(command.interpreter_version, "Lua 5.4")
				helpers.assert_eq(command.argv_equal, true)
				helpers.assert_eq(command.swap_equal, true)
				helpers.assert_eq(command.detach_equal, true)
			end
		end, debug.traceback)
		assert(sh("rm -rf " .. quote(dir)) == 0)
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("updater version comparison parity", function()
	helpers.it("replays the shared version vectors, including malformed suffixes", function()
		local raw = assert(read(helpers.shared("modules/updater/version_vectors.json")))
		local vectors = require("json").decode(raw).vectors
		local version = require("updater.version")
		for _, vector in ipairs(vectors) do
			helpers.assert_eq(version.compare_versions(vector.a, vector.b), vector.expect, vector.id)
		end
	end)
end)
