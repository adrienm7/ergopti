--- tests/unit/modules/llm/test_sha256_digest_escaped_names.lua

--- ==============================================================================
--- MODULE: SHA-256 Digest Of An Escaped Name (sha256-escaped-name)
--- DESCRIPTION:
--- shasum writes "\<digest>  <name>" when the name holds a backslash or a
--- newline. The installers took the first field as the digest, so a file under
--- a folder holding a backslash never matched its pin: the MLX wheel and lock
--- fingerprint, the Ollama archive, the native uv wheel, the release stage and
--- the Karabiner installer checksum all refused a genuine file (28 October
--- Linux pass, on ensure-mlx-deps.sh).
---
--- The shell installers now share sha256_file_digest (network-retry.sh); the
--- release stage and the Karabiner parser strip the marker themselves.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.onboarding_install_fixture")
local Scenario = require("tests.support.onboarding_install_scenarios")

local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end

local function command(text)
	local pipe = assert(io.popen("( " .. text .. " ) 2>&1; printf '\\n__STATUS__:%s' \"$?\"", "r"))
	local bytes = assert(pipe:read("*a"))
	assert(pipe:close())
	local status = assert(tonumber(bytes:match("__STATUS__:(%d+)%s*$")))
	return bytes:gsub("\n?__STATUS__:%d+%s*$", ""), status
end

helpers.describe("SHA-256 of a file whose name shasum escapes (sha256-escaped-name)", function()
	helpers.it("sha256_file_digest names the bare digest under a folder holding a backslash", function()
		local root = os.tmpname()
		os.remove(root)
		root = root .. "-digest\\folder"
		local llm = helpers.driver_root() .. "modules/llm/"
		local script = "set -eu; source " .. quote(llm .. "network-retry.sh")
			.. "; mkdir -p " .. quote(root) .. "; printf 'pinned bytes' > " .. quote(root .. "/f")
			.. "; printf 'raw=%s\\n' \"$(shasum -a 256 " .. quote(root .. "/f") .. ")\""
			.. "; printf 'stdin=%s\\n' \"$(shasum -a 256 < " .. quote(root .. "/f") .. ")\""
			.. "; printf 'digest=%s\\n' \"$(sha256_file_digest " .. quote(root .. "/f") .. ")\""
		local output, status = command("ROUTE_ORIGINS_FILE="
			.. quote(helpers.shared("modules/network/route_origins.json")) .. " /bin/bash -c " .. quote(script))
		command("rm -rf " .. quote(root))
		helpers.assert_eq(status, 0, output)
		helpers.assert_true(output:match("raw=\\%x+") ~= nil,
			"the fixture reproduces the escaped shasum line: " .. output)
		local expected = assert(output:match("stdin=(%x+)"), output)
		helpers.assert_eq(output:match("digest=([^\n]*)"), expected, "the helper names the bare digest")
	end)

	helpers.it("the Karabiner installer accepts the digest of an escaped name", function()
		Fixture.with_fixture({}, function(onboarding, calls)
			local outcomes = {}
			local task = Scenario.advance_to_stage(onboarding, calls, "checksum", function(ok, detail)
				outcomes[#outcomes + 1] = { ok = ok, detail = detail }
			end)
			task:complete(0, "\\" .. Fixture.TEST_SHA .. "  /Users/a\\\\b/Karabiner.dmg.part\n", "")
			helpers.assert_eq(#outcomes, 0, "the checksum stage did not refuse: "
				.. tostring(outcomes[1] and outcomes[1].detail))
			helpers.assert_eq(#calls.renames, 1, "the verified partial is promoted")
			helpers.assert_eq(#Scenario.tasks_for_stage(calls, "mount"), 1, "the mount stage follows")
		end)
	end)

	helpers.it("no macOS installer takes shasum's first field as the digest unescaped", function()
		local root = helpers.driver_root()
		local pipe = assert(io.popen("cd " .. quote(root) .. " && find modules adapters platform -name '*.sh' -type f"))
		local offenders, scanned = {}, 0
		for relative in pipe:lines() do
			local file = assert(io.open(root .. relative, "rb"))
			local source = file:read("*a")
			file:close()
			scanned = scanned + 1
			local lines = {}
			for line in (source .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
			for index, line in ipairs(lines) do
				if line:find("shasum %-a 256 \"") and not line:match("^%s*#") then
					-- The digest must lose the escape marker within the next two lines.
					local window = table.concat(lines, "\n", index, math.min(#lines, index + 2))
					if not window:find("#\\\\}", 1, true) then
						offenders[#offenders + 1] = relative .. ":" .. index .. ": " .. line
					end
				end
			end
		end
		pipe:close()
		helpers.assert_true(scanned >= 5, "the scan must reach the installers, saw " .. scanned)
		helpers.assert_eq(#offenders, 0, "use sha256_file_digest:\n" .. table.concat(offenders, "\n"))
	end)
end)
