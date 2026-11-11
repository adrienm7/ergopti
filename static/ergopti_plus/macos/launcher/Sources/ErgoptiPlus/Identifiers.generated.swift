// AUTO-GENERATED from _shared/data/identifiers.json.
// DO NOT EDIT BY HAND — run `npm run codegen:identifiers` to refresh.

/// Application names, bundle ids, service labels and external hosts. Hosts are
/// bare names: build a URL as "https://\(Identifiers.Hosts.github)/...".
enum Identifiers {
	enum App {
		static let name = "ErgoptiPlus"
		static let ahk = "ErgoptiPlus.ahk"
		static let exe = "ErgoptiPlus.exe"
		static let bundle = "ErgoptiPlus.app"
	}
	enum BundleIds {
		static let launcher = "com.ergoptiplus.app"
		static let hammerspoon = "com.ergoptiplus.app.hammerspoon"
	}
	enum SigningIds {
		static let runtimeInstaller = "com.ergoptiplus.app.runtime-installer"
		static let installedPhysicalSource = "com.ergoptiplus.app.installed-physical-source"
		static let remapCore = "com.ergoptiplus.remap.core"
		static let remapConsole = "com.ergoptiplus.remap.console"
		static let remapCli = "com.ergoptiplus.remap.cli"
	}
	enum ServiceLabels {
		static let macosCore = "com.ergoptiplus.runtime.core"
		static let macosRemapGuardian = "com.ergoptiplus.remap-guardian"
		static let macosVirtualHid = "com.ergoptiplus.runtime.vhid"
	}
	enum Hosts {
		static let github = "github.com"
		static let githubApi = "api.github.com"
		static let huggingface = "huggingface.co"
		static let ollama = "ollama.com"
		static let ollamaRegistry = "registry.ollama.ai"
	}
	enum DevSource {
		static let plistKey = "ErgoptiDevSourceRoot"
		static let environment = "ERGOPTI_DEV_SOURCE_ROOT"
	}
	enum FieldReport {
		static let branchPrefix = "field/"
		static let folder = "docs/field-reports"
		static let baseConfigKey = "ergoptiFieldBase"
		static let environment = "ERGOPTI_FIELD_RUN_ROOT"
	}
	enum MacosNotifications {
		static let launcherQuitRequest = "com.ergoptiplus.app.quit-request"
	}
}
