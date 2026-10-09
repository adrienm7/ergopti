--- tests/unit/modules/llm/test_mlx_bootstrap_script.lua

--- ==============================================================================
--- MODULE: MLX Bootstrap Script Regression Tests
--- DESCRIPTION:
--- Runs the real modules/llm/ensure-mlx-deps.sh, in the launcher layout, over a
--- project mirror and a fake uv whose venv interpreter imports, or refuses to
--- import, the MLX packages:
--- 1. A venv is published, and exit 0 reported, only after its interpreter
---    imported the MLX packages; before, a venv that could not import mlx_lm
---    was published with its fingerprint and reused as installed for good.
--- 2. An installed venv that no longer imports is rebuilt, never trusted.
--- 3. The repair mode removes Ergopti's own venv and its staging leftovers,
---    and nothing else; it refuses a link or a folder without a Python
---    environment.
--- 4. The interpreter is uv's own Apple Silicon build, and uv's files stay in
---    Ergopti's folder, so a foreign ~/.local or ~/.cache cannot refuse them.
--- 5. The script and the Lua import probe import the same packages.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The script is macOS bash: it runs on any POSIX host with bash, and a host
-- without one (a Windows Lua) cannot execute it at all.
local POSIX = package.config:sub(1, 1) == "/"

local PYTHON_REQUEST = "cpython-3.11-macos-aarch64-none"





-- ====================================
-- ====================================
-- ======= 1/ Fixture Utilities =======
-- ====================================
-- ====================================

--- Quotes a value for /bin/sh.
--- @param value string
--- @return string
local function sh_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- Runs a shell command and returns its combined output and exit status.
--- @param command string
--- @return string output
--- @return integer|nil status
local function run(command)
	local handle = assert(io.popen("( " .. command .. " ) 2>&1; printf '\\n__STATUS__:%s' \"$?\""))
	local output = handle:read("*a")
	handle:close()
	local status = tonumber(output:match("__STATUS__:(%d+)%s*$"))
	return (output:gsub("\n?__STATUS__:%d+%s*$", "")), status
end

--- Writes a file.
--- @param path string
--- @param text string
local function write(path, text)
	local handle = assert(io.open(path, "w"))
	handle:write(text)
	handle:close()
end

--- Reads a file, nil when absent.
--- @param path string
--- @return string|nil
local function read(path)
	local handle = io.open(path, "r")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

--- Tells whether a path exists (a dangling link counts).
--- @param path string
--- @return boolean
local function exists(path)
	local _, status = run("[ -e " .. sh_quote(path) .. " ] || [ -L " .. sh_quote(path) .. " ]")
	return status == 0
end

-- The fake uv: a venv whose interpreter answers the import probe, failing it
-- while "$FIXTURE_ROOT/import-fails" exists, and a sync that installs the
-- package folders the fast path checks. Every call and its environment is
-- recorded for the assertions.
local FAKE_UV = [==[#!/usr/bin/env bash
set -eu
printf '%s | cache=%s python_dir=%s no_modify=%s preference=%s system_certs=%s ca_file=%s https_relay=%s no_relay=%s downloads=%s\n' "$*" \
	"${UV_CACHE_DIR:-}" "${UV_PYTHON_INSTALL_DIR:-}" "${UV_NO_MODIFY_PATH:-}" \
	"${UV_PYTHON_PREFERENCE:-}" "${UV_SYSTEM_CERTS:-}" "${SSL_CERT_FILE:-}${REQUESTS_CA_BUNDLE:-}" \
	"${HTTPS_PROXY:-}" "${NO_PROXY:-}" "${UV_PYTHON_DOWNLOADS:-}" >> "$FIXTURE_ROOT/uv.log"
case "${1:-}" in
	--version)
		printf '%s\n' 'uv 0.0.0-fixture'
		;;
	--help)
		printf '%s\n' '      --system-certs'
		;;
	python)
		exit 0
		;;
	venv)
		target="${2:?missing venv target}"
		mkdir -p "$target/bin" "$target/lib/python3.11/site-packages"
		printf '%s\n' 'home = /fixture/python' > "$target/pyvenv.cfg"
		cat > "$target/bin/python" <<'PY'
