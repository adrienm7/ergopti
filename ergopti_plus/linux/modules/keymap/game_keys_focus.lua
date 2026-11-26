--- modules/keymap/game_keys_focus.lua

--- ==============================================================================
--- MODULE: Game Keys Focus (Linux)
--- DESCRIPTION:
--- « Touches de jeu » at their physical place in a game while the layout
--- emulation types Ergopti (maintainer decision of 2026-11-26). Under the
--- emulation one key code carries both what a game binds and what a chat
--- field types, so a key cannot keep its place and type Ergopti at once. With
--- the Ergopti XKB layout installed in the session, a game whose own choice is
--- "physical" gets that layout while it has the focus, and the emulation lets
--- its keys through; the previous layout comes back when the game loses the
--- focus. The route is the shared one (_shared/layouts/engine/emulation/game_keys.lua).
---
--- FEATURES & RATIONALE:
--- 1. Decided on a focus change only (the focus callback of the daemon), never
---    on the key path: the switch is the input source switcher's asynchronous
---    command, and the emulation reads one boolean per press.
--- 2. Every collaborator is injected (M.init), so tests drive the switches
---    without a desktop.
--- ==============================================================================

local GameKeys = require("layouts.engine.emulation.game_keys")
local Logger = require("core.logger.engine.shim")

local M = {}

local LOG = "keymap.game_keys_focus"

local REQUIRED_DEPS = { "settings", "emulation", "switcher", "set_game" }

-- Collaborators (M.init) and the focus state.
local _deps = nil
local _app = nil
local _passing = false
local _previous = nil
-- Whether the session's layouts were read once: the switcher lists them only
-- after a refresh, which the menu may not have asked for yet.
local _listed = false

