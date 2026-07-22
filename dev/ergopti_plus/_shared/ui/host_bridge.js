// _shared/ui/host_bridge.js

// ===========================================================================
// MODULE: Host Bridge Factory
// DESCRIPTION:
// Provides makeHostBridge(name) — a factory for host-agnostic post functions
// used by every webview app. On Windows (WebView2) the payload is sent as a
// JSON string over window.chrome.webview; on macOS (WKWebView) and Linux
// (WebKit2GTK) the raw payload is posted over window.webkit.messageHandlers[name]
// — both use the same WebKit JS API, so no third probe is needed for Linux.
// String payloads bypass JSON.stringify so plain-string commands ('ready',
// 'open_link', …) travel as-is.
//
// Handler name contract — every host MUST register a message handler for the
// bridge name used by its webview app. These names are stable API:
//
//   action_picker_bridge      — _shared/ui/action_picker
//   changelog_bridge          — _shared/ui/changelog
//   dl_bridge                 — _shared/ui/download_window
//   hsEditor                  — _shared/ui/hotstring_editor
//   hotstrings_config_bridge  — _shared/ui/hotstrings_config_window
//   hsOnboarding              — _shared/ui/onboarding
//   hsPaths                   — _shared/ui/paths_editor
//   hsPersonalInfo            — _shared/ui/personal_info_editor
//   metrics_apps_bridge       — _shared/ui/metrics_apps
//   metrics_typing_bridge     — _shared/ui/metrics_typing
//   model_browser_bridge      — _shared/ui/model_browser
//   prompt_bridge             — _shared/ui/prompt_editor
//   token_bridge              — _shared/ui/token_prompt
//   healthcheck                — _shared/ui/healthcheck (future)
//   personal_toml_editor       — _shared/ui/personal_toml_editor (future)
//
// Linux host (WebKit2GTK) MUST register each handler via
// webkit_user_content_manager_register_script_message_handler() for the
// corresponding bridge name before loading the webview.
// ===========================================================================

/**
 * Creates a host-agnostic post function for the given WKWebView handler name.
 * Windows (WebView2) is always probed first and the call returns early to avoid
 * double-posting. Wrapped in try/catch so bridge failures degrade gracefully.
 * @param {string} name - WKWebView messageHandler name (macOS bridge identifier).
 * @returns {function(any): void}
 */
function makeHostBridge(name) {
	return function post(payload) {
		try {
			if (window.chrome && window.chrome.webview && typeof window.chrome.webview.postMessage === 'function') {
				window.chrome.webview.postMessage(typeof payload === 'string' ? payload : JSON.stringify(payload));
				return;
			}
			if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[name]) {
				window.webkit.messageHandlers[name].postMessage(payload);
			}
		} catch (e) {
			console.error('[' + name + '] postMessage failed:', e);
		}
	};
}

/**
 * Decodes a response emitted by the Linux WebKit host bridge.
 * @param {boolean} isBase64 - Whether the payload was base64-encoded by the host.
 * @param {string} payload - Encoded JSON response body.
 * @returns {any|null} Parsed response, or null when the host payload is invalid.
 */
function decodeHostBridgeResponse(isBase64, payload) {
	try {
		const serialized = isBase64
			? new TextDecoder().decode(Uint8Array.from(atob(payload), (char) => char.charCodeAt(0)))
			: decodeURIComponent(payload);
		return JSON.parse(serialized);
	} catch (error) {
		console.error("[host bridge] failed to decode native response:", error);
		return null;
	}
}
