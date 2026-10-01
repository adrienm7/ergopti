--- tests/e2e/boot/boot_scenarios.lua

--- ==============================================================================
--- MODULE: Installed-Application Boot Scenarios
--- DESCRIPTION:
--- Boots the REAL init.lua of an installed ErgoptiPlus.app copy, one child
--- process per boot (boot_child.lua), over the user states that decide what a
--- boot does: a fresh install, the neutral defaults, the recommended preset
--- imported through the menu, and configuration files written by older
--- versions. Every boot must log no ERROR, show no dialog, never exit, and
--- neither write nor look up user data inside the application bundle.
---
--- FEATURES & RATIONALE:
--- 1. hardening-a-startup-zero-error: a startup ERROR reached users while CI
---    stayed green, because no suite booted the driver past the first-run
---    wizard. Each scenario judges the whole boot plus a virtual minute of its
---    deferred work.
--- 2. hardening-b-installed-layout: the driver runs from a copy staged as the
---    app bundle (Contents/Resources/static), its configuration elsewhere.
---    The apps dashboard read its categories from hs.configdir/data, inside the
---    bundle, and showed nothing (982f2b801).
--- 3. hardening-e-presets: the recommended preset is imported by clicking the
---    real « Restore recommended values » row, then booted: the navigation
---    layer must be non-empty and entered by a key (db71c39bf).
--- 4. Both processors (boot-arch-ollama-default): every scenario boots on an
---    Apple silicon Mac and on an Intel Mac, at once. The default AI backend
---    follows the processor, and an Intel Mac booting an older config.toml
---    started the Ollama it never installed, with the AI off, and logged an
---    ERROR that arm64 boots could not show. A boot that turns the AI on
---    without its runtime must tell the user so, naming that runtime.
--- 5. The boot's Karabiner lease (layout-name-forms): an Ergopti layout, whose
---    localised and HIToolbox names differ, made the first layout poll report a
---    change that fenced the boot's RESUME in flight, logged « prepared lease
---    RESUME failed: lease-stopping » and opened the error window. The boot of
---    that layout keeps its one lease worker. A real layout switch or a reload
---    while that RESUME is in flight supersedes the activation without an ERROR
---    (lease-stop-supersedes-activation).
--- 6. hardening-h-no-rosetta: on Apple silicon no started process may lack an
---    arm64 slice. dev.155 opened, on a Mac migrated from an Intel one, macOS's
---    "support for Intel-based apps is ending" notice about Python: the boot's
---    input-source probe ran /usr/bin/python3, whose xcode-select shim runs the
---    active developer folder's python3, and that copy was x86_64 only. The
---    migrated Mac keeps those Intel Pythons (and an Intel Homebrew in
---    /usr/local); a Python helper started after the boot must pick the arm64 one.
--- ==============================================================================

local M = {}

local ON_WINDOWS = package.config:sub(1, 1) == "\\"

-- The line each boot must reach: the wizard of a fresh install, or the end of
-- a configured boot.
local WIZARD_MARKER = "Onboarding wizard opened."
local BOOTED_MARKER = "Hammerspoon boot SUCCESSFUL."





-- ==================================
-- ==================================
-- ======= 1/ Staging ===============
-- ==================================
-- ==================================

