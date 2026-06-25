/**
 * _shared/ui/token_prompt/script.js
 * HuggingFace token input UI — shared frontend for both drivers.
 */

// Host-agnostic post: Windows WebView2 takes a string over window.chrome.webview
// (objects are JSON-encoded); macOS WKWebView takes the raw payload over the
// token_bridge usercontent handler. The page never assumes one host.
function post(payload) {
	if (window.chrome && window.chrome.webview && typeof window.chrome.webview.postMessage === 'function') {
		window.chrome.webview.postMessage(typeof payload === 'string' ? payload : JSON.stringify(payload));
		return;
	}
	if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.token_bridge) {
		window.webkit.messageHandlers.token_bridge.postMessage(payload);
	}
}

function doOpenLink() {
	post('open_link');
}

function doCancel() {
	post('cancel');
}

function doValidate() {
	const token = document.getElementById('token-input').value || '';
	post({
		type: 'validate',
		token: token
	});
}

// Focus input on load and register Enter key handler
window.addEventListener('load', function () {
	const input = document.getElementById('token-input');
	if (input) {
		// Multi-step focus to ensure visibility
		input.focus();
		setTimeout(() => {
			input.focus();
			input.select();
		}, 50);
		setTimeout(() => {
			input.focus();
		}, 150);

		input.addEventListener('keypress', function (e) {
			if (e.key === 'Enter') {
				doValidate();
			}
		});
	}
});

// Also try to focus immediately
document.addEventListener('DOMContentLoaded', function () {
	const input = document.getElementById('token-input');
	if (input) {
		input.focus();
	}
});
