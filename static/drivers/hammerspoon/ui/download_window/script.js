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

const KIND_TITLES = {
	mlx_install: '⚙️ Installation du moteur IA (MLX)',
	ollama_install: '⚙️ Installation du moteur IA (Ollama)',
	mlx_model: '📥 Téléchargement du modèle MLX',
	ollama_model: '📥 Téléchargement du modèle Ollama',
};

const KIND_MODES = {
	mlx_install: 'bootstrap',
	ollama_install: 'bootstrap',
	mlx_model: 'download',
	ollama_model: 'download',
};

/**
 * Switches the body class set so the right "kind" accent and "mode" layout
 * are applied. Called by the Lua side at show() time and again whenever the
 * caller re-issues show() with a different kind.
 * @param {string} kind - One of mlx_install, ollama_install, mlx_model, ollama_model.
 * @param {string|null} title - Override for the H2 title (null = use default for kind).
 * @param {string|null} subtitle - Override for the subtitle line (bootstrap mode only).
 */
function setKind(kind, title, subtitle) {
	if (!kind || !KIND_MODES[kind]) return;
	const mode = KIND_MODES[kind];
	// Clear previous kind/mode classes before applying the fresh ones
	document.body.classList.remove(
		'mode-download',
		'mode-bootstrap',
		'kind-mlx_install',
		'kind-ollama_install',
		'kind-mlx_model',
		'kind-ollama_model',
		'is-error'
	);
	document.body.classList.add('mode-' + mode, 'kind-' + kind);

	const titleEl = document.getElementById('title');
	if (titleEl) titleEl.textContent = title || KIND_TITLES[kind] || 'Progression';

	const subtitleEl = document.getElementById('subtitle');
	if (subtitleEl) subtitleEl.textContent = subtitle || '';
}

/**
 * Updates the bootstrap step label (second line, brighter).
 * @param {string} text - French step label.
 */
function setStep(text) {
	document.body.classList.remove('is-error');
	const el = document.getElementById('step-line');
	if (el) el.textContent = text || '';
}

/**
 * Updates the bootstrap detail line (third line, monospaced, dimmed).
 * Truncation from the left is handled in CSS via direction: rtl.
 * @param {string} text - Raw subprocess output line.
 */
function setDetail(text) {
	const el = document.getElementById('detail-line');
	if (!el) return;
	// Strip ANSI escape sequences so the user sees clean text
	const clean = String(text || '').replace(/\x1b\[[0-9;]*[A-Za-z]/g, '');
	el.textContent = clean;
}

/**
 * Updates the bootstrap progress bar fill. Pass null for indeterminate.
 * @param {number|null} pct - Percentage in [0, 100], or null for indeterminate.
 */
function setProgress(pct) {
	const fill = document.getElementById('bootstrap-bar-fill');
	if (!fill) return;
	if (pct === null || pct === undefined) {
		fill.style.width = '0%';
		return;
	}
	const clamped = Math.max(0, Math.min(100, Number(pct) || 0));
	fill.style.width = clamped + '%';
}

/**
 * Switches the bootstrap UI to error presentation: red accent + red step.
 * @param {string} text - Short French error message.
 */
function setError(text) {
	document.body.classList.add('is-error');
	const el = document.getElementById('step-line');
	if (el) el.textContent = text || 'Erreur inconnue.';
}

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
 * Resets the UI to its initial state for a retry, preventing zombie placeholders.
 */
function resetUI() {
	globalLogLines = [];
	globalDoneState = false;

	const barFill = document.getElementById('bar-fill');
	barFill.style.width = '0%';
	barFill.classList.remove('error');

	const pctEl = document.getElementById('pct');
	pctEl.textContent = '0 %';
	pctEl.style.color = '#30d158';

	document.getElementById('file-count').style.display = 'none';
	document.getElementById('file-count').textContent = '';

	document.getElementById('stats-details').style.display = 'none';
	document.getElementById('eta-container').style.display = 'none';
	document.getElementById('done-msg').style.display = 'none';
	document.getElementById('stats-fallback').style.display = 'block';

	const logArea = document.getElementById('log-area');
	logArea.textContent = '';
	logArea.style.display = 'none';

	const cancelBtn = document.getElementById('btn-cancel');
	if (cancelBtn) {
		cancelBtn.style.display = 'inline-block';
		cancelBtn.disabled = false;
		cancelBtn.textContent = '🛑 Annuler';
	}

	const retryBtn = document.getElementById('btn-retry');
	if (retryBtn) retryBtn.style.display = 'none';
}

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
 * @param {string} fileCount - Optional file progress string (e.g., "47/102").
 */
function update(percentage, downloadedSize, speed, eta, fileCount) {
	if (globalDoneState) return; // Cap at 99% during download: 100% is reserved exclusively for done()

	const cappedPercentage = Math.min(Math.max(0, parseInt(percentage) || 0), 99);
	document.getElementById('bar-fill').style.width = cappedPercentage + '%';
	document.getElementById('pct').textContent = cappedPercentage + ' %'; // Line 1: Fichiers (next to percentage, pushed right by CSS)

	const fileCountEl = document.getElementById('file-count');
	if (fileCount) {
		fileCountEl.textContent = `📁 Fichiers : ${fileCount}`;
		fileCountEl.style.display = 'block';
	} else {
		fileCountEl.style.display = 'none';
	} // Line 2: Taille & Vitesse

	const statsDetails = document.getElementById('stats-details');
	let detailsParts = [];

	if (downloadedSize) detailsParts.push(`📦 Taille : <b>${downloadedSize}</b>`);
	if (speed) detailsParts.push(`⚡ Vitesse : <b>${speed}</b>`);

	if (detailsParts.length > 0) {
		statsDetails.innerHTML = detailsParts.join(
			'<span class="gap"></span>—<span class="gap"></span>'
		);
		statsDetails.style.display = 'block';
		document.getElementById('stats-fallback').style.display = 'none';
	} else {
		statsDetails.style.display = 'none';
		document.getElementById('stats-fallback').style.display = 'block';
	} // Line 3: Temps restant

	const etaContainer = document.getElementById('eta-container');
	const etaEl = document.getElementById('eta');
	if (eta) {
		etaEl.textContent = eta;
		etaContainer.style.display = 'block';
	} else {
		etaContainer.style.display = 'none';
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
	if (!line) return; // Strip ANSI colors and control sequences from terminal output

	const cleanLine = String(line).replace(/\x1b\[[0-9;]*[A-Za-z]/g, ''); // Hide noisy transfer progress bars that visually duplicate the main UI bar

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
		progressBar.style.width = '100%';
		document.getElementById('pct').textContent = '❌';
		document.getElementById('pct').style.color = '#ff453a';
	} // Hide specific stats, files count and ETA to make room for the final message

	document.getElementById('file-count').style.display = 'none';
	document.getElementById('eta-container').style.display = 'none';
	document.getElementById('stats-details').style.display = 'none';
	document.getElementById('stats-fallback').style.display = 'none';

	const doneMessageElement = document.getElementById('done-msg');
	doneMessageElement.textContent =
		message || (isSuccess ? '✅ Terminé' : 'Échec du téléchargement');
	doneMessageElement.className = isSuccess ? 'ok' : 'error'; // Show it inline inside the status-line

	doneMessageElement.style.display = 'block';

	if (!isSuccess) {
		const retryBtn = document.getElementById('btn-retry');
		if (retryBtn) retryBtn.style.display = 'inline-block';
	}
}
