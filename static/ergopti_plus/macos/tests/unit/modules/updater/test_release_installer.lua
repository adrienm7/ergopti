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
		call.on_done(0, "READY /private/tmp/user/x/app/ErgoptiPlus.app\n", "")
		call.on_done(10, "", "curl: (6) Could not resolve host")
		call.on_done(21, "", "")
		call.on_done(27, "", "code object is not signed")
		helpers.assert_eq(results[1][1], "/private/tmp/user/x/app/ErgoptiPlus.app")
		helpers.assert_eq(results[2][2], "download")
		helpers.assert_eq(results[3][2], "verify")
		helpers.assert_eq(results[4][2], "verify")
		helpers.assert_nil(results[4][1])
	end)

	helpers.it("arms the replacement detached, with the previous app kept aside", function()
		local ran = {}
		Installer._run = function(executable, args) ran[#ran + 1] = { executable = executable, args = args }; return true end
		helpers.assert_true(Installer.arm_swap("/private/tmp/user/x/app/ErgoptiPlus.app"))
		local args = ran[1].args
		helpers.assert_eq(ran[1].executable, "/bin/sh")
		helpers.assert_true(args[2]:find("nohup", 1, true) ~= nil, "the replacement outlives this process")
		helpers.assert_eq(args[4], Installer.SWAP_SCRIPT)
		helpers.assert_eq(args[5], "4242")
		helpers.assert_eq(args[6], "/Applications/ErgoptiPlus.app")
		helpers.assert_eq(args[7], "/private/tmp/user/x/app/ErgoptiPlus.app")
		helpers.assert_eq(args[8], "/Applications/ErgoptiPlus.app.previous")
		helpers.assert_eq(args[9], "/private/tmp/user/x/swap.log")
		helpers.assert_eq(select(1, Installer.arm_swap("/etc/passwd")), false, "only a staged app is accepted")
	end)

	helpers.it("refuses outside a packaged launch", function()
		env.ERGOPTI_LAUNCHER_EXECUTABLE = nil
		helpers.assert_nil(Installer.app_bundle())
		helpers.assert_eq(Installer.stage({ tag = TAG }, function() end), false)
		helpers.assert_eq(select(1, Installer.arm_swap("/private/tmp/user/x/app/ErgoptiPlus.app")), false)
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
		local status, output = sh("sh -c " .. quote(script) .. " stage " .. quote(URL) .. " " .. quote(digest)
			.. " " .. quote(dir .. "/stage") .. " 0.0.0-dev.139 /Applications/ErgoptiPlus.app "
			.. quote(opts.format or "zip") .. " " .. quote(opts.bundle or "ErgoptiPlus.app"))
		local called = read(calls) or ""
		sh("rm -rf " .. quote(dir))
		return status, output, called
	end

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
		if opts.previous then assert(sh("mkdir -p " .. quote(previous)) == 0) end
		if opts.no_stage then sh("rm -rf " .. quote(staged)) end
		local opened = dir .. "/opened"
		local open = fake(dir, "open", 'echo "$2" >> ' .. quote(opened))
		local script = Installer.SWAP_SCRIPT:gsub("/usr/bin/open", open)
		local pid = opts.pid or "999999999"
		local status, output = sh("sh -c " .. quote(script) .. " swap " .. pid .. " " .. quote(app) .. " "
			.. quote(staged) .. " " .. quote(previous))
		local result = {
			status = status, output = output,
			app = read(app .. "/marker"), previous = read(previous .. "/marker"), opened = read(opened) or "",
			app_path = app,
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
			return swap({ pid = sleeper, previous = true })
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

	helpers.it("puts the previous app back and opens it when the chosen one cannot move in", function()
		local result = swap({ no_stage = true })
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