#!/usr/bin/env bash
if [ "${1:-}" = "-c" ]; then
	if [ -f "$FIXTURE_ROOT/import-fails" ]; then
		printf '%s\n' 'Traceback (most recent call last):' "ModuleNotFoundError: No module named 'mlx'" >&2
		exit 1
	fi
	printf '%s\n' "$2" >> "$FIXTURE_ROOT/probes.log"
fi
exit 0
PY
		chmod +x "$target/bin/python"
		;;
	sync)
		sp="$UV_PROJECT_ENVIRONMENT/lib/python3.11/site-packages"
		mkdir -p "$sp/mlx_lm" "$sp/huggingface_hub" "$sp/jinja2" "$sp/safetensors" "$sp/truststore"
		;;
	*)
		printf 'unexpected fake uv command: %s\n' "$*" >&2
		exit 97
		;;
esac
]==]

--- Builds a project mirror, a home and the fake uv under a fresh scratch folder.
--- @return table fixture { root, home, venv, app_support, script }
local function new_fixture()
	local root = helpers.temp_dir() .. "/mlx-bootstrap-script-" .. tostring(os.time())
		.. "-" .. tostring(math.random(1, 1000000000))
	local driver = helpers.driver_root()
	local project = root .. "/project"
	local home = root .. "/home"
	local _, made = run("mkdir -p " .. sh_quote(project .. "/modules/llm") .. " "
		.. sh_quote(home .. "/.local/bin") .. " && cp "
		.. sh_quote(driver .. "modules/llm/ensure-mlx-deps.sh") .. " "
		.. sh_quote(driver .. "modules/llm/network-retry.sh") .. " "
		.. sh_quote(driver .. "modules/llm/uv-release.sh") .. " "
		.. sh_quote(project .. "/modules/llm/") .. " && cp "
		.. sh_quote(driver .. "pyproject.toml") .. " " .. sh_quote(driver .. "uv.lock") .. " "
		.. sh_quote(project .. "/"))
	helpers.assert_eq(made, 0, "the fixture project must be created")
	write(home .. "/.local/bin/uv", FAKE_UV)
	run("chmod +x " .. sh_quote(home .. "/.local/bin/uv"))
	local app_support = home .. "/Library/Application Support/Ergopti"
	return {
		root = root,
		home = home,
		app_support = app_support,
		venv = app_support .. "/mlx-venv",
		script = project .. "/modules/llm/ensure-mlx-deps.sh",
	}
end

--- Runs the script in the launcher layout.
--- @param fixture table
--- @param extra string|nil Extra environment assignments.
--- @return string output
--- @return integer|nil status
local function bootstrap(fixture, extra)
	return run("cd " .. sh_quote(fixture.root) .. " && FIXTURE_ROOT=" .. sh_quote(fixture.root)
		.. " HOME=" .. sh_quote(fixture.home)
		.. " ERGOPTI_CONFIG_DIR=/Applications/ErgoptiPlus.app/Contents/Resources/static "
		-- The fixture supplies its own network inputs; inherited host lowercase
		-- routes/CA variables cannot masquerade as the caller's explicit values.
		.. "HTTPS_PROXY=http://fixture.invalid:3128 https_proxy= HTTP_PROXY= http_proxy= ALL_PROXY= all_proxy= "
		.. "NO_PROXY= no_proxy= SSL_CERT_FILE= REQUESTS_CA_BUNDLE= "
		.. (extra or "") .. " bash " .. sh_quote(fixture.script))
end

--- Removes a fixture folder.
--- @param fixture table
local function dispose(fixture)
	run("rm -rf " .. sh_quote(fixture.root))
end

--- Registers a test that needs bash; a host without it reports why.
--- @param name string
--- @param body function Receives a fresh fixture.
local function it_runs(name, body)
	helpers.it(name, function()
		helpers.assert_true(POSIX, "this suite runs the bash script and needs a POSIX host")
		local fixture = new_fixture()
		local ok, err = xpcall(body, debug.traceback, fixture)
		dispose(fixture)
		if not ok then error(err, 0) end
	end)
end





-- ============================================
-- ============================================
-- ======= 2/ Import-Proven Publication =======
-- ============================================
-- ============================================