--- Takes the collaborators. Called once, before the first focus change.
--- @param deps table { settings = fn() -> GameKeys.resolve result, emulation = fn() ->
---   { active, ergopti } (the layout emulation's status), switcher = fn() -> an
---   input_source_switch switcher, nil when the desktop has none, set_game = fn(boolean) the
---   tap-hold owner told whether a game has the focus }
function M.init(deps)
	if _deps ~= nil then error("game_keys_focus: already initialized", 2) end
	if type(deps) ~= "table" then error("game_keys_focus.init needs its collaborators", 2) end
	for _, name in ipairs(REQUIRED_DEPS) do
		if type(deps[name]) ~= "function" then error("game_keys_focus.init needs " .. name, 2) end
	end
	_deps = deps
	Logger.info(LOG, "Game keys focus initialized.")
end

--- The session layout of the installed Ergopti XKB layout, nil when none is listed.
--- @param switcher table|nil
--- @return table|nil choice { id, label, active }
function M.installed_choice(switcher)
	if type(switcher) ~= "table" or type(switcher.choices) ~= "function" then return nil end
	for _, choice in ipairs(switcher.choices()) do
		if type(choice.id) == "string" and choice.id:lower():find("ergopti", 1, true) then return choice end
	end
	return nil
end

--- The capabilities a route reads for an application.
--- @param app string|nil
--- @param settings table|nil The game-key settings already read; read now when nil.
--- @return table caps { installed_layout, game }
--- @return string mode The Ergopti mode: emulation, installed or system.
--- @return table settings The game-key settings they were read with.
function M.caps(app, settings)
	if _deps == nil then error("game_keys_focus.caps needs M.init first", 2) end
	local status = _deps.emulation()
	local switcher = _deps.switcher()
	local installed = M.installed_choice(switcher)
	local mode = GameKeys.MODE_SYSTEM
	if type(status) == "table" and status.active == true then
		mode = GameKeys.MODE_EMULATION
	elseif installed ~= nil and installed.active == true then
		mode = GameKeys.MODE_INSTALLED
	end
	settings = settings or _deps.settings()
	return { installed_layout = installed ~= nil and type(status) == "table" and status.ergopti == true,
		game = GameKeys.is_game(settings, "linux", app) }, mode, settings
end

--- The route of an application in force now.
--- @param app string|nil
--- @return table route GameKeys.route's result.
function M.route(app)
	local caps, mode, settings = M.caps(app)
	return GameKeys.route("linux", mode, (GameKeys.choice_for(settings, "linux", app)), caps)
end

--- Follows a focus change: switches a « physical » game to the installed
--- Ergopti layout, and back when it loses the focus.
--- @param app string|nil The focused application's WM class or app_id.
function M.on_focus(app)
	if _deps == nil then error("game_keys_focus.on_focus needs M.init first", 2) end
	_app = app
	local listing = _deps.switcher()
	if listing ~= nil and not _listed then
		_listed = true
		-- Decided once the layouts are listed, for the application still focused.
		listing.refresh(function() if _app == app then M.on_focus(app) end end)
		return
	end
	local called, route = pcall(M.route, app)
	-- A game skips the tap-hold delays, whatever its keys' place.
	local game_called, game = pcall(function() return GameKeys.is_game(_deps.settings(), "linux", app) end)
	if game_called then
		_deps.set_game(game)
	else
		Logger.error(LOG, "Whether %s is a game could not be read: %s.", tostring(app), tostring(game))
	end
	if not called then
		Logger.error(LOG, "The game keys of %s could not be decided: %s.", tostring(app), tostring(route))
		route = nil
	end
	local passing = route ~= nil and route.strategy == GameKeys.SWITCH_TO_INSTALLED
	if passing == _passing then return end
	local switcher = _deps.switcher()
	if passing then
		local installed = M.installed_choice(switcher)
		if installed == nil then return end
		_previous = nil
		for _, choice in ipairs(switcher.choices()) do
			if choice.active == true then _previous = choice.id end
		end
		_passing = true
		Logger.start(LOG, "Game keys at their physical place in %s: switching to the Ergopti layout…", tostring(app))
		switcher.select(installed.id, function(ok, detail)
			if ok then
				Logger.success(LOG, "The Ergopti layout types in %s.", tostring(app))
			else
				-- The emulation types again: the keys follow the letters there.
				_passing = false
				Logger.error(LOG, "The Ergopti layout could not be selected for %s: %s.", tostring(app), tostring(detail))
			end
		end)
		return
	end
	_passing = false
	local previous = _previous
	_previous = nil
	if previous == nil or type(switcher) ~= "table" then return end
	Logger.start(LOG, "Leaving a game: switching back to '%s'…", previous)
	switcher.select(previous, function(ok, detail)
		if ok then
			Logger.success(LOG, "Layout '%s' is back.", previous)
		else
			Logger.error(LOG, "Layout '%s' could not be given back after a game: %s.", previous, tostring(detail))
		end
	end)
end

--- M.on_focus once the owner is started: the daemon's focus callback runs in
--- replays and sessions that start no focus owner, which have no game to follow.
--- @param app string|nil
function M.follow_focus(app)
	if _deps ~= nil then M.on_focus(app) end
end

--- Whether M.init ran: a daemon without focus reports has no game to follow.
--- @return boolean
function M.is_initialised() return _deps ~= nil end

--- Whether the emulation leaves the focused application's keys to the
--- installed Ergopti layout.
--- @return boolean
function M.passes_through()
	return _passing
end

--- The application last focused, for the menu's per-application rows.
--- @return string|nil
function M.current_app()
	return _app
end

--- Forgets the collaborators and the focus state (test seam).
function M._reset_for_test()
	_deps, _app, _passing, _previous, _listed = nil, nil, false, nil, false
end

--- The daemon's collaborators.
--- @return table deps
function M.production_deps()
	local Manifest = require("menu.engine.manifest_reader")
	return {
		settings = function()
			local config = require("infra.layout_emulation_preferences").snapshot()
			return GameKeys.resolve(config, Manifest.default_for, function(segments, detail)
				require("settings.engine.migration.outdated").report(segments, detail, Logger)
			end)
		end,
		emulation = function() return require("modules.keymap.layout_emulation").status() end,
		switcher = function()
			local Pause = require("modules.keymap.pause_layout_switch")
			return Pause.is_initialised() and Pause.switcher() or nil
		end,
		set_game = function(game)
			local TapHolds = require("platform.remap.tap_hold_manager")
			if TapHolds.is_initialized() and TapHolds.set_game(game) ~= true then
				Logger.error(LOG, "The tap-holds could not follow the game focus.")
			end
		end,
	}
end

--- Initializes the module with the daemon's collaborators.
function M.start()
	M.init(M.production_deps())
end

return M
