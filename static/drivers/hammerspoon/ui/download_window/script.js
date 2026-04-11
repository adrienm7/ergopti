// ui/download_window/script.js

/**
 * ==============================================================================
 * MODULE: Download Window UI Script
 * DESCRIPTION:
 * Manages the UI state, progress bars, and logging output for the Ollama
 * LLM model download window. Handles communication with the Hammerspoon backend.
 *
 * FEATURES & RATIONALE:
 * 1. Vanilla DOM Updates: Keeps rendering fast without dependencies.
 * 2. Message Bridge: Communicates state cleanly to Hammerspoon.
 * ==============================================================================
 */

let globalLogLines = [];
let globalDoneState = false;

// ========================================
// ========================================
// ======= 1/ Backend Communication =======
// ========================================
// ========================================

/**
 * Disables the cancel button, updates its UI, and sends a cancellation request to the backend.
 */
function doCancel() {
	const cancelButton = document.getElementById('btn-cancel');
	if (cancelButton) {
		cancelButton.disabled = true;
		cancelButton.textContent = 'Annulation…';
	}

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

/**
 * Sends a retry request to relaunch the download.
 */
function doRetry() {
	if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dl_bridge) {
		window.webkit.messageHandlers.dl_bridge.postMessage('retry');
	}
}

// =============================
// =============================
// ======= 2/ UI Updates =======
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
 * Injects model size parameters safely into the frontend.
 * @param {Object} sizes - Object containing dl, disk, and ram sizes as formatted strings.
 */
function setSizes(sizes) {
	const container = document.getElementById('model-sizes');
	const szDl = document.getElementById('sz-dl');
	const szRam = document.getElementById('sz-ram');

	let hasSizes = false;
	if (sizes.dl) {
		szDl.textContent = '⬇️ ' + sizes.dl;
		hasSizes = true;
	}
	if (sizes.params) {
		szRam.textContent = '🧠 ' + sizes.params + ' paramètres';
		hasSizes = true;
	}

	if (hasSizes) {
		container.style.display = 'flex';
	}
}

/**
 * Updates the progress bar and statistics display.
 * @param {number|string} percentage - The completion percentage.
 * @param {string} downloadedSize - The formatted downloaded size string.
 * @param {string} speed - The current download speed.
 * @param {string} eta - The estimated time remaining.
 * @param {string} fileCount - Optional file progress string (e.g., "47/102").
 */
function update(percentage, downloadedSize, speed, eta, fileCount) {
	if (globalDoneState) return;

	// Cap at 99% during download: 100% is reserved exclusively for done()
	const cappedPercentage = Math.min(Math.max(0, parseInt(percentage) || 0), 99);
	document.getElementById('bar-fill').style.width = cappedPercentage + '%';
	document.getElementById('pct').textContent = cappedPercentage + ' %';

	// Line 1: ETA
	const etaContainer = document.getElementById('eta-container');
	const etaEl = document.getElementById('eta');
	if (eta) {
		etaEl.textContent = eta;
		etaContainer.style.display = 'inline-block';
	} else {
		etaContainer.style.display = 'none';
	}

	// Line 2: Size | Speed | Files
	const statsDetails = document.getElementById('stats-details');
	let detailsParts = [];

	if (downloadedSize) detailsParts.push(`📦 Taille : <b>${downloadedSize}</b>`);
	if (speed) detailsParts.push(`⚡ Vitesse : <b>${speed}</b>`);
	if (fileCount) detailsParts.push(`📁 Fichiers : <b>${fileCount}</b>`);

	if (detailsParts.length > 0) {
		statsDetails.innerHTML = detailsParts.join(
			'<span class="gap"></span>—<span class="gap"></span>'
		);
		statsDetails.style.display = 'block';
		document.getElementById('stats-fallback').style.display = 'none';
	} else {
		statsDetails.style.display = 'none';
		document.getElementById('stats-fallback').style.display = 'block';
	}
}

/**
 * Forces the display of the raw terminal log area in the UI.
 */
function showLog() {
	document.getElementById('log-area').style.display = 'block';
	if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dl_bridge) {
		window.webkit.messageHandlers.dl_bridge.postMessage('expand');
	}
}

/**
 * Appends a new line to the internal log buffer and updates the scrollable log text area.
 * Keeps a maximum of 200 lines to prevent performance issues.
 * @param {string} line - The log string to append.
 */
function addLog(line) {
	if (!line) return;

	// Strip ANSI colors and control sequences from terminal output
	const cleanLine = String(line).replace(/\x1b\[[0-9;]*[A-Za-z]/g, '');

	// Hide noisy transfer progress bars that visually duplicate the main UI bar
	if (/%\|.*it\/s/.test(cleanLine) || /\|\s*\d+\s*\/\s*\d+\s*\[/.test(cleanLine)) {
		return;
	}

	globalLogLines.push(cleanLine);
	if (globalLogLines.length > 200) globalLogLines.shift();

	const logArea = document.getElementById('log-area');
	logArea.textContent = globalLogLines.join('\n');
	logArea.scrollTop = logArea.scrollHeight;
}

/**
 * Transitions the UI to its final state (success or error).
 * @param {boolean} isSuccess - True if the download completed successfully, false otherwise.
 * @param {string} message - The final message to display to the user.
 * @param {string} errorKind - The error kind, such as "gated".
 */
function done(isSuccess, message, errorKind) {
	globalDoneState = true;

	const cancelButton = document.getElementById('btn-cancel');
	if (cancelButton) cancelButton.style.display = 'none';

	const progressBar = document.getElementById('bar-fill');
	if (isSuccess) {
		progressBar.style.width = '100%';
		progressBar.classList.remove('error');
		document.getElementById('pct').textContent = '100 %';
	} else {
		progressBar.classList.add('error');
		if (
			!progressBar.style.width ||
			progressBar.style.width === '0%' ||
			progressBar.style.width === ''
		) {
			progressBar.style.width = '100%';
		}
		document.getElementById('pct').textContent = '❌';
		document.getElementById('pct').style.color = '#ff453a';
	}

	const doneMessageElement = document.getElementById('done-msg');
	doneMessageElement.textContent = message;
	doneMessageElement.className = isSuccess ? 'ok' : 'error';
	doneMessageElement.style.display = 'inline-block';

	const statsElement = document.getElementById('stats');
	statsElement.textContent = '';

	if (!isSuccess) {
		// Keep the error label visually attached to the cross icon
		doneMessageElement.textContent = 'Échec du téléchargement';
	}

	if (!isSuccess) {
		// show retry button in main controls
		const retryBtn = document.getElementById('btn-retry');
		if (retryBtn) retryBtn.style.display = 'inline-block';
	} else {
		const retryBtn = document.getElementById('btn-retry');
		if (retryBtn) retryBtn.style.display = 'none';
	}
}
