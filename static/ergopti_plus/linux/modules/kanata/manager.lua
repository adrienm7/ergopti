--- modules/kanata/manager.lua

--- ==============================================================================
--- MODULE: Kanata Manager (Linux)
--- DESCRIPTION:
--- Manages the kanata key-remapping daemon lifecycle on Linux. Reads the tap-hold
--- configuration (from defaults.toml or a user TOML file), generates the kanata
--- defalias block via the shared kanata_generator.lua, merges it with the static
--- kanata.kbd template, writes the result to ~/.config/kanata/ergopti.kbd, and
--- manages the kanata process (start / stop / restart).
---
--- FEATURES & RATIONALE:
--- 1. TOML-driven generation: the defalias block is NEVER hand-maintained —
---    it is generated from the canonical _shared/tap_hold/defaults.toml using
---    the shared kanata_generator. The user can override with their own
---    ~/.config/ergopti/tap_hold.toml.
--- 2. Template merging: the static kanata.kbd (defsrc, deflayer, Ergo-QWERTY
---    mappings) is read once and the generated defalias replaces the hand-written
---    one. Comments above the (defalias) block are preserved as markers.
--- 3. Process lifecycle: start() launches kanata as a background subprocess;
---    stop() sends SIGTERM; restart() = stop + generate + start.
--- 4. systemd integration: the install script also creates a kanata.service
---    user unit so kanata starts automatically with the graphical session.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

-- Shared TOML decoder — this module owns no bespoke parser.
local TomlCodec = require("toml_codec")

local LOG = "modules.kanata.manager"


-- =========================================
-- =========================================
-- ======= 1/ State ========================
-- =========================================
-- =========================================

local _kanata_pid    = nil    -- PID of the running kanata process.
local _config_dir    = nil    -- ~/.config/kanata
local _kbd_path      = nil    -- ~/.config/kanata/ergopti.kbd
local _template_path = nil    -- Path to the static kanata.kbd template.
local _shared_dir    = nil    -- Path to the _shared tree (sibling of the driver).
local _user_toml     = nil    -- Path to the user's tap_hold.toml override.


-- =========================================
-- =========================================
-- ======= 2/ Path Resolution ==============
-- =========================================
-- =========================================

--- Resolves and caches the working paths. Called once on first use.
local function _resolve_paths()
	if _config_dir then return end

	local home = require("infra.config_paths").home()
	_config_dir = home .. "/.config/kanata"

	-- Generated kanata config destination.
	_kbd_path = _config_dir .. "/ergopti.kbd"

	-- User tap-hold override (takes precedence over defaults.toml).
	_user_toml = home .. "/.config/ergopti/tap_hold.toml"

	-- Static kanata.kbd template: resolve relative to the driver root.
	local src = debug.getinfo(1, "S").source:gsub("^@", "")
	local driver_root = src:match("^(.*)[/\\]modules[/\\]kanata[/\\]manager%.lua$") or "."
	driver_root = driver_root:gsub("\\", "/")
	-- The template sits beside this manager, mirroring how macOS keeps its
	-- Karabiner assets in modules/karabiner/data/. kanata is Linux-only, so
	-- nothing about it belongs outside this driver.
	_template_path = driver_root .. "/modules/kanata/data/kanata.kbd"

	-- Through the resolver: _shared is a sibling of the driver folder, and
	-- letting each module rediscover that is how one of them gets it wrong.
	local ok_paths, Paths = pcall(require, "infra.paths")
	_shared_dir = ok_paths and Paths.shared_root() or nil

	-- Verify the template exists (fail-loud: kanata cannot work without it).
	local fh = io.open(_template_path, "r")
	if not fh then
		Logger.error(LOG, "Kanata template not found: %s", _template_path)
		_template_path = nil
	else
		fh:close()
	end
end


-- =========================================
-- =========================================
-- ======= 3/ TOML Config Loading ==========
-- =========================================
-- =========================================

