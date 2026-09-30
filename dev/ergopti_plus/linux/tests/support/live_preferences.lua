--- tests/support/live_preferences.lua

--- Explicit configuration choices for live hardware and service fixtures.
local M = {}
local Paths = require("infra.config_paths")
local Shell = require("adapters.shell_runner")

--- Creates the canonical preference folder before its conditional writers run.
--- @return string directory The real configuration owner's resolved directory.
function M.ensure_directory()
	local directory = Paths.config()
	assert(Shell.run("mkdir -p " .. Shell.quote(directory)), "live preference directory must exist")
	return directory
end

--- Selects only the catalogue, remapping and AI choices the daemon probe uses.
--- The caller supplies a private HOME before loading any configuration owner.
function M.daemon()
	local directory = M.ensure_directory()
	local Files = require("adapters.file_system")
	local _, status = Files.read_with_status(Paths.config("config.toml"))
	assert(status == "absent", "the live daemon fixture requires a fresh configuration")
	-- Any config.toml is a configured driver, so the setup wizard stays closed.
	local config = ""
	-- The AI probe's rewrite runs from a chord, as a user would bind it. Chords
	-- only fire while the shortcuts feature is on, which it is not by default:
	-- without it the daemon holds the chord back as it does during a pause.
	if os.getenv("ERGOPTI_LIVE_LLM_PORT") then
		config = config .. "\n[shortcuts]\nenabled = true\n"
			.. "\n[shortcuts.keyboard]\nsuper_space = \"llm_predict_rewrite\"\n"
	end
	assert(Files.write(Paths.config("config.toml"), config), "live configuration must be created")
	local Hotstrings = require("modules.hotstrings.hotstrings_config")
	Hotstrings.init(require("modules.hotstrings.engine").new(), "tests/e2e/fixtures/daemon_keys.toml")
	Hotstrings.load_all()
	assert(Hotstrings.set_all_sections("daemon_keys", true), "the live catalogue must be explicitly selected")
	assert(Files.write(Paths.config("tap_hold.toml"), require("tests.support.tap_hold_fixture").with_preset()),
		"the live tap-hold fixture must explicitly import its preset")
	local preset = require("keymap.layer_editor").read_shipped(require("infra.paths").shared("keymap/layers.recommended.toml"))
	assert(Files.write(directory .. "/layers.toml", preset), "the live navigation fixture must explicitly import its preset")
	if os.getenv("ERGOPTI_LIVE_LLM_PORT") then
		assert(require("infra.llm_preferences").set_many({
			["llm.enabled"] = true, ["llm.models.selected"] = "api", ["llm.profiles.num_predictions"] = 1,
			["llm.navigation.val_modifiers"] = {},
		}), "the live API choices must reach canonical preferences")
	end
end

return M
