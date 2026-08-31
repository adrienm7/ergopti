// _shared/ui/healthcheck/script.js

// ===========================================================================
// MODULE: Healthcheck Shared Renderer
// DESCRIPTION:
// Receives a diagnostic snapshot as JSON and renders the full report
// client-side.  All labels are in English (developer-facing diagnostic —
// not i18n'd).  Handles both Windows (AHK) and macOS snapshot shapes;
// the OS-specific system rows are rendered conditionally based on which
// fields are present in the snapshot.
//
// Entry point:
//   window.renderHealthcheck(snapshot)
//     snapshot — the raw snapshot object produced by HealthCheck_Run()
//     on Windows or M.run() on macOS.  The top-level keys are:
//       version, sys, uptime_sec, warn_count, err_count,
//       ports_validated, failed_adapters,
//       wired_count, adapter_count, unwired_adapters,  (macOS only)
//       event_tap_timeout_telemetry,                    (macOS only)
//       last_error, recent_issues,
//       pause_state, keylogger, llm, layout, hotstrings, logs, config
// ===========================================================================

/**
 * Formats raw seconds into a human-readable uptime string (e.g. "2h 04m 37s").
 * @param {number} sec
 * @returns {string}
 */
function formatUptime(sec) {
	sec = Math.floor(sec || 0);
	var h = Math.floor(sec / 3600);
	var m = Math.floor((sec % 3600) / 60);
	var s = sec % 60;
	if (h > 0) {
		return h + 'h ' + String(m).padStart(2, '0') + 'm ' + String(s).padStart(2, '0') + 's';
	}
	if (m > 0) {
		return m + 'm ' + String(s).padStart(2, '0') + 's';
	}
	return s + 's';
}

/**
 * Renders a key-value table row.
 * @param {string} field
 * @param {string} value HTML-safe value
 * @returns {string}
 */
function row(field, value) {
	return '<tr><td>' + field + '</td><td>' + value + '</td></tr>';
}

/**
 * Renders the complete healthcheck report into #content.
 * @param {object} s - Snapshot from HealthCheck_Run() / M.run()
 */