if POSIX then
helpers.describe("The MLX venv is published only once it imports (mlx-bootstrap-import-proof)", function()
	it_runs("refuses to publish a venv whose interpreter cannot import MLX", function(fixture)
		write(fixture.root .. "/import-fails", "")
		local output, status = bootstrap(fixture)
		helpers.assert_eq(status, 4, "a venv that cannot import mlx_lm must fail the bootstrap: " .. output)
		helpers.assert_true(output:find("No module named 'mlx'", 1, true) ~= nil,
			"the interpreter's own error names the cause: " .. output)
		helpers.assert_eq(exists(fixture.venv), false, "nothing is published")
		helpers.assert_eq(exists(fixture.venv .. "/.last_sync_hash"), false, "no fingerprint is written")
		local _, leftovers = run("ls -d " .. sh_quote(fixture.venv) .. ".* >/dev/null 2>&1")
		helpers.assert_true(leftovers ~= 0, "the rejected candidate is removed")
	end)

	it_runs("publishes the venv and its fingerprint once the probe imported MLX", function(fixture)
		local output, status = bootstrap(fixture)
		helpers.assert_eq(status, 0, output)
		helpers.assert_true(exists(fixture.venv .. "/bin/python"), "the venv is published")
		helpers.assert_true(exists(fixture.venv .. "/.last_sync_hash"), "its fingerprint is written")
		local probes = read(fixture.root .. "/probes.log") or ""
		helpers.assert_true(probes:find("import mlx_lm", 1, true) ~= nil,
			"success is reported only after the import probe ran")
		helpers.assert_true(output:find("IMPORT_CHECKING", 1, true) ~= nil,
			"the probe is announced to the progress window")
	end)

	it_runs("rebuilds an installed venv that no longer imports instead of reusing it", function(fixture)
		local _, first = bootstrap(fixture)
		helpers.assert_eq(first, 0)
		write(fixture.root .. "/import-fails", "")
		local output, status = bootstrap(fixture)
		helpers.assert_true(status ~= 0,
			"the fast path must not exit 0 on a venv that cannot import: " .. output)
		helpers.assert_true(output:find("does not import MLX", 1, true) ~= nil, output)
	end)
end)





-- =====================================================
-- =====================================================
-- ======= 3/ Repair Removes Only Ergopti's Venv =======
-- =====================================================
-- =====================================================

helpers.describe("The MLX repair removes only Ergopti's venv (mlx-bootstrap-repair-script)", function()
	it_runs("removes the venv and its leftovers, keeps its neighbours, rebuilds it", function(fixture)
		local _, first = bootstrap(fixture)
		helpers.assert_eq(first, 0)
		write(fixture.venv .. "/stale-package", "broken")
		run("mkdir -p " .. sh_quote(fixture.venv .. ".bootstrap.12345/bin"))
		write(fixture.app_support .. "/keep.txt", "not the venv")
		local output, status = bootstrap(fixture, "ERGOPTI_MLX_REPAIR=1")
		helpers.assert_eq(status, 0, output)
		helpers.assert_eq(exists(fixture.venv .. "/stale-package"), false,
			"the repair removes the venv before rebuilding it")
		helpers.assert_eq(exists(fixture.venv .. ".bootstrap.12345"), false,
			"an interrupted run's staging folder is removed too")
		helpers.assert_true(exists(fixture.venv .. "/bin/python"), "the venv is rebuilt")
		helpers.assert_true(exists(fixture.venv .. "/.last_sync_hash"))
		helpers.assert_eq(read(fixture.app_support .. "/keep.txt"), "not the venv",
			"nothing beside the venv is touched")
		local uv_log = read(fixture.root .. "/uv.log") or ""
		helpers.assert_true(uv_log:find("sync [^\n]*%-%-refresh") ~= nil,
			"the repair downloads the packages again: " .. uv_log)
		helpers.assert_true(output:find("VENV_REMOVING", 1, true) ~= nil)
	end)

	it_runs("refuses a venv that is a link and leaves its target intact", function(fixture)
		local outside = fixture.root .. "/outside"
		run("mkdir -p " .. sh_quote(outside .. "/bin") .. " " .. sh_quote(fixture.app_support))
		write(outside .. "/precious.txt", "keep me")
		write(outside .. "/pyvenv.cfg", "home = /elsewhere\n")
		run("ln -s " .. sh_quote(outside) .. " " .. sh_quote(fixture.venv))
		local output, status = bootstrap(fixture, "ERGOPTI_MLX_REPAIR=1")
		helpers.assert_eq(status, 5, "a link is never Ergopti's venv: " .. output)
		helpers.assert_true(output:find("Refusing to remove", 1, true) ~= nil, output)
		helpers.assert_eq(read(outside .. "/precious.txt"), "keep me")
		local _, is_link = run("[ -L " .. sh_quote(fixture.venv) .. " ]")
		helpers.assert_eq(is_link, 0, "the link itself is left in place")
	end)

	it_runs("refuses a folder that holds no Python environment", function(fixture)
		run("mkdir -p " .. sh_quote(fixture.venv))
		write(fixture.venv .. "/notes.txt", "user data")
		local output, status = bootstrap(fixture, "ERGOPTI_MLX_REPAIR=1")
		helpers.assert_eq(status, 5, output)
		helpers.assert_eq(read(fixture.venv .. "/notes.txt"), "user data",
			"a folder Ergopti did not create keeps its files")
	end)
end)





