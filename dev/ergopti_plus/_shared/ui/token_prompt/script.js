/**
 * _shared/ui/token_prompt/script.js
 * HuggingFace token input UI — shared frontend for both drivers.
 */

const post = makeHostBridge('token_bridge');

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
