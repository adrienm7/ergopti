// _shared/ui/metrics_typing/maintenance.js

/**
 * ==============================================================================
 * MODULE: Dashboard Export and Purge
 * DESCRIPTION:
 * The Export and Purge controls of the typing dashboard. Each asks for a
 * confirmation in the page, then hands the operation to the driver's single
 * owning metrics writer (Linux keystats, macOS log_manager, Windows KL_*
 * journal owner), which acts once its flush has settled and answers through
 * complete_metrics_maintenance.
 *
 * FEATURES & RATIONALE:
 * 1. One owner at a time: a monotonic id travels with the request, and only
 *    the answer carrying the active id is applied, so a late answer after the
 *    watchdog cannot overwrite a newer outcome.
 * 2. The three transports of the range request: WebView2 postMessage on
 *    Windows, the WebKit document bridge on Linux, the polled _lua_request
 *    mailbox on macOS.
 * 3. A Purge removes the metrics on every device (maintainer decision
 *    2026-11-06); after it commits, the page asks for a cache reset so it
 *    redraws from the purged store.
 * ==============================================================================
 */

// ======================================
// ======================================
// ======= 1/ Constants and State =======
// ======================================
// ======================================

// The writer waits for its flush before it acts; a purge also waits for the
// flush carrying its tombstone. Past this, the page stops waiting and says so.
const METRICS_MAINTENANCE_WATCHDOG_MS = 120_000;

const METRICS_MAINTENANCE_KINDS = Object.freeze(['export', 'purge']);
// Each kind's texts, spelled in full so the translation audit sees every key.
const METRICS_MAINTENANCE_TEXT = {
	export: {
		confirm: 'ui_typing.maintenance_confirm_export',
		done: 'ui_typing.maintenance_export_done',
		failed: 'ui_typing.maintenance_export_failed'
	},
	purge: {
		confirm: 'ui_typing.maintenance_confirm_purge',
		done: 'ui_typing.maintenance_purge_done',
		failed: 'ui_typing.maintenance_purge_failed'
	}
};

const metrics_maintenance_state = {
	pending_kind: null,
	active_kind: null,
	active_id: 0,
	sequence: 0,
	watchdog: null
};

// ===============================
// ===============================
// ======= 2/ Page Helpers =======
// ===============================
// ===============================

/**
 * Shows one line in the maintenance bar, with or without its confirm buttons.
 * @param {string} text - Localized message (set as text, never as HTML).
 * @param {boolean} asking - Whether the Confirm and Cancel buttons show.
 */
function show_metrics_maintenance(text, asking) {
	const bar = document.getElementById('metrics_maintenance_bar');
	if (!bar) return;
	bar.hidden = false;
	document.getElementById('metrics_maintenance_text').textContent = text;
	document.getElementById('btn_maintenance_confirm').hidden = !asking;
	document.getElementById('btn_maintenance_cancel').hidden = !asking;
}

/**
 * Enables or disables both maintenance buttons while a request is owned.
 * @param {boolean} busy - Whether a request is in flight.
 */
function set_metrics_maintenance_busy(busy) {
	for (const id of ['btn_metrics_export', 'btn_metrics_purge']) {
		const button = document.getElementById(id);
		if (button) button.disabled = busy;
	}
}

/**
 * Hands one request to the host through this window's transport.
 * @param {string} kind - "export" or "purge".
 * @param {number} id - Monotonic owner id.
 */
function post_metrics_maintenance(kind, id) {
	const message = { action: 'metrics_' + kind, maintenance_id: id };
	if (window.chrome?.webview) {
		window.chrome.webview.postMessage(JSON.stringify(message));
		return;
	}
	if (
		hostHasCapability('document_bridge') &&
		window.webkit?.messageHandlers?.metrics_typing_bridge
	) {
		window.webkit.messageHandlers.metrics_typing_bridge.postMessage(message);
		return;
	}
	window._lua_request = JSON.stringify(message);
}

// ================================
// ================================
// ======= 3/ Public Controls =======
// ================================
// ================================

/**
 * Asks for confirmation of an Export or a Purge.
 * @param {string} kind - "export" or "purge".
 * @returns {boolean} Whether the confirmation is now shown.
 */
function ask_metrics_maintenance(kind) {
	if (!METRICS_MAINTENANCE_KINDS.includes(kind) || metrics_maintenance_state.active_id)
		return false;
	metrics_maintenance_state.pending_kind = kind;
	show_metrics_maintenance(_t(METRICS_MAINTENANCE_TEXT[kind].confirm), true);
	return true;
}

/** Withdraws the confirmation without sending anything. */
function cancel_metrics_maintenance() {
	metrics_maintenance_state.pending_kind = null;
	const bar = document.getElementById('metrics_maintenance_bar');
	if (bar) bar.hidden = true;
}

/**
 * Sends the confirmed request to the owning writer.
 * @returns {number} The request's owner id, or 0 when nothing was confirmed.
 */
function confirm_metrics_maintenance() {
	const kind = metrics_maintenance_state.pending_kind;
	if (!kind || metrics_maintenance_state.active_id) return 0;
	const id = ++metrics_maintenance_state.sequence;
	metrics_maintenance_state.pending_kind = null;
	metrics_maintenance_state.active_kind = kind;
	metrics_maintenance_state.active_id = id;
	set_metrics_maintenance_busy(true);
	show_metrics_maintenance(_t('ui_typing.maintenance_pending'), false);
	metrics_maintenance_state.watchdog = setTimeout(() => {
		if (metrics_maintenance_state.active_id !== id) return;
		metrics_maintenance_state.active_id = 0;
		metrics_maintenance_state.active_kind = null;
		set_metrics_maintenance_busy(false);
		show_metrics_maintenance(_t('ui_typing.maintenance_timeout'), false);
	}, METRICS_MAINTENANCE_WATCHDOG_MS);
	post_metrics_maintenance(kind, id);
	return id;
}

/**
 * Applies the writer's answer to the request it owns.
 * @param {number} id - Owner id the page sent.
 * @param {boolean} ok - Whether the writer committed the operation.
 * @param {string|null} path - The Export copy, when one was written.
 * @returns {boolean} Whether this answer completed the active request.
 */
function complete_metrics_maintenance(id, ok, path) {
	if (!Number.isSafeInteger(id) || id <= 0 || id !== metrics_maintenance_state.active_id)
		return false;
	if (typeof ok !== 'boolean') return false;
	const kind = metrics_maintenance_state.active_kind;
	clearTimeout(metrics_maintenance_state.watchdog);
	metrics_maintenance_state.watchdog = null;
	metrics_maintenance_state.active_id = 0;
	metrics_maintenance_state.active_kind = null;
	set_metrics_maintenance_busy(false);
	const outcome = ok ? 'done' : 'failed';
	const text = _t(METRICS_MAINTENANCE_TEXT[kind][outcome]).replace('{path}', String(path ?? ''));
	show_metrics_maintenance(text, false);
	if (ok && kind === 'purge' && typeof request_cache_reset === 'function') request_cache_reset();
	return true;
}