-- ================================================
-- ================================================
-- ======= 4/ Owned Interpreter And Folders =======
-- ================================================
-- ================================================

helpers.describe("The MLX venv uses uv's Apple Silicon Python in owned folders (mlx-bootstrap-owned-interpreter)", function()
	it_runs("asks uv for its own arm64 interpreter and keeps uv's files in Application Support", function(fixture)
		local output, status = bootstrap(fixture)
		helpers.assert_eq(status, 0, output)
		local uv_log = read(fixture.root .. "/uv.log") or ""
		helpers.assert_true(uv_log:find("venv [^\n]*%-%-python " .. PYTHON_REQUEST:gsub("%-", "%%-")) ~= nil,
			"the venv must not take a system, Homebrew or x86_64 Python: " .. uv_log)
		helpers.assert_true(uv_log:find("preference=only-managed", 1, true) ~= nil, uv_log)
		helpers.assert_true(uv_log:find("cache=" .. fixture.app_support .. "/mlx-uv/cache", 1, true) ~= nil,
			"uv's cache lives in Ergopti's folder: " .. uv_log)
		helpers.assert_true(uv_log:find("python_dir=" .. fixture.app_support .. "/mlx-uv/python", 1, true) ~= nil,
			uv_log)
		helpers.assert_true(uv_log:find("no_modify=1", 1, true) ~= nil,
			"the uv installer must never edit the user's shell profiles")
	end)
end)
end





-- ===============================================
-- ===============================================
-- ======= 4b/ Never Rosetta (hardening-h) =======
-- ===============================================
-- ===============================================

-- An x86_64-only Mach-O header, as file(1) identifies it on macOS and Linux.
local INTEL_MACHO = "\207\250\237\254" .. "\7\0\0\1" .. "\3\0\0\0" .. "\2\0\0\0" .. string.rep("\0", 64)

