--- _shared/lua/identifiers.lua
--- AUTO-GENERATED from _shared/data/identifiers.json.
--- DO NOT EDIT BY HAND — run `npm run codegen:identifiers` to refresh.

--- ==============================================================================
--- DATA: Application Identifiers and External Hosts
--- DESCRIPTION:
--- The application file and bundle names, the bundle ids, the service labels and
--- the external hosts shared by the Lua drivers. Hosts are bare names: build a
--- URL as "https://" .. hosts.github .. "/...".
--- ==============================================================================

return {
	app = {
		name = "ErgoptiPlus",
		ahk = "ErgoptiPlus.ahk",
		exe = "ErgoptiPlus.exe",
		bundle = "ErgoptiPlus.app",
	},
	bundle_ids = {
		launcher = "com.ergoptiplus.app",
		hammerspoon = "com.ergoptiplus.app.hammerspoon",
	},
	service_labels = {
		macos_core = "com.ergoptiplus.runtime.core",
		macos_virtual_hid = "com.ergoptiplus.runtime.vhid",
	},
	hosts = {
		github = "github.com",
		github_api = "api.github.com",
		huggingface = "huggingface.co",
		ollama = "ollama.com",
		ollama_registry = "registry.ollama.ai",
	},
}
