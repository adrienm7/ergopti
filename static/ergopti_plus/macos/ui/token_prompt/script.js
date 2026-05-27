/**
 * ui/token_prompt/script.js
 * HuggingFace token input UI for Hammerspoon
 */

function doOpenLink() {
	if (
		window.webkit &&
		window.webkit.messageHandlers &&
		window.webkit.messageHandlers.token_bridge
	) {
		window.webkit.messageHandlers.token_bridge.postMessage('open_link');
	}
}

function doCancel() {
	if (
		window.webkit &&
		window.webkit.messageHandlers &&
		window.webkit.messageHandlers.token_bridge
	) {
		window.webkit.messageHandlers.token_bridge.postMessage('cancel');
	}
}

function doValidate() {
	const token = document.getElementById('token-input').value || '';
	if (
		window.webkit &&
		window.webkit.messageHandlers &&
		window.webkit.messageHandlers.token_bridge
	) {
		window.webkit.messageHandlers.token_bridge.postMessage({
			type: 'validate',
			token: token
		});
	}
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
