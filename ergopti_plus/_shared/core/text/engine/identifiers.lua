--- _shared/core/text/engine/identifiers.lua
--- AUTO-GENERATED from _shared/core/text/data/identifiers.json.
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
		display_name = "Ergopti+",
	},
	bundle_ids = {
		launcher = "com.ergoptiplus.app",
		hammerspoon = "com.ergoptiplus.app.hammerspoon",
	},
	signing_ids = {
		runtime_installer = "com.ergoptiplus.app.runtime-installer",
		installed_physical_source = "com.ergoptiplus.app.installed-physical-source",
		remap_core = "com.ergoptiplus.remap.core",
		remap_console = "com.ergoptiplus.remap.console",
		remap_cli = "com.ergoptiplus.remap.cli",
	},
	service_labels = {
		macos_core = "com.ergoptiplus.runtime.core",
		macos_remap_guardian = "com.ergoptiplus.remap-guardian",
		macos_virtual_hid = "com.ergoptiplus.runtime.vhid",
	},
	hosts = {
		github = "github.com",
		github_api = "api.github.com",
		huggingface = "huggingface.co",
		ollama = "ollama.com",
		ollama_registry = "registry.ollama.ai",
	},
	dev_source = {
		plist_key = "ErgoptiDevSourceRoot",
		environment = "ERGOPTI_DEV_SOURCE_ROOT",
	},
	field_report = {
		branch_prefix = "field/",
		folder = "docs/field-reports",
		base_config_key = "ergoptiFieldBase",
		environment = "ERGOPTI_FIELD_RUN_ROOT",
	},
	bytecode_package = {
		manifest = "manifest",
		bundle = "bundle",
		format = "ergopti-bytecode-1",
		end_marker = "end",
		compiler = "linux/install/compile_bytecode.lua",
	},
	macos_notifications = {
		launcher_quit_request = "com.ergoptiplus.app.quit-request",
	},
	linux_stage = {
		infix = "ergopti",
	},
	linux_launchers = {
		package = "/usr/bin/ergopti",
		flatpak = "/app/bin/ergopti",
	},
	linux_desktop = {
		gnome_extension_uuid = "focus@ergopti.fr",
		gnome_switch_path = "/org/ergopti/InputSource",
		gnome_switch_interface = "org.ergopti.InputSource1",
		gnome_extension_missing = "gnome_extension_missing",
		compose_state_file = ".ergopti_plus_compose_input_method",
		xkb_user_root_env = "ERGOPTI_XKB_USER_ROOT",
		wayland_toplevel_list = "ext_foreign_toplevel_list_v1",
		wayland_toplevel_handle = "ext_foreign_toplevel_handle_v1",
		dialog_host_guard_env = "ERGOPTI_DIALOG_HOST_GUARD",
		dialog_host_guard_case_env = "ERGOPTI_DIALOG_HOST_GUARD_CASE",
		dbusmenu_interface = "com.canonical.dbusmenu",
		notification_persistence = "persistence",
		uinput_udev_rule_file = "99-ergopti-uinput.rules",
	},
	linux_host_environment = {
		names_env = "ERGOPTI_HOST_ENV_NAMES",
		value_prefix = "ERGOPTI_HOST_ENV_SET_",
		driver_root_env = "ERGOPTI_HOST_ENV_DRIVER_ROOT",
	},
	linux_input = {
		virtual_keyboard = "Ergopti Virtual Keyboard",
		virtual_pointer = "Ergopti Virtual Pointer",
	},
	locales = {
		system_fallback = "en",
	},
}
