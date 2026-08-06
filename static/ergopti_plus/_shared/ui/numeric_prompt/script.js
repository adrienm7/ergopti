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
// 1. The host owns the bounds. The page draws whatever range it is given rather
//    than knowing about temperature or context length, so a second setting
//    needs no second page.
// 2. It refuses out of range rather than clamping. Clamping would return a
//    number the user did not type while showing them the one they did.
// 3. It says why. An input that rejects silently reads as a broken button.
// ===========================================================================

const post = makeHostBridge('numeric_prompt_bridge');

/** The range the host declared, filled by receive_prompt. */
let bounds = { min: null, max: null };

/**
 * Shows an error under the field, or clears it.
 * @param {string} message - Empty string to clear.
 */
function showError(message) {
	const box = document.getElementById('error');
	if (!box) return;
	box.textContent = message || '';
	box.hidden = !message;
}

/**
 * Fills the window from the host's request.
 * Called by the host after the page reports itself ready.
 * @param {object} request - { title, hint, value, min, max }
 */
function receive_prompt(request) {
	if (!request || typeof request !== 'object') return;
	bounds = { min: request.min, max: request.max };

	const title = document.getElementById('prompt-title');
	if (title) title.textContent = request.title || '';
	const hint = document.getElementById('prompt-hint');
	if (hint) hint.textContent = request.hint || '';

	const input = document.getElementById('value-input');
	if (input) {
		if (typeof request.min === 'number') input.min = String(request.min);
		if (typeof request.max === 'number') input.max = String(request.max);
		input.value = request.value === undefined ? '' : String(request.value);
		input.focus();
		input.select();
	}

	const range = document.getElementById('range-hint');
	if (range && typeof request.min === 'number' && typeof request.max === 'number') {
		range.textContent = request.min + ' – ' + request.max;
	}
	showError('');
}

/** Sends the typed value back, or reports why it cannot. */
function doSave() {
	const input = document.getElementById('value-input');
	const raw = input ? input.value : '';
	const value = Number(raw);

	// An empty field is not zero. Number('') is 0, and saving that would set a
	// temperature of zero for a user who cleared the box to start over.
	if (raw === '' || Number.isNaN(value)) {
		showError(window.i18n_get ? window.i18n_get('numeric_prompt.not_a_number') : '');
		return;
	}
	if (typeof bounds.min === 'number' && value < bounds.min) {
		showError(window.i18n_get ? window.i18n_get('numeric_prompt.out_of_range') : '');
		return;
	}
	if (typeof bounds.max === 'number' && value > bounds.max) {
		showError(window.i18n_get ? window.i18n_get('numeric_prompt.out_of_range') : '');
		return;
	}

	post({ action: 'save', value: value });
}

/** Closes without changing anything. */
function doCancel() {
	post({ action: 'cancel' });
}

window.addEventListener('load', function () {
	post('ready');
	const input = document.getElementById('value-input');
	if (input) {
		input.addEventListener('keydown', function (event) {
			if (event.key === 'Enter') doSave();
			if (event.key === 'Escape') doCancel();
		});
	}
});
