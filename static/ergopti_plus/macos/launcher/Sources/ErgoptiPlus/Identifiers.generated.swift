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
	enum ServiceLabels {
		static let macosCore = "com.ergoptiplus.runtime.core"
		static let macosVirtualHid = "com.ergoptiplus.runtime.vhid"
	}
	enum Hosts {
		static let github = "github.com"
		static let githubApi = "api.github.com"
		static let huggingface = "huggingface.co"
		static let ollama = "ollama.com"
		static let ollamaRegistry = "registry.ollama.ai"
	}
}
