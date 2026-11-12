; _generated/identifiers.ahk
; AUTO-GENERATED from _shared/data/identifiers.json.
; DO NOT EDIT BY HAND — run `npm run codegen:identifiers` to refresh.
#Requires AutoHotkey v2.0

; ==============================================================================
; MODULE: Application Identifiers and External Hosts
; DESCRIPTION:
; The application file names, bundle ids, service labels, external hosts and
; field report names, and the catalogue shown for a system language without
; one. A misspelt name fails at the first access. Hosts are bare names: build a
; URL as "https://" . Identifiers.Hosts.GITHUB . "/...".
; ==============================================================================

class Identifiers {
	class App {
		static NAME := "ErgoptiPlus"
		static AHK := "ErgoptiPlus.ahk"
		static EXE := "ErgoptiPlus.exe"
		static BUNDLE := "ErgoptiPlus.app"
	}
	class BundleIds {
		static LAUNCHER := "com.ergoptiplus.app"
		static HAMMERSPOON := "com.ergoptiplus.app.hammerspoon"
	}
	class SigningIds {
		static RUNTIME_INSTALLER := "com.ergoptiplus.app.runtime-installer"
		static INSTALLED_PHYSICAL_SOURCE := "com.ergoptiplus.app.installed-physical-source"
		static REMAP_CORE := "com.ergoptiplus.remap.core"
		static REMAP_CONSOLE := "com.ergoptiplus.remap.console"
		static REMAP_CLI := "com.ergoptiplus.remap.cli"
	}
	class ServiceLabels {
		static MACOS_CORE := "com.ergoptiplus.runtime.core"
		static MACOS_REMAP_GUARDIAN := "com.ergoptiplus.remap-guardian"
		static MACOS_VIRTUAL_HID := "com.ergoptiplus.runtime.vhid"
	}
	class Hosts {
		static GITHUB := "github.com"
		static GITHUB_API := "api.github.com"
		static HUGGINGFACE := "huggingface.co"
		static OLLAMA := "ollama.com"
		static OLLAMA_REGISTRY := "registry.ollama.ai"
	}
	class DevSource {
		static PLIST_KEY := "ErgoptiDevSourceRoot"
		static ENVIRONMENT := "ERGOPTI_DEV_SOURCE_ROOT"
	}
	class FieldReport {
		static BRANCH_PREFIX := "field/"
		static FOLDER := "docs/field-reports"
		static BASE_CONFIG_KEY := "ergoptiFieldBase"
		static ENVIRONMENT := "ERGOPTI_FIELD_RUN_ROOT"
	}
	class Locales {
		static SYSTEM_FALLBACK := "en"
	}
}
