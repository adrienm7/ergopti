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

local SCENARIOS = {
	{ name = "a fresh install opens the first-run wizard", steps = { "boot" }, marker = WIZARD_MARKER },
	{ name = "the neutral defaults boot", setup = neutral_defaults, steps = { "boot" }, marker = BOOTED_MARKER },
	-- Booted over the recommended preset, it then opens every window and file the
	-- action catalogue can open, which the recommended shortcuts admit.
	{ name = "the recommended preset imported from the menu boots and opens its windows", setup = neutral_defaults,
		steps = { "restore_recommended", "open_windows" }, marker = BOOTED_MARKER, recommended = true },
	{ name = "an unstamped v2 config.toml with legacy settings and a tilde paths.toml boots",
		setup = older_release("shipped_space_wrap_removed_on_macos", legacy_settings_and_tilde_paths),
		steps = { "boot" }, marker = BOOTED_MARKER },
	{ name = "a v3 config.toml with the AI on and its retired trigger shortcut boots",
		setup = older_release("shipped_trigger_shortcut_removed_on_macos"), steps = { "boot" }, marker = BOOTED_MARKER },
	{ name = "a v5 config.toml with gestures on and duplicate switch actions boots",
		setup = older_release("shipped_duplicate_switch_actions_merged_on_macos"), steps = { "boot" },
		marker = BOOTED_MARKER },
}





-- ===================================
-- ===================================
-- ======= 3/ Running and judging ====
-- ===================================
-- ===================================

--- Runs one child and returns its complete output.
--- @param ctx table Scenario context.
--- @param action string boot_child action.
--- @return string output
local function run_child(ctx, action)
	local settings_file = ctx.root .. "/settings.lua"
	local fh = assert(io.open(settings_file, "w"))
	fh:write("return {\n")
	for key, value in pairs(ctx.settings or {}) do
		fh:write(string.format("\t[%q] = %s,\n", key, type(value) == "string" and string.format("%q", value)
			or tostring(value)))
	end
	fh:write("}\n")
	fh:close()
	local command = table.concat({
		"cd " .. q(ctx.root) .. " &&",
		"HOME=" .. q(ctx.home), "TMPDIR=" .. q(ctx.root .. "/tmp"),
		"XDG_CONFIG_HOME=", "XDG_STATE_HOME=", "XDG_DATA_HOME=", "XDG_CACHE_HOME=",
		q(ctx.interpreter), q(ctx.driver .. "/tests/e2e/boot/boot_child.lua"),
		q(ctx.driver), q(ctx.app_root), q(ctx.root .. "/machine"), q(ctx.home), q(action), q(settings_file), "2>&1",
	}, " ")
	local pipe = io.popen(command, "r")
	local output = pipe:read("*a")
	pipe:close()
	return output
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
				or kind == "OPEN_MISSING"
				or kind == "TIMER_RAISED" or kind == "BOOT_RAISED" or kind == "SCENARIO_FAILED" then
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

--- The navigation layer the recommended preset deployed: Karabiner
--- manipulators that need the layer, and those that enter it.
--- @param home string
--- @return integer layer_rows, integer entering_rows
local function navigation_layer(home)
	local decoded = require("json").decode(read(home .. "/.config/karabiner/karabiner.json") or "{}")
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

--- Runs every scenario through `check`.
--- @param check table { pass(label), fail(label, expected, actual), skip(label) }
--- @param options table { driver, interpreter }
function M.run(check, options)
	if ON_WINDOWS then
		check.skip("installed-application boot scenarios need a POSIX shell, cp, ls and find")
		return
	end
	local world = dofile(options.driver .. "/tests/e2e/boot/world.lua")
	local repo = options.driver:gsub("/static/ergopti_plus/macos/?$", "")
	local scratch = os.tmpname()
	os.remove(scratch)
	local app_root = scratch .. "/app"
	stage_app(repo, app_root)
	local before = bundle_files(app_root)
	for index, scenario in ipairs(SCENARIOS) do
		local root = scratch .. "/" .. index
		local ctx = {
			root = root, home = root .. "/home", repo = repo, driver = options.driver, app_root = app_root,
			interpreter = options.interpreter, world = world,
		}
		run("mkdir -p " .. q(ctx.home) .. " " .. q(root .. "/tmp"))
		if scenario.setup then scenario.setup(ctx) end
		local problems = {}
		local last_output = ""
		for _, action in ipairs(scenario.steps) do
			last_output = run_child(ctx, action)
			local marker = action ~= "restore_recommended" and scenario.marker or nil
			for _, problem in ipairs(judge(last_output, action, marker)) do
				problems[#problems + 1] = action .. ": " .. problem
			end
		end
		-- hardening-b: the bundle a boot leaves is the bundle it found.
		local after = bundle_files(app_root)
		for path in pairs(after) do
			if not before[path] then problems[#problems + 1] = "created inside the bundle: " .. path end
		end
		for path in pairs(before) do
			if not after[path] then problems[#problems + 1] = "deleted from the bundle: " .. path end
		end
		before = after
		if #problems == 0 then
			check.pass("hardening-a/b boot: " .. scenario.name)
		else
			check.fail("hardening-a/b boot: " .. scenario.name, "no ERROR, dialog or bundle write",
				table.concat(problems, "\n        ", 1, math.min(#problems, 12)))
		end
		if scenario.recommended then
			local layer_rows, entering = navigation_layer(ctx.home)
			if layer_rows > 0 and entering > 0 then
				check.pass(string.format("hardening-e-presets: the recommended navigation layer is deployed "
					.. "(%d rows) and a key enters it (%d)", layer_rows, entering))
			else
				check.fail("hardening-e-presets: the recommended navigation layer is deployed and entered",
					"rows > 0 and an entering key", string.format("%d rows, %d entering", layer_rows, entering))
			end
		end
		run("rm -rf " .. q(root))
	end
	run("rm -rf " .. q(scratch))
end

return M