--- Quotes one value for /bin/sh.
--- @param value string
--- @return string
local function q(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- Runs one POSIX command and raises on failure.
--- @param command string
local function run(command)
	local result = os.execute(command)
	if not (result == true or result == 0) then error("boot scenarios: command failed: " .. command, 2) end
end

--- Reads one whole file.
--- @param path string
--- @return string|nil
local function read(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	return content
end

--- Stages ErgoptiPlus.app under `root` from the repository, once for every
--- scenario (a boot must leave it as it found it), with the layout
--- tools/build/macos-bundle-manifest.json declares: the driver and the shared
--- tree without tests, launcher sources or documentation, the menu logos, the
--- newest keyboard-layout bundle, the layout registry and a build stamp.
--- @param repo string Repository root.
--- @param root string Scenario root.
local function stage_app(repo, root)
	local static = root .. "/ErgoptiPlus.app/Contents/Resources/static"
	run("mkdir -p " .. q(static .. "/ergopti_plus") .. " " .. q(static .. "/img/logo") .. " "
		.. q(static .. "/layouts") .. " " .. q(static .. "/ergopti/macos/bundles") .. " "
		.. q(root .. "/ErgoptiPlus.app/Contents/MacOS"))
	run("cp -R " .. q(repo .. "/static/ergopti_plus/macos") .. " " .. q(repo .. "/static/ergopti_plus/_shared")
		.. " " .. q(static .. "/ergopti_plus/"))
	run("rm -rf " .. q(static .. "/ergopti_plus/macos/tests") .. " " .. q(static .. "/ergopti_plus/macos/launcher")
		.. " " .. q(static .. "/ergopti_plus/_shared/tests") .. " " .. q(static .. "/ergopti_plus/_shared/lua/test"))
	run("find " .. q(static .. "/ergopti_plus") .. " -name '*.md' -type f -exec rm -f {} +")
	for _, logo in ipairs({ "logo_black.png", "logo_simple.png", "logo_simple_disabled.png", "logo_white.png" }) do
		run("cp " .. q(repo .. "/static/img/logo/" .. logo) .. " " .. q(static .. "/img/logo/"))
	end
	run("cp -R " .. q(repo .. "/static/layouts/registry") .. " " .. q(static .. "/layouts/"))
	local newest = nil
	local listing = io.popen("ls " .. q(repo .. "/static/ergopti/macos/bundles"))
	for name in listing:lines() do
		if name:match("^Ergopti_v[%d.]+%.bundle$") and (newest == nil or name > newest) then newest = name end
	end
	listing:close()
	run("cp -R " .. q(repo .. "/static/ergopti/macos/bundles/" .. assert(newest, "no keyboard-layout bundle"))
		.. " " .. q(static .. "/ergopti/macos/bundles/"))
	local stamp = assert(io.open(static .. "/ergopti_plus/_shared/build_stamp.txt", "w"))
	stamp:write("commit=0000000000000000000000000000000000e2e000\n")
	stamp:close()
	local helper = assert(io.open(root .. "/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus", "w"))
	helper:write("#!/bin/sh\nexit 0\n")
	helper:close()
	run("chmod 755 " .. q(root .. "/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"))
end

--- Lists every file of the bundle, to compare before and after the boots.
--- @param root string Scenario root.
--- @return table set Path -> size.
local function bundle_files(root)
	local files = {}
	local listing = io.popen("cd " .. q(root) .. " && find ErgoptiPlus.app -type f")
	for path in listing:lines() do files[path] = true end
	listing:close()
	return files
end





-- =====================================
-- =====================================
-- ======= 2/ User states ==============
-- =====================================
-- =====================================

--- Writes one file under the scenario's HOME.
--- @param home string
--- @param relative string
--- @param content string
local function write_home(home, relative, content)
	local path = home .. "/" .. relative
	run("mkdir -p " .. q(path:match("^(.*)/[^/]+$")))
	local fh = assert(io.open(path, "wb"))
	fh:write(content)
	fh:close()
end

--- The first-run wizard completed with the neutral defaults on a Mac where
--- Karabiner-Elements is set up.
--- @param ctx table Scenario context.
local function neutral_defaults(ctx)
	write_home(ctx.home, ".config/ergopti_plus/hammerspoon/config.toml",
		assert(read(ctx.driver .. "/_generated/config_template.toml"), "config template missing"))
	ctx.world.install_karabiner(ctx.root .. "/machine", ctx.home)
end

--- A configuration folder an older release left, with its config.toml from the
--- shared migration corpus (a file that version wrote).
--- @param case string Case directory under _shared/tests/corpus/config_migrations.
--- @param extra function|nil Adds more of that release's state.
--- @return function setup
local function older_release(case, extra)
	return function(ctx)
		local input = ctx.repo .. "/static/ergopti_plus/_shared/tests/corpus/config_migrations/" .. case .. "/input.toml"
		write_home(ctx.home, ".config/ergopti_plus/hammerspoon/config.toml", assert(read(input), "missing " .. input))
		write_home(ctx.home, ".config/ergopti_plus/wrap_symbols.toml", "")
		ctx.world.install_karabiner(ctx.root .. "/machine", ctx.home)
		if extra then extra(ctx) end
	end
end

--- A Mac migrated from an Intel one: the Command Line Tools and the Homebrew
--- it brought along are x86_64 only, beside an Apple silicon Homebrew.
--- @param ctx table Scenario context.
local function migrated_from_intel(ctx)
	neutral_defaults(ctx)
	local machine = ctx.root .. "/machine"
	ctx.world.write_macho(machine .. "/Library/Developer/CommandLineTools/usr/bin/python3", { "x86_64" })
	ctx.world.write_macho(machine .. "/usr/local/bin/python3", { "x86_64" })
	ctx.world.write_macho(machine .. "/opt/homebrew/bin/python3", { "arm64" })
end

--- The same migrated Mac without any arm64 Python: nothing at boot needs one,
--- so the boot neither starts an Intel Python nor asks for a native one.
--- @param ctx table Scenario context.
local function migrated_from_intel_without_native_python(ctx)
	neutral_defaults(ctx)
	local machine = ctx.root .. "/machine"
	ctx.world.write_macho(machine .. "/Library/Developer/CommandLineTools/usr/bin/python3", { "x86_64" })
	ctx.world.write_macho(machine .. "/usr/local/bin/python3", { "x86_64" })
end

--- The preference keys and the tilde paths.toml of releases before the
--- namespaced settings (tools/diagnostics/macos_launch_gate.py: upgraded,
--- tilde_paths).
--- @param ctx table
local function legacy_settings_and_tilde_paths(ctx)
	ctx.settings = {
		i18n_locale = "fr",
		["llm.enabled"] = false,
		llm_backend = "mlx",
		llm_max_words = 20,
		magickey_repeat_enabled = true,
		ergopti_menubar_logo_variant = "default",
	}
	write_home(ctx.home, "Library/Application Support/ErgoptiPlus/paths.toml",
		"# Custom paths — auto-generated by ErgoptiPlus.\n\nConfigDirPath = \"~/.config/ergopti_plus/\"\n")
end

-- The config.toml files older macOS releases wrote: every shipped case of the
-- shared migration corpus, found by name so a new case boots without an edit
-- here. An unstamped one predates the namespaced settings, and its release
-- also left their preference keys and a tilde paths.toml.
local CORPUS_REL = "/static/ergopti_plus/_shared/tests/corpus/config_migrations"

--- Reads one key of one table of a flat config.toml (headers, then
--- `key = value` lines), the shape every corpus input has.
--- @param toml string File content.
--- @param section string Table header without brackets, e.g. "llm".
--- @param key string
--- @return string|nil value Raw value text.
local function toml_value(toml, section, key)
	local current = nil
	for line in toml:gmatch("[^\n]+") do
		local header = line:match("^%s*%[([^%]]+)%]%s*$")
		if header then
			current = header
		elseif current == section then
			local value = line:match("^%s*" .. key .. "%s*=%s*(.-)%s*$")
			if value then return value end
		end
	end
	return nil
end

--- The runtime a boot that turns the AI on must name when it is missing, as
--- the product defines it: the selected backend, else the platform default
--- (MLX on Apple silicon, Ollama on Intel). The E2E Mac installs neither.
--- @param case table { enables_ai, selected } from older_release_cases.
--- @param arch string
--- @return string|nil runtime Product name, or nil when the AI stays off.
local function missing_ai_runtime(case, arch)
	if not case.enables_ai then return nil end
	local selected = case.selected or (arch == "arm64" and "mlx" or "ollama")
	return ({ mlx = "MLX", ollama = "Ollama" })[selected]
end

--- The shipped corpus cases of macOS, sorted, each with its schema version
--- and what its config.toml says about the AI.
--- @param repo string Repository root.
--- @return table cases { name, stamped, enables_ai, selected }
local function older_release_cases(repo)
	local cases = {}
	local listing = io.popen("ls " .. q(repo .. CORPUS_REL))
	for name in listing:lines() do
		if name:match("^shipped_.+_on_macos$") then
			local input = assert(read(repo .. CORPUS_REL .. "/" .. name .. "/input.toml"), "missing input of " .. name)
			cases[#cases + 1] = {
				name = name,
				stamped = input:find("schema_version%s*=") ~= nil,
				enables_ai = toml_value(input, "llm", "enabled") == "true",
				selected = (toml_value(input, "llm.models", "selected") or ""):match('^"(%w+)"$'),
			}
		end
	end
	listing:close()
	table.sort(cases, function(a, b) return a.name < b.name end)
	return cases
end

--- Every scenario: the fixed user states, then one per older release.
--- @param repo string Repository root.
--- @return table scenarios
local function scenarios(repo)
	local list = {
		{ name = "a fresh install opens the first-run wizard", steps = { "boot" }, marker = WIZARD_MARKER },
		{ name = "the neutral defaults boot", setup = neutral_defaults, steps = { "boot" }, marker = BOOTED_MARKER },
		-- Booted over the recommended preset, it then opens every window and file the
		-- action catalogue can open, which the recommended shortcuts admit.
		{ name = "the recommended preset imported from the menu boots and opens its windows",
			setup = neutral_defaults, steps = { "restore_recommended", "open_windows" }, marker = BOOTED_MARKER,
			recommended = true },
		-- world.MACHINES: the machine each boot runs on, and the lease facts it ends with.
		{ name = "an Ergopti layout boots while the lease worker answers late, on one lease worker",
			setup = neutral_defaults, steps = { "boot" }, marker = BOOTED_MARKER,
			machine = "ergopti_layout_slow_worker", facts = { lease_workers = "1", lease_phase = "active" } },
		{ name = "a layout switch while the boot's RESUME is in flight activates a fresh lease",
			setup = neutral_defaults, steps = { "boot" }, marker = BOOTED_MARKER,
			machine = "layout_switch_during_resume", facts = { lease_workers = "2", lease_phase = "active" } },
		{ name = "a reload while the boot's RESUME is in flight fences the lease before reloading",
			setup = neutral_defaults, steps = { "boot" }, marker = BOOTED_MARKER,
			machine = "reload_during_resume", facts = { native_reloads = "1", lease_phase = "idle" } },
		-- hardening-h-no-rosetta: the recommended shortcuts, then a Python helper
		-- (the display-mirror shortcut), which must pick the arm64 Homebrew.
		{ name = "a Mac migrated from Intel boots and runs a Python helper without Rosetta",
			setup = migrated_from_intel, steps = { "restore_recommended", "python_helper" }, marker = BOOTED_MARKER },
		{ name = "a Mac migrated from Intel without an arm64 Python boots without Rosetta",
			setup = migrated_from_intel_without_native_python, steps = { "boot" }, marker = BOOTED_MARKER },
	}
	for _, case in ipairs(older_release_cases(repo)) do
		list[#list + 1] = {
			name = "an older release's config.toml boots (" .. case.name
				.. (case.stamped and ")" or ", unstamped, with legacy settings and a tilde paths.toml)"),
			setup = older_release(case.name, not case.stamped and legacy_settings_and_tilde_paths or nil),
			steps = { "boot" }, marker = BOOTED_MARKER,
			-- The legacy preference keys of an unstamped release turn the AI off
			ai_runtime = case.stamped and function(arch) return missing_ai_runtime(case, arch) end or nil,
		}
	end
	if #list < 6 then error("boot scenarios: the migration corpus holds fewer than three macOS releases") end
	local turns_ai_on = false
	for _, scenario in ipairs(list) do
		turns_ai_on = turns_ai_on or (scenario.ai_runtime ~= nil and scenario.ai_runtime("x86_64") ~= nil)
	end
	if not turns_ai_on then
		error("boot scenarios: no stamped macOS release of the migration corpus turns the AI on")
	end
	return list
end





-- ===================================
-- ===================================
-- ======= 3/ Running and judging ====
-- ===================================
-- ===================================

--- The shell command of one child, its settings file written.
--- @param ctx table Scenario context of one architecture.
--- @param action string boot_child action.
--- @return string command
local function child_command(ctx, action)
	local machine = ctx.machine or "standard"
	local settings_file = ctx.root .. "/settings.lua"
	local fh = assert(io.open(settings_file, "w"))
	fh:write("return {\n")
	for key, value in pairs(ctx.settings or {}) do
		fh:write(string.format("\t[%q] = %s,\n", key, type(value) == "string" and string.format("%q", value)
			or tostring(value)))
	end
	fh:write("}\n")
	fh:close()
	return table.concat({
		"cd " .. q(ctx.root) .. " &&",
		"HOME=" .. q(ctx.home), "TMPDIR=" .. q(ctx.root .. "/tmp"),
		"XDG_CONFIG_HOME=", "XDG_STATE_HOME=", "XDG_DATA_HOME=", "XDG_CACHE_HOME=",
		q(ctx.interpreter), q(ctx.driver .. "/tests/e2e/boot/boot_child.lua"),
		q(ctx.driver), q(ctx.app_root), q(ctx.root .. "/machine"), q(ctx.home), q(action), q(ctx.arch),
		q(settings_file), q(machine),
	}, " ")
end

--- Runs one action on every architecture at once, one child each, so the
--- second processor costs no second wait.
--- @param contexts table Scenario contexts, one per architecture.
--- @param action string boot_child action.
--- @return table outputs Each child's complete output, by context index.
local function run_children(contexts, action)
	local jobs = {}
	for index, ctx in ipairs(contexts) do
		jobs[index] = "(" .. child_command(ctx, action) .. ") > " .. q(ctx.root .. "/" .. action .. ".out") .. " 2>&1 &"
	end
	jobs[#jobs + 1] = "wait"
	-- Each child's output is judged, not this shell's status
	os.execute(table.concat(jobs, " "))
	local outputs = {}
	for index, ctx in ipairs(contexts) do
		outputs[index] = read(ctx.root .. "/" .. action .. ".out") or ""
	end
	return outputs
end

--- What one boot showed the user or did to the bundle, as failure lines.
--- @param output string Child output.
--- @param action string
--- @param marker string|nil Line the boot must reach.
--- @return table problems
local function judge(output, action, marker)
	local problems = {}
	for line in output:gmatch("[^\n]+") do
		if line:find("%[ERROR%]") or line:find("%[FATAL%]") then
			problems[#problems + 1] = "logged " .. line:gsub("^%S+ %S+ ", "")
		else
			local kind = line:match("^E2E_([%u_]+) ")
			if kind == "DIALOG" or kind == "EXIT" or kind == "BUNDLE_WRITE" or kind == "BUNDLE_READ_MISSING"
				or kind == "OPEN_MISSING" or kind == "ROSETTA"
				or kind == "TIMER_RAISED" or kind == "TAP_RAISED" or kind == "BOOT_RAISED"
				or kind == "SCENARIO_FAILED" then
				problems[#problems + 1] = line
			end
		end
	end
	if not output:find("E2E_DONE " .. action, 1, true) then
		problems[#problems + 1] = "the " .. action .. " child never finished: " .. output:sub(-400)
	end
	if marker and not output:find(marker, 1, true) then
		problems[#problems + 1] = "the boot never logged « " .. marker .. " »"
	end
	return problems
end

--- What one boot's facts contradict of the facts its scenario expects, as
--- failure lines; the last E2E_FACT line of a key wins.
--- @param output string Child output.
--- @param expected table|nil key -> value.
--- @return table problems
local function judge_facts(output, expected)
	local problems = {}
	local actual = {}
	for key, value in output:gmatch("E2E_FACT ([%w_]+)=([^\n]*)") do actual[key] = value end
	local keys = {}
	for key in pairs(expected or {}) do keys[#keys + 1] = key end
	table.sort(keys)
	for _, key in ipairs(keys) do
		if actual[key] ~= expected[key] then
			problems[#problems + 1] = string.format("fact %s is %s, expected %s", key, tostring(actual[key]),
				expected[key])
		end
	end
	return problems
end

--- The navigation layer the recommended preset deployed: Karabiner
--- manipulators that need the layer, and those that enter it.
--- @param home string
--- @param json table The shared JSON codec.
--- @return integer layer_rows, integer entering_rows
local function navigation_layer(home, json)
	local decoded = json.decode(read(home .. "/.config/karabiner/karabiner.json") or "{}")
	local layer_rows, entering = 0, 0
	local function is_layer(name) return type(name) == "string" and name:find("^ergopti_layer_active") ~= nil end
	local function walk(node, in_manipulator)
		if type(node) ~= "table" then return end
		if type(node.set_variable) == "table" and is_layer(node.set_variable.name) and node.set_variable.value == 1 then
			entering = entering + 1
		end
		if node.type == "variable_if" and is_layer(node.name) and node.value == 1 and in_manipulator then
			layer_rows = layer_rows + 1
		end
		for _, child in pairs(node) do walk(child, in_manipulator or node.from ~= nil) end
	end
	walk(decoded, false)
	return layer_rows, entering
end

--- The keys the shipped recommended layer binds on one OS: its `all` table
--- and that OS's table (_shared/keymap/layers.recommended.toml).
--- @param shared string The _shared folder.
--- @param os_name string "macos" or "linux".
--- @return integer keys
local function recommended_layer_keys(shared, os_name)
	local fh = assert(io.open(shared .. "/keymap/layers.recommended.toml", "rb"), "the shipped layer preset is missing")
	local keys, count, scope = {}, 0, nil
	for line in fh:lines() do
		local header = line:match("^%[layers%.[%w_]+%.([%w_]+)%]")
		if header then
			scope = header
		elseif line:match("^%[") then
			scope = nil
		elseif scope == "all" or scope == os_name then
			local key = line:match('^"([^"]+)"%s*=')
			if key and not keys[key] then
				keys[key] = true
				count = count + 1
			end
		end
	end
	fh:close()
	return count
end

--- The Pythons a child started, as the world recorded them, split between its
--- boot and its action (boot_child records E2E_PHASE between the two).
--- @param output string Child output.
--- @return table boot, table action E2E_SPAWN_ARCH lines of Python executables.
local function started_pythons(output)
	local boot, action = {}, {}
	local current = boot
	for line in output:gmatch("[^\n]+") do
		if line:match("^E2E_PHASE ") then current = action end
		local executable = line:match("^E2E_SPAWN_ARCH (%S+)")
		if executable and executable:match("/python[%d.]*$") then current[#current + 1] = line end
	end
	return boot, action
end

--- Whether a boot told the user that the AI runtime it needs is missing: a
--- notification naming that runtime (a product name, never translated).
--- @param output string Child output.
--- @param runtime string "MLX" or "Ollama".
--- @return boolean told
local function notified_missing_runtime(output, runtime)
	for line in output:gmatch("[^\n]+") do
		if line:match("^E2E_NOTIFY ") and line:find(runtime, 1, true) then return true end
	end
	return false
end

--- Runs every scenario through `check`, on every architecture.
--- @param check table { pass(label), fail(label, expected, actual), skip(label) }
--- @param options table { driver, interpreter }
function M.run(check, options)
	if ON_WINDOWS then
		check.skip("installed-application boot scenarios need a POSIX shell, cp, ls and find")
		return
	end
	local world = dofile(options.driver .. "/tests/e2e/boot/world.lua")
	-- Loaded by path: the scenarios make no assumption on the caller's package.path.
	local json = dofile(options.driver .. "/../_shared/lua/json.lua")
	local repo = options.driver:gsub("/static/ergopti_plus/macos/?$", "")
	local scratch = os.tmpname()
	os.remove(scratch)
	local app_root = scratch .. "/app"
	stage_app(repo, app_root)
	local before = bundle_files(app_root)
	for index, scenario in ipairs(scenarios(repo)) do
		local contexts = {}
		for _, arch in ipairs(world.ARCHITECTURES) do
			local root = scratch .. "/" .. index .. "-" .. arch
			local ctx = {
				root = root, home = root .. "/home", repo = repo, driver = options.driver, app_root = app_root,
				interpreter = options.interpreter, world = world, arch = arch, problems = {},
				machine = scenario.machine,
			}
			run("mkdir -p " .. q(ctx.home) .. " " .. q(root .. "/tmp"))
			if scenario.setup then scenario.setup(ctx) end
			contexts[#contexts + 1] = ctx
		end
		for _, action in ipairs(scenario.steps) do
			local outputs = run_children(contexts, action)
			local marker = action ~= "restore_recommended" and scenario.marker or nil
			for context_index, ctx in ipairs(contexts) do
				local output = outputs[context_index]
				for _, problem in ipairs(judge(output, action, marker)) do
					ctx.problems[#ctx.problems + 1] = action .. ": " .. problem
				end
				for _, problem in ipairs(judge_facts(output, scenario.facts)) do
					ctx.problems[#ctx.problems + 1] = action .. ": " .. problem
				end
				-- hardening-h: the boot starts no Python at all; the helper starts one,
				-- which the ROSETTA judgement above then covers.
				local boot_pythons, action_pythons = started_pythons(output)
				if #boot_pythons > 0 then
					ctx.problems[#ctx.problems + 1] = action .. ": the boot started a Python: " .. boot_pythons[1]
				end
				if action == "python_helper" and #action_pythons == 0 then
					ctx.problems[#ctx.problems + 1] = action .. ": the Python helper started no Python"
				end
				local runtime = action == "boot" and scenario.ai_runtime and scenario.ai_runtime(ctx.arch) or nil
				if runtime and not notified_missing_runtime(output, runtime) then
					ctx.problems[#ctx.problems + 1] = action .. ": the AI is on without " .. runtime
						.. ", and no notification names it"
				end
			end
		end
		-- hardening-b: the bundle a boot leaves is the bundle it found.
		local after = bundle_files(app_root)
		local bundle_problems = {}
		for path in pairs(after) do
			if not before[path] then bundle_problems[#bundle_problems + 1] = "created inside the bundle: " .. path end
		end
		for path in pairs(before) do
			if not after[path] then bundle_problems[#bundle_problems + 1] = "deleted from the bundle: " .. path end
		end
		before = after
		for _, ctx in ipairs(contexts) do
			-- The boots of one scenario run at once: either may have written it
			for _, problem in ipairs(bundle_problems) do ctx.problems[#ctx.problems + 1] = problem end
			local label = "hardening-a/b boot (" .. ctx.arch .. "): " .. scenario.name
			if #ctx.problems == 0 then
				check.pass(label)
			else
				check.fail(label, "no ERROR, dialog or bundle write, any missing AI runtime named, and its facts",
					table.concat(ctx.problems, "\n        ", 1, math.min(#ctx.problems, 12)))
			end
			if scenario.recommended then
				-- Every key the preset binds on macOS has at least one manipulator gated
				-- on the layer; the layer was empty before db71c39bf.
				local layer_rows, entering = navigation_layer(ctx.home, json)
				local preset_keys = recommended_layer_keys(repo .. "/static/ergopti_plus/_shared", "macos")
				if layer_rows >= preset_keys and preset_keys > 0 and entering > 0 then
					check.pass(string.format("hardening-e-presets (%s): the recommended navigation layer is deployed "
						.. "(%d rows for %d preset keys) and a key enters it (%d)", ctx.arch, layer_rows, preset_keys,
						entering))
				else
					check.fail("hardening-e-presets (" .. ctx.arch .. "): the recommended navigation layer is "
						.. "deployed and entered", string.format("at least %d rows and an entering key", preset_keys),
						string.format("%d rows, %d entering", layer_rows, entering))
				end
			end
			run("rm -rf " .. q(ctx.root))
		end
	end
	run("rm -rf " .. q(scratch))
end

return M