if POSIX then
helpers.describe("No uv or venv Python built for another processor is started (hardening-h-no-rosetta)", function()
	it_runs("skips an Intel uv first in PATH for a native one", function(fixture)
		-- The Intel Homebrew uv of a migrated Mac, found first; the native uv after it.
		run("mkdir -p " .. sh_quote(fixture.home .. "/.cargo/bin") .. " && mv "
			.. sh_quote(fixture.home .. "/.local/bin/uv") .. " " .. sh_quote(fixture.home .. "/.cargo/bin/uv"))
		write(fixture.home .. "/.local/bin/uv", INTEL_MACHO)
		run("chmod +x " .. sh_quote(fixture.home .. "/.local/bin/uv"))
		local output, status = bootstrap(fixture, "ERGOPTI_NATIVE_ARCH=arm64")
		helpers.assert_eq(status, 0, output)
		helpers.assert_true(output:find("Skipping " .. fixture.home .. "/.local/bin/uv", 1, true) ~= nil, output)
		helpers.assert_true((read(fixture.root .. "/uv.log") or ""):find("venv", 1, true) ~= nil,
			"the native uv built the venv")
	end)

	it_runs("rebuilds a venv whose Python is Intel without ever starting it", function(fixture)
		local _, first = bootstrap(fixture, "ERGOPTI_NATIVE_ARCH=arm64")
		helpers.assert_eq(first, 0)
		-- The venv an Intel interpreter built: same fingerprint, same packages.
		os.remove(fixture.venv .. "/bin/python")
		write(fixture.venv .. "/bin/python", INTEL_MACHO)
		run("chmod +x " .. sh_quote(fixture.venv .. "/bin/python"))
		local output, status = bootstrap(fixture, "ERGOPTI_NATIVE_ARCH=arm64")
		helpers.assert_eq(status, 0, output)
		helpers.assert_true(output:find("built for another processor than arm64", 1, true) ~= nil, output)
		helpers.assert_true(output:find("do not import with " .. fixture.venv .. "/bin/python", 1, true) == nil,
			"the Intel interpreter is never started, not even to probe it: " .. output)
		local header = read(fixture.venv .. "/bin/python") or ""
		helpers.assert_true(header:sub(1, 2) == "#!", "the venv is rebuilt on uv's own interpreter")
	end)
end)
end





-- ====================================
-- ====================================
-- ======= 4c/ Managed Networks =======
-- ====================================
-- ====================================

-- What `scutil --proxy` prints on a Mac whose network settings name a relay.
local SCUTIL_RELAY = table.concat({
	"<dictionary> {",
	"  ExceptionsList : <array> {",
	"    0 : *.local",
	"    1 : 169.254/16",
	"  }",
	"  HTTPEnable : 1",
	"  HTTPPort : 3128",
	"  HTTPProxy : relay.corp",
	"  HTTPSEnable : 1",
	"  HTTPSPort : 3129",
	"  HTTPSProxy : relay.corp",
	"  ProxyAutoConfigEnable : 0",
	"}",
}, "\n")

