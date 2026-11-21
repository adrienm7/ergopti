// _shared/ui/numeric_prompt/script.js

// ===========================================================================
// MODULE: Numeric Prompt
// DESCRIPTION:
// Asks for one number, within a range the host declares, and hands it back.
//
// WHY IT EXISTS:
// macOS sets a numeric LLM setting through a free-text dialog; the Linux tray
// has no text input, so its menu offers presets. That difference was the last
// LLM gap between the two drivers, and closing it by taking the dialog away
// from macOS would have removed a capability. This adds the capability to Linux
// instead, so both have presets AND free entry.
//
// FEATURES & RATIONALE:
// 1. The host owns the rule. The page sends the text as typed and the host
//    reads it with the shared value check, so « 0,7 », a fraction in a whole
//    number or a value out of range is judged as macOS and Windows judge it,
//    not by the field's own number parser.
// 2. It refuses rather than clamping or rounding. Either would save a number
//    the user did not type while showing them the one they did.
// 3. It says why: the host's refusal names the accepted range, and the field
//    is marked invalid for a screen reader.
// ===========================================================================

const post = makeHostBridge('numeric_prompt_bridge');

/** Monotonic host request identity; prevents a retained page answering its successor. */
let requestEpoch = null;

/**
 * Shows an error under the field, or clears it.
 * @param {string} message - Empty string to clear.
 */
function showError(message) {
	const box = document.getElementById('error');
	if (!box) return;
	box.textContent = message || '';
	box.hidden = !message;
	const input = document.getElementById('value-input');
	if (input) input.setAttribute('aria-invalid', message ? 'true' : 'false');
}

/**
 * Shows the host's refusal of the typed text, and returns to the field.
 * Called by the host after it refused a save.
 * @param {string} message - Localized refusal naming what is accepted.
 */
function show_refusal(message) {
	showError(typeof message === 'string' ? message : '');
	const input = document.getElementById('value-input');
	if (input) input.focus();
}

/**
 * Fills the window from the host's request.
 * Called by the host after the page reports itself ready.
 * @param {object} request - { title, hint, value, range, request_epoch }
 */
function receive_prompt(request) {
	if (!request || typeof request !== 'object') return;
	requestEpoch = typeof request.request_epoch === 'number' ? request.request_epoch : null;
	showError('');

	const title = document.getElementById('prompt-title');
	if (title) title.textContent = request.title || '';
	const hint = document.getElementById('prompt-hint');
	if (hint) hint.textContent = request.hint || '';

	const input = document.getElementById('value-input');
	if (input) {
		input.value = request.value === undefined ? '' : String(request.value);
		input.focus();
		input.select();
	}

	const range = document.getElementById('range-hint');
	if (range) range.textContent = typeof request.range === 'string' ? request.range : '';
	showError('');
}

/** Sends the text as typed; the host reads it and answers a refusal with show_refusal. */
function doSave() {
	const input = document.getElementById('value-input');
	post({ action: 'save', text: input ? input.value : '', request_epoch: requestEpoch });
}

/** Closes without changing anything. */
function doCancel() {
	post({ action: 'cancel', request_epoch: requestEpoch });
}

window.addEventListener('load', function () {
	post('ready');
	const input = document.getElementById('value-input');
	if (input) {
		input.addEventListener('keydown', function (event) {
			if (event.isComposing) return;
			if (event.key === 'Enter') doSave();
			if (event.key === 'Escape') doCancel();
		});
	}
});