window.renderHealthcheck = function (s) {
	s = s || {};
	var sys = s.sys || {};
	var okList = s.ports_validated || [];
	var failList = s.failed_adapters || [];
	var total = okList.length + failList.length;
	var warnCount = s.warn_count || 0;
	var errCount = s.err_count || 0;
	var lastErr = s.last_error || '';
	var issues = s.recent_issues || [];

	var html = '';

	// ── Title ────────────────────────────────────────────────────────────
	html += '<h1>System diagnostic</h1>';

	// ── System table ─────────────────────────────────────────────────────
	html += '<h2>System</h2>';
	html += '<table><tr><th>Field</th><th>Value</th></tr>';

	html += row('ErgoptiPlus version', escapeHtml(String(s.version || '')));
	html += row('Last git commit', escapeHtml(String(sys.git_hash || 'unknown')));
	html += row('Uptime', escapeHtml(formatUptime(s.uptime_sec)));

	// OS-specific rows: detect the driver by the presence of ahk_version vs hs_version
	if (sys.ahk_version !== undefined) {
		// Windows / AHK driver
		html += row('AutoHotkey', escapeHtml(String(sys.ahk_version || '') + ' ' + String(sys.ahk_bitness || '')));
		html += row('Windows', escapeHtml(String(sys.os_name || '')));
		html += row('Windows build', escapeHtml(String(sys.os_build || '')));
		html += row('Architecture', escapeHtml(String(sys.os_arch || '')));
	} else if (sys.hs_version !== undefined) {
		// macOS / Hammerspoon driver
		html += row('Hammerspoon', escapeHtml(String(sys.hs_version || '?')));
		if (s.event_tap_timeout_telemetry) {
			html += row(
				'Native tap timeout telemetry',
				escapeHtml(String(s.event_tap_timeout_telemetry.summary || 'unavailable'))
			);
		}
		html += row('macOS', escapeHtml(String(sys.os_version || '?')));
		html += row('Architecture', escapeHtml(String(sys.arch || '?')));
	}

	html += row('CPU', escapeHtml(String(sys.cpu_name || sys.cpu_model || '?')));
	html += row('Logical cores', escapeHtml(String(sys.cpu_cores || '?')));

	if (sys.ram_total_gb !== undefined) {
		// Windows format
		html += row('Total RAM', escapeHtml(String(sys.ram_total_gb) + ' GB'));
		html += row('Available RAM', escapeHtml(String(sys.ram_free_gb) + ' GB'));
	} else {
		// macOS format
		html += row('Total RAM', escapeHtml(String(sys.ram_total || '?')));
		html += row('Available RAM', escapeHtml(String(sys.ram_free || '?')));
	}

	html += row('Screen resolution', escapeHtml(String(sys.screen_res || '?')));

	if (sys.dpi_scale !== undefined) {
		// Windows DPI
		html += row('DPI', escapeHtml(String(sys.dpi || '') + ' (' + String(sys.dpi_scale) + '%)'));
	} else if (sys.dpi !== undefined) {
		// macOS DPI (may have retina_scale)
		var dpiVal = escapeHtml(String(sys.dpi || '?'));
		if (sys.retina_scale) {
			dpiVal += ' &nbsp;<em>' + escapeHtml(String(sys.retina_scale)) + ' Retina</em>';
		}
		html += row('DPI', dpiVal);
	}

	html += row('Locale', escapeHtml(String(sys.locale || '?')));

	if (sys.config_dir) {
		html += row('Config dir', '<code>' + escapeHtml(String(sys.config_dir)) + '</code>');
	}

	html += '</table>';

	// ── Session counters ─────────────────────────────────────────────────
	var warnOk = warnCount === 0
		? '<span class="ok">&#x2705; ' + warnCount + '</span>'
		: '<span class="fail">&#x274C; ' + warnCount + '</span>';
	var errOk = errCount === 0
		? '<span class="ok">&#x2705; ' + errCount + '</span>'
		: '<span class="fail">&#x274C; ' + errCount + '</span>';

	html += '<h2>Session counters</h2>';
	html += '<table><tr><th>Type</th><th>Count</th></tr>';
	html += '<tr><td>&#x26A0;&#xFE0F; Warnings</td><td>' + warnOk + '</td></tr>';
	html += '<tr><td>&#x1F534; Errors</td><td>' + errOk + '</td></tr>';
	html += '</table>';

	// ── Runtime state ────────────────────────────────────────────────────
	if (s.pause_state || s.layout || s.llm || s.keylogger || s.hotstrings || s.logs) {
		html += '<h2>Runtime state</h2>';
		html += '<table><tr><th>Field</th><th>Value</th></tr>';

		if (s.pause_state) {
			var ps = s.pause_state;
			var pauseVal = ps.is_paused
				? '<span class="fail">PAUSED</span> (' + escapeHtml(String(ps.source || '')) + ')'
				: '<span class="ok">running</span>';
			html += row('Pause / Suspend', pauseVal);
		}

		if (s.layout) {
			var ly = s.layout;
			html += row('Layout base', escapeHtml(String(ly.ergopti_base)));
			html += row('AltGr', escapeHtml(String(ly.altgr)));
			html += row('Shift', escapeHtml(String(ly.shift)));
			html += row('Caps', escapeHtml(String(ly.caps)));
			html += row('Prefix latch', escapeHtml(String(ly.prefix_latch)));
		}

		if (s.llm) {
			var ll = s.llm;
			html += row('LLM enabled', escapeHtml(String(ll.enabled)));
			html += row('LLM backend', escapeHtml(String(ll.backend)));
			html += row('LLM profile', escapeHtml(String(ll.active_profile)));
			if (ll.model !== undefined) {
				html += row('LLM model', escapeHtml(String(ll.model)));
			}
			if (ll.n_predictions !== undefined) {
				html += row('LLM predictions', escapeHtml(String(ll.n_predictions)));
			}
		}

		if (s.keylogger) {
			var kl = s.keylogger;
			html += row('Keylogger events', escapeHtml(String(kl.events_session)));
			html += row('WPM', escapeHtml(String(kl.wpm)));
			html += row('Privacy hits', escapeHtml(String(kl.privacy_hits)));
		}

		if (s.hotstrings) {
			var ht = s.hotstrings;
			html += row('Terminators', escapeHtml(String(ht.terminators)));
			html += row('Personal hotstrings', escapeHtml(String(ht.personal_count)));
			html += row('Dynamic hotstrings', escapeHtml(String(ht.dynamic_count)));
			if (ht.default_delay !== undefined) {
				html += row('Default delay', escapeHtml(String(ht.default_delay)));
			}
			html += row('Magic key', escapeHtml(String(ht.magic_key)));
		}

		if (s.logs) {
			var lg = s.logs;
			var logVal = lg.unified_today
				? '<code>' + escapeHtml(String(lg.unified_today)) + '</code>'
				: '<em>n/a</em>';
			var errVal = lg.errors_today
				? '<code>' + escapeHtml(String(lg.errors_today)) + '</code>'
				: '<em>n/a</em>';
			html += row('Log (unified)', logVal);
			html += row('Log (errors)', errVal);
			html += row('Ring buffer lines', escapeHtml(String(lg.ring_lines || 0)));
		}

		html += '</table>';
	}

	// ── Adapters ─────────────────────────────────────────────────────────
	var wiredCount = s.wired_count;
	var adapterCount = s.adapter_count;
	var unwiredList = s.unwired_adapters || [];

	var adaptersLabel = 'Adapters (' + okList.length + '/' + total + ' OK';
	if (wiredCount !== undefined && adapterCount !== undefined) {
		adaptersLabel += ' — ' + wiredCount + '/' + adapterCount + ' wired';
	}
	adaptersLabel += ')';
	html += '<h2>' + adaptersLabel + '</h2>';

	var unwiredSet = {};
	unwiredList.forEach(function (name) { unwiredSet[name] = true; });

	html += '<ul>';
	okList.forEach(function (name) {
		if (unwiredSet[name]) {
			html += '<li><span class="unwired">~</span> <code>' + escapeHtml(String(name)) + '</code> <em>(contract-healthy, not wired into any feature)</em></li>';
		} else {
			html += '<li><span class="ok">&#x2713;</span> <code>' + escapeHtml(String(name)) + '</code></li>';
		}
	});
	failList.forEach(function (name) {
		html += '<li><span class="fail">&#x2717;</span> <code>' + escapeHtml(String(name)) + '</code></li>';
	});
	html += '</ul>';

	// ── Last error ───────────────────────────────────────────────────────
	html += '<h2>Last recorded error</h2>';
	if (lastErr) {
		html += '<pre>' + escapeHtml(String(lastErr)) + '</pre>';
	} else {
		html += '<em>No error recorded.</em>';
	}

	// ── Recent issues ────────────────────────────────────────────────────
	html += '<h2>Recent warnings / errors (' + issues.length + '/100)</h2>';
	if (issues.length === 0) {
		html += '<em>No warnings or errors since startup.</em>';
	} else {
		var lines = issues.map(function (l) { return escapeHtml(String(l)); }).join('\n');
		html += '<pre>' + lines + '</pre>';
	}

	document.getElementById('content').innerHTML = html;
};

/**
 * Starts the Linux request/response path after the renderer exists.
 *
 * Windows and macOS inject their snapshots directly after navigation. Linux
 * owns a page-scoped WebKit message handler instead, so it must request the
 * first snapshot and decode the native response. The host marker keeps this
 * path inert in the other two drivers.
 */
function startLinuxHealthcheckBridge() {
	if (window.__ergopti_host !== 'linux') {
		return;
	}

	var post = makeHostBridge('healthcheck');
	window.__hostBridgeResponse = function (bridge, isBase64, payload) {
		if (bridge !== 'healthcheck') {
			return;
		}
		var snapshot = decodeHostBridgeResponse(isBase64, payload);
		if (snapshot !== null) {
			window.renderHealthcheck(snapshot);
		}
	};
	window.refreshHealthcheck = function () {
		post({ action: 'refresh' });
	};
	post('ready');
}

startLinuxHealthcheckBridge();