--- The uv.log lines of one subcommand.
--- @param fixture table
--- @param subcommand string e.g. "venv", "sync".
--- @return table lines
local function uv_calls(fixture, subcommand)
	local lines = {}
	for line in (read(fixture.root .. "/uv.log") or ""):gmatch("[^\n]+") do
		if line:find("^" .. subcommand .. " ") then lines[#lines + 1] = line end
	end
	return lines
end

if POSIX then
helpers.describe("The installer works on a managed network (mlx-bootstrap-managed-network)", function()
	it_runs("trusts the system store and hands no CA file to uv", function(fixture)
		-- A GUI launch carries no CA variable; the host running the suite may.
		local output, status = bootstrap(fixture, "SSL_CERT_FILE= REQUESTS_CA_BUNDLE=")
		helpers.assert_eq(status, 0, output)
		local syncs = uv_calls(fixture, "sync")
		helpers.assert_true(#syncs > 0, "uv sync ran")
		for _, line in ipairs(syncs) do
			helpers.assert_true(line:find("system_certs=1", 1, true) ~= nil,
				"uv loads the keychain's roots, a company inspection certificate included: " .. line)
			helpers.assert_true(line:find("ca_file= ", 1, true) ~= nil,
				"no CA file overrides the system store (the Mozilla bundle refused every "
					.. "download behind a TLS-inspecting relay): " .. line)
		end
	end)

	it_runs("hands the relay to uv with loopback excluded", function(fixture)
		local output, status = bootstrap(fixture, "HTTPS_PROXY=http://relay.corp:3129 NO_PROXY=intranet.corp")
		helpers.assert_eq(status, 0, output)
		local sync = uv_calls(fixture, "sync")[1] or ""
		helpers.assert_true(sync:find("https_relay=http://relay.corp:3129", 1, true) ~= nil, sync)
		helpers.assert_true(sync:find("no_relay=intranet.corp,localhost,127.0.0.1,::1", 1, true) ~= nil,
			"the local servers never go through the relay: " .. sync)
	end)

	it_runs("builds the venv on a native system Python without downloading one", function(fixture)
		local python = fixture.root .. "/native-python3"
		write(python, "#!/usr/bin/env bash\nexit 0\n")
		run("chmod +x " .. sh_quote(python))
		local output, status = bootstrap(fixture, "ERGOPTI_NATIVE_PYTHONS=" .. sh_quote("/nonexistent/python3:" .. python))
		helpers.assert_eq(status, 0, output)
		local venv = uv_calls(fixture, "venv")[1] or ""
		helpers.assert_true(venv:find("--python " .. python, 1, true) ~= nil, venv)
		helpers.assert_true(venv:find("downloads=never", 1, true) ~= nil, venv)
		helpers.assert_true(venv:find("preference=only%-system") ~= nil, venv)
		helpers.assert_eq(#uv_calls(fixture, "python"), 0,
			"no managed interpreter is looked up or downloaded (GitHub)")
	end)

	helpers.it("reads the relay and its exceptions from scutil, and names a PAC it cannot apply", function()
		local driver = helpers.driver_root()
		local function parse(text)
			local output = run("printf '%s' " .. sh_quote(text) .. " | bash -c "
				.. sh_quote(". " .. sh_quote(driver .. "modules/llm/network-retry.sh") .. " && system_network_from_scutil"))
			return (output:gsub("%s+$", ""))
		end
		helpers.assert_eq(parse(SCUTIL_RELAY),
			"HTTPS_PROXY=http://relay.corp:3129\nHTTP_PROXY=http://relay.corp:3128\nNO_PROXY=.local,169.254/16")
		helpers.assert_eq(parse("<dictionary> {\n  HTTPSEnable : 0\n  ProxyAutoConfigEnable : 1\n"
			.. "  ProxyAutoConfigURLString : http://wpad.corp/relay.pac\n}"), "PAC_URL=http://wpad.corp/relay.pac")
		helpers.assert_eq(parse("<dictionary> {\n  HTTPSEnable : 0\n}"), "")
	end)

	helpers.it("installs uv from its pinned PyPI wheel, never an installer piped into a shell", function()
		local driver = helpers.driver_root()
		local script = assert(read(driver .. "modules/llm/ensure-mlx-deps.sh"))
		local release = assert(read(driver .. "modules/llm/uv-release.sh"))
		helpers.assert_true(script:find("| sh", 1, true) == nil and script:find("astral.sh", 1, true) == nil,
			"the Astral installer downloads uv from GitHub, which company networks block")
		helpers.assert_true(release:find('UV_WHEEL_ARM64_URL="https://files.pythonhosted.org/', 1, true) ~= nil)
		helpers.assert_true(release:match('UV_WHEEL_ARM64_SHA256="%x+"') ~= nil
			and #release:match('UV_WHEEL_ARM64_SHA256="(%x+)"') == 64, "the wheel is pinned by its SHA-256")
	end)
end)
end





-- ===================================
-- ===================================
-- ======= 5/ One Import Probe =======
-- ===================================
-- ===================================

helpers.describe("The script and the Lua probe import the same packages (mlx-bootstrap-probe-parity)", function()
	--- Lists the modules an "import a; import b" statement names.
	--- @param statement string
	--- @return table sorted
	local function modules_of(statement)
		local names = {}
		for name in statement:gmatch("import%s+([%w_%.]+)") do names[#names + 1] = name end
		table.sort(names)
		return names
	end

	helpers.it("probes the same modules before publishing and before reusing", function()
		local driver = helpers.driver_root()
		local script = assert(read(driver .. "modules/llm/ensure-mlx-deps.sh"))
		local manager = assert(read(driver .. "ui/menu/menu_llm/models_manager_mlx.lua"))
		local script_probe = script:match('\nMLX_IMPORT_PROBE="([^"]+)"')
		helpers.assert_not_nil(script_probe, "ensure-mlx-deps.sh must declare its import probe")
		local lua_probe = manager:match("%-c '(import mlx_lm[^']+)'")
		helpers.assert_not_nil(lua_probe, "models_manager_mlx must keep its import probe")
		helpers.assert_eq(modules_of(script_probe), modules_of(lua_probe),
			"a venv the script published must pass the probe that reuses it")
	end)
end)
