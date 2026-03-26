// ui/download_window/script.js

// ===========================================================================
// Download Window UI Script.
//
// Manages the UI state, progress bars, and logging output for the Ollama
// LLM model download window. Handles communication with the Hammerspoon backend.
// ===========================================================================

// ==================================
// ==================================
// ======= 1/ Globals & State =======
// ==================================
// ==================================

let logLines = [];

// ========================================
// ========================================
// ======= 2/ Backend Communication =======
// ========================================
// ========================================

/**
 * Disables the cancel button, updates its UI, and sends a cancellation request to the backend.
 */
function doCancel() {
	const cancelButton = document.getElementById('btn-cancel');
	cancelButton.disabled = true;
	cancelButton.textContent = 'Annulation…';

	if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dl_bridge) {
		window.webkit.messageHandlers.dl_bridge.postMessage('cancel');
	}
}

/**
 * Sends a request to the backend to open the Terminal for manual intervention.
 */
function doTerm() {
	if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dl_bridge) {
		window.webkit.messageHandlers.dl_bridge.postMessage('terminal');
	}
}

// =============================
// =============================
// ======= 3/ UI Updates =======
// =============================
// =============================

/**
 * Sets the displayed model name in the UI.
 * @param {string} modelName - The name of the model being downloaded.
 */
function setModel(modelName) {
	document.getElementById('model').textContent = modelName;
}

/**
 * Updates the progress bar and statistics display.
 * @param {number|string} percentage - The completion percentage.
 * @param {string} downloadedSize - The formatted downloaded size string.
 * @param {string} speed - The current download speed.
 * @param {string} eta - The estimated time remaining.
 */
function update(percentage, downloadedSize, speed, eta) {
	document.getElementById('bar-fill').style.width = percentage + '%';
	document.getElementById('pct').textContent = percentage + ' %';

	let statsHtml = '';
	if (downloadedSize) statsHtml += '<b>' + downloadedSize + '</b><br>';
	if (speed) statsHtml += 'Vitesse : <b>' + speed + '</b>';
	if (eta) statsHtml += '  ·  Temps restant : <b>' + eta + '</b>';

	document.getElementById('stats').innerHTML = statsHtml || 'Téléchargement en cours…';
}

/**
 * Forces the display of the raw terminal log area in the UI.
 */
function showLog() {
	document.getElementById('log-area').style.display = 'block';
}

/**
 * Appends a new line to the internal log buffer and updates the scrollable log text area.
 * Keeps a maximum of 200 lines to prevent performance issues.
 * @param {string} line - The log string to append.
 */
function addLog(line) {
	logLines.push(line);
	if (logLines.length > 200) logLines.shift();

	const logArea = document.getElementById('log-area');
	logArea.textContent = logLines.join('\n');
	logArea.scrollTop = logArea.scrollHeight;
}

/**
 * Transitions the UI to its final state (success or error).
 * @param {boolean} isSuccess - True if the download completed successfully, false otherwise.
 * @param {string} message - The final message to display to the user.
 */
function done(isSuccess, message) {
	document.getElementById('btn-cancel').style.display = 'none';
	document.getElementById('bar-fill').style.width = '100%';
	document.getElementById('pct').textContent = isSuccess ? '100 %' : '—';

	const doneMessageElement = document.getElementById('done-msg');
	doneMessageElement.textContent = message;
	doneMessageElement.className = isSuccess ? 'ok' : 'error';
	doneMessageElement.style.display = 'block';

	document.getElementById('stats').textContent = '';
}
