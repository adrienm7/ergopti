/**
 * _shared/ui/token_prompt/script.js
 * HuggingFace token input UI — shared frontend for both drivers.
 */

const post = makeHostBridge('token_bridge');

const FOCUS_RETRY_FIRST_MS = 50; // [ui] token_prompt_focus_retry_first_ms
const FOCUS_RETRY_SECOND_MS = 150; // [ui] token_prompt_focus_retry_second_ms

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
		// Retry focus only while no control has been chosen. Selecting the input
		// later would replace a token the user has already started typing.
		const focusIfUnclaimed = () => {
			if (document.activeElement === document.body) input.focus();
		};
		focusIfUnclaimed();
		setTimeout(focusIfUnclaimed, FOCUS_RETRY_FIRST_MS);
		setTimeout(focusIfUnclaimed, FOCUS_RETRY_SECOND_MS);

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
	if (input && document.activeElement === document.body) {
		input.focus();
	}
});