--- Reads a TOML file and extracts the [tap_hold.keys.*] sections into the
--- keys_config shape expected by kanata_generator.generate(). All TOML parsing
--- is delegated to the shared toml_codec — this module owns no bespoke parser.
--- @param path string Absolute path to the TOML file.
--- @return table|nil keys_config, or nil when the file is absent, empty, or has no keys.
local function _load_keys_from_toml(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()

	-- decode returns nil on a spec violation; treat that as "no usable config"
	-- so the caller falls through to the next source rather than crashing.
	local parsed = TomlCodec.decode(content)
	if type(parsed) ~= "table"
		or type(parsed.tap_hold) ~= "table"
		or type(parsed.tap_hold.keys) ~= "table" then
		Logger.error(LOG, "tap_hold.toml at '%s' is malformed — falling back to shared defaults.", path)
		return nil
	end

	local keys = {}
	for key_id, kc in pairs(parsed.tap_hold.keys) do
		if type(kc) == "table" then
			keys[key_id] = {
				time_activation_seconds = kc.time_activation_seconds,
				tap_action              = kc.tap_action,
				hold_modifier           = kc.hold_modifier,
				hold_layer              = kc.hold_layer,
			}
		end
	end

	return next(keys) and keys or nil
end

--- Loads tap-hold key config, preferring the user's TOML override over the
--- shared defaults.toml. Returns keys_config in the shape expected by
--- kanata_generator.generate().
--- @param user_toml_path string|nil Explicit user tap_hold.toml path (test seam);
---   nil resolves the real ~/.config/ergopti/tap_hold.toml.
--- @return table keys_config
local function _load_tap_hold_config(user_toml_path)
	_resolve_paths()

	-- Resolved from the driver root, not by rewriting the template path. The
	-- previous form substituted "/kanata/kanata.kbd" inside _template_path, so
	-- moving the template one directory deeper silently stopped matching and the
	-- generator was handed an empty key set — a full config with an empty
	-- (defalias) block, which is far worse than a loud failure.
	local defaults_path = _shared_dir and (_shared_dir .. "/tap_hold/defaults.toml") or nil

	-- Through the resolver rather than a bare relative path: the old fallback
	-- depended on the process's current directory, so a driver started from
	-- anywhere but one exact folder read no defaults and silently used none.
	if not defaults_path then
		local ok_paths, Paths = pcall(require, "infra.paths")
		defaults_path = ok_paths and Paths.shared("tap_hold/defaults.toml") or nil
	end

	-- Load order: user override → shared defaults. The user's tap_hold.toml, when
	-- present, fully replaces the defaults (no per-key merge), mirroring the other
	-- drivers' "generated per-driver file is the complete config" semantic.
	local keys = nil

	local user_toml = user_toml_path or _user_toml
	if user_toml then
		local fh = io.open(user_toml, "r")
		if fh then
			fh:close()
			Logger.info(LOG, "Loading tap-hold config from user file: %s", user_toml)
			keys = _load_keys_from_toml(user_toml)
			-- The user file exists but produced no usable keys (malformed, or valid
			-- TOML with no [tap_hold.keys.*] sections). Warn loudly before silently
			-- falling back to the shared defaults, so a broken user override is
			-- visible rather than masquerading as a deliberate "use defaults".
			if not keys then
				Logger.warn(LOG, "User tap_hold.toml at '%s' is present but yielded no usable keys — ignoring it and falling back to shared defaults.", user_toml)
			end
		end
	end

	if not keys and defaults_path then
		local fh = io.open(defaults_path, "r")
		if fh then
			fh:close()
			Logger.info(LOG, "Loading tap-hold config from defaults: %s", defaults_path)
			keys = _load_keys_from_toml(defaults_path)
		end
	end

	if not keys then
		Logger.warn(LOG, "No tap-hold config found — kanata will use empty defalias.")
		keys = {}
	end

	return keys
end

--- Test accessor: runs the tap-hold config loader in isolation, bypassing the
--- template gate in generate_kbd(), so the suite can exercise the user-file
--- fallback/fail-fast logging without a resolvable kanata.kbd template. The path
--- argument points the loader at a temp fixture (test seam), avoiding a $HOME
--- override or cross-platform nested-dir creation.
--- @param user_toml_path string|nil Absolute path to a user tap_hold.toml fixture.
--- @return table keys_config
function M._load_tap_hold_config_for_test(user_toml_path)
	return _load_tap_hold_config(user_toml_path)
end


-- =========================================
-- =========================================
-- ======= 4/ .kbd Generation ==============
-- =========================================
-- =========================================

--- Reads the static kanata.kbd template and returns its content with the
--- marker-commented section split so we can replace the defalias block.
--- @return string|nil template_prefix, string|nil template_suffix
local function _read_template()
	_resolve_paths()
	if not _template_path then return nil, nil end

	local fh = io.open(_template_path, "r")
	if not fh then return nil, nil end
	local content = fh:read("*a")
	fh:close()

	-- Split at the last (defalias block — everything before it is the template
	-- prefix (defcfg, defsrc, deflayer, Ergo-QWERTY mappings); the last
	-- (defalias block is the tap-hold-press section we replace.
	local last_defalias_start = nil
	local pos = 1
	while true do
		local s, e = content:find("\n%(defalias", pos)
		if not s then break end
		last_defalias_start = s + 1  -- position after the newline
		pos = e
	end

	if not last_defalias_start then
		Logger.error(LOG, "Template has no (defalias) block marker — cannot replace.")
		return content, ""
	end

	local prefix = content:sub(1, last_defalias_start - 1)
	-- suffix starts from the closing ")" of the defalias block.
	-- Find the matching close-paren.
	local depth = 0
	local suffix_start = nil
	for i = last_defalias_start, #content do
		local c = content:sub(i, i)
		if c == "(" then depth = depth + 1
		elseif c == ")" then
			depth = depth - 1
			if depth <= 0 then
				suffix_start = i + 1
				break
			end
		end
	end

	local suffix = suffix_start and content:sub(suffix_start) or "\n"
	return prefix, suffix
end

--- Generates the complete kanata.kbd by merging the static template with the
--- generated defalias block.
--- @return string|nil Full .kbd content, or nil on failure.
function M.generate_kbd()
	_resolve_paths()

	local prefix, suffix = _read_template()
	if not prefix then return nil end

	-- Load tap-hold config.
	local keys_config = _load_tap_hold_config()

	-- Read the one-shot shift timeout from the canonical timings registry. No
	-- hardcoded fallback: the value lives once in the shared registry, so a
	-- missing registry or key is a broken install to surface loudly, not to mask
	-- with a duplicated literal that would silently override the canonical value.
	local ok_timings, Timings = pcall(require, "infra.timings")
	if not ok_timings or type(Timings) ~= "table" or type(Timings.ms) ~= "function" then
		Logger.error(LOG, "Timings registry unavailable — cannot generate kanata config without the canonical one-shot timeout.")
		return nil
	end
	local one_shot_ms = Timings.ms("tap_hold", "one_shot_shift_timeout_ms")
	if not one_shot_ms or one_shot_ms <= 0 then
		Logger.error(LOG, "'tap_hold.one_shot_shift_timeout_ms' missing from the timings registry — cannot generate kanata config.")
		return nil
	end

	-- Generate the defalias block.
	local ok_gen, gen = pcall(require, "tap_hold.kanata_generator")
	if not ok_gen or not gen then
		Logger.error(LOG, "kanata_generator failed to load — cannot generate defalias.")
		return nil
	end

	local defalias = gen.generate(keys_config, {
		one_shot_shift_timeout_ms = one_shot_ms,
	})

	-- Assemble.
	local kbd = prefix .. "\n" .. defalias .. "\n" .. (suffix or "")
	return kbd
end

--- Writes the generated .kbd to ~/.config/kanata/ergopti.kbd.
--- @return boolean True on success.
function M.write_kbd()
	_resolve_paths()

	Logger.start(LOG, "Writing kanata config…")

	local kbd = M.generate_kbd()
	if not kbd then
		Logger.error(LOG, "write_kbd(): generation failed.")
		return false
	end

	-- Ensure config directory exists.
	os.execute(string.format("mkdir -p '%s' 2>/dev/null",
		_config_dir:gsub("'", "'\\''")))

	local fh = io.open(_kbd_path, "w")
	if not fh then
		Logger.error(LOG, "Cannot write .kbd to %s", _kbd_path)
		return false
	end
	fh:write(kbd)
	fh:close()

	Logger.success(LOG, "Kanata config written to %s (%d bytes).", _kbd_path, #kbd)
	return true
end

--- Returns the path to the generated .kbd file.
--- @return string|nil
function M.get_kbd_path()
	_resolve_paths()
	return _kbd_path
end


-- =========================================
-- =========================================
-- ======= 5/ Process Lifecycle ============
-- =========================================
-- =========================================

--- Starts the kanata daemon. Idempotent — no-op if already running.
--- @return boolean True if kanata is running after this call.
function M.start()
	_resolve_paths()

	if M.is_running() then
		Logger.debug(LOG, "start(): kanata already running (pid=%d).", _kanata_pid)
		return true
	end

	Logger.start(LOG, "Starting kanata daemon…")

	-- Check that kanata binary exists.
	local ok_bin = os.execute("which kanata >/dev/null 2>&1")
	if ok_bin ~= true and ok_bin ~= 0 then
		Logger.warn(LOG, "start(): kanata binary not found — install with: bash install.sh")
		return false
	end

	-- Ensure the .kbd exists (generate if missing).
	local fh = io.open(_kbd_path, "r")
	if not fh then
		Logger.info(LOG, "No .kbd found — generating before start…")
		if not M.write_kbd() then return false end
	else
		fh:close()
	end

	-- Determine the device path. kanata --auto-detect works on most systems.
	local cmd = string.format(
		"kanata --quiet --cfg '%s' 2>&1 & echo $!",
		_kbd_path:gsub("'", "'\\''")
	)

	local pipe = io.popen(cmd, "r")
	if not pipe then
		Logger.error(LOG, "start(): io.popen failed.")
		return false
	end

	local pid_str = pipe:read("*l")
	pipe:close()
	_kanata_pid = tonumber(pid_str)

	if not _kanata_pid then
		Logger.error(LOG, "start(): could not read kanata PID.")
		return false
	end

	Logger.success(LOG, "Kanata started (pid=%d, cfg=%s).", _kanata_pid, _kbd_path)
	return true
end

--- Stops the kanata daemon. Safe to call when not running.
function M.stop()
	if not M.is_running() then return end

	os.execute(string.format("kill %d 2>/dev/null", _kanata_pid))
	Logger.info(LOG, "Kanata stopped (pid=%d).", _kanata_pid)
	_kanata_pid = nil
end

--- Restarts kanata: regenerates the .kbd, stops any running instance, starts fresh.
--- @return boolean True if kanata is running after this call.
function M.restart()
	Logger.info(LOG, "Restarting kanata…")
	M.stop()
	if not M.write_kbd() then return false end
	return M.start()
end

--- Returns true when kanata is running.
--- @return boolean
function M.is_running()
	if not _kanata_pid then return false end
	-- Check the PID is still alive (send signal 0).
	local ok = os.execute(string.format("kill -0 %d 2>/dev/null", _kanata_pid))
	return (ok == true or ok == 0)
end

return M
