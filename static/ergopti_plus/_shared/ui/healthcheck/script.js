// _shared/ui/healthcheck/script.js

// ===========================================================================
// MODULE: Healthcheck Shared Renderer
// DESCRIPTION:
// Receives a diagnostic snapshot as JSON and renders the full report
// client-side.  Labels are in English: the report is read by whoever triages
// a problem, whatever the user's language.  Handles the Windows (AHK), macOS
// and Linux snapshot shapes; the OS-specific system rows are rendered
// conditionally based on which fields are present in the snapshot, and a
// generic row with no value is omitted rather than shown as "?".  The
// structural module check is a collapsed developer section at the end.
//
// Entry point:
//   window.renderHealthcheck(snapshot)
//     snapshot — the raw snapshot object produced by HealthCheck_Run()
//     on Windows, M.run() on macOS or the Linux bridge.  The top-level keys are:
//       version, sys, uptime_sec, warn_count, err_count,
//       ports_validated, failed_adapters,
//       disabled_adapters,                              (Linux only)
//       wired_count, adapter_count, unwired_adapters,  (macOS only)
//       event_tap_timeout_telemetry,                    (macOS only)
//       last_error, recent_issues, recent_issues_source,
//       pause_state, keylogger, llm, layout, hotstrings, logs, config,
//       remap                                           (macOS only)
//       permissions                                     (macOS only)
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
 * Renders a row only when its value is known. A "?" told the reader nothing a
 * missing row does not, and on Linux, whose snapshot has no screen probe, it
 * filled the table with question marks.
 * @param {string} field
 * @param {*} value Raw value; undefined, null and "" omit the row.
 * @returns {string}
 */
function optionalRow(field, value) {
	if (value === undefined || value === null || value === '') return '';
	return row(field, escapeHtml(String(value)));
}

/**
 * Renders one macOS privacy permission state; anything but "granted" is a
 * failure because the matching feature cannot work without it.
 * @param {string} state "granted", "missing", or "unknown (...)"
 * @returns {string} HTML-safe value
 */
function permissionValue(state) {
	var text = escapeHtml(String(state || 'unknown'));
	var cls = state === 'granted' ? 'ok' : 'fail';
	return '<span class="' + cls + '">' + text + '</span>';
}

/**
 * Renders the structural self-test as a collapsed developer section.
 *
 * It used to be an "Adapters (x/y OK — w/n wired)" heading listing every
 * module: three different checks on three drivers under one name, meaningless
 * to a user, and on Linux an AI feature that is simply off showed as a red
 * failure. The summary line still counts failures, so a collapsed section says
 * when something is wrong; failures are listed, passing modules sit behind a
 * nested disclosure, and optional modules that are off are neutral.
 * @param {object} s Snapshot.
 * @param {string[]} okList Modules that passed the contract check.
 * @param {string[]} failList Modules that failed it.
 * @param {number} total Modules checked.
 * @returns {string} HTML.
 */
function renderDeveloperDetails(s, okList, failList, total) {
	var disabledList = s.disabled_adapters || [];
	var summary = 'Developer details';
	if (failList.length > 0) {
		summary += ' &#x2014; <span class="fail">' + failList.length + ' module check failure(s)</span>';
	}
	var html = '<details class="developer"><summary>' + summary + '</summary>';

	html += '<h3>Module contract check (loaded + required functions present): '
		+ okList.length + '/' + total + ' OK</h3>';
	if (failList.length === 0) {
		html += '<p><span class="ok">&#x2713;</span> No failure.</p>';
	} else {
		html += '<ul>';
		failList.forEach(function (name) {
			html += '<li><span class="fail">&#x2717;</span> <code>' + escapeHtml(String(name)) + '</code></li>';
		});
		html += '</ul>';
	}
	if (disabledList.length > 0) {
		html += '<p>Optional modules that are not running (not a failure):</p><ul>';
		disabledList.forEach(function (name) {
			html += '<li><span class="disabled">&#x2013;</span> <code>' + escapeHtml(String(name))
				+ '</code> <em>(disabled)</em></li>';
		});
		html += '</ul>';
	}
	if (okList.length > 0) {
		html += '<details><summary>Show the ' + okList.length + ' passing module(s)</summary><ul>';
		okList.forEach(function (name) {
			html += '<li><span class="ok">&#x2713;</span> <code>' + escapeHtml(String(name)) + '</code></li>';
		});
		html += '</ul></details>';
	}

	// macOS only: a build-time fact kept honest by a meta test, not a probe
	if (s.wired_count !== undefined && s.adapter_count !== undefined) {
		var unwiredList = s.unwired_adapters || [];
		html += '<h3>Used by production code (verified at build time): '
			+ s.wired_count + '/' + s.adapter_count + '</h3>';
		if (unwiredList.length > 0) {
			html += '<ul>';
			unwiredList.forEach(function (name) {
				html += '<li><span class="unwired">~</span> <code>' + escapeHtml(String(name))
					+ '</code> <em>(no production caller)</em></li>';
			});
			html += '</ul>';
		}
	}
	return html + '</details>';
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
	// commit_source says whether the id comes from a package's build stamp or a
	// source checkout, so a release build and a dev run of it are told apart.
	var commit = String(sys.git_hash || 'unknown');
	if (sys.commit_source) commit += ' (' + String(sys.commit_source) + ')';
	html += row('Last git commit', escapeHtml(commit));
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
		if (s.permissions) {
			html += row('Accessibility', permissionValue(s.permissions.accessibility));
			html += row('Screen Recording', permissionValue(s.permissions.screen_recording));
		}
	} else if (sys.os === 'linux') {
		// Linux driver: the distribution, the kernel and the display stack are
		// what a Linux report is triaged by.
		html += optionalRow('Linux', sys.os_name);
		html += optionalRow('Kernel', sys.kernel);
		html += optionalRow('Architecture', sys.arch);
		var display = sys.display_server;
		if (display && sys.desktop) display += ' (' + sys.desktop + ')';
		html += optionalRow('Display server', display);
		html += optionalRow('Lua runtime', sys.runtime);
	}

	html += optionalRow('CPU', sys.cpu_name || sys.cpu_model);
	html += optionalRow('Logical cores', sys.cpu_cores);

	if (sys.ram_total_gb !== undefined) {
		// Windows format
		html += row('Total RAM', escapeHtml(String(sys.ram_total_gb) + ' GB'));
		html += row('Available RAM', escapeHtml(String(sys.ram_free_gb) + ' GB'));
	} else {
		// macOS and Linux format
		html += optionalRow('Total RAM', sys.ram_total);
		html += optionalRow('Available RAM', sys.ram_free);
	}

	html += optionalRow('Screen resolution', sys.screen_res);

	if (sys.dpi_scale !== undefined) {
		// Windows DPI
		html += row('DPI', escapeHtml(String(sys.dpi || '') + ' (' + String(sys.dpi_scale) + '%)'));
	} else if (sys.dpi !== undefined || sys.retina_scale) {
		// macOS: the DPI is absent when the physical size is unknown, and the
		// backing scale then stands alone rather than behind a "?".
		var dpiParts = [];
		if (sys.dpi !== undefined) dpiParts.push(escapeHtml(String(sys.dpi)));
		if (sys.retina_scale) dpiParts.push('<em>' + escapeHtml(String(sys.retina_scale)) + ' Retina</em>');
		html += row('DPI', dpiParts.join(' &nbsp;'));
	}

	html += optionalRow('Locale', sys.locale);

	if (sys.config_dir) {
		html += row('Config dir', '<code>' + escapeHtml(String(sys.config_dir)) + '</code>');
	}
	// Where the application runs from: inside a packaged app this is the
	// bundle, which is why it must never be presented as the config dir.
	if (sys.script_dir) {
		html += row('App dir', '<code>' + escapeHtml(String(sys.script_dir)) + '</code>');
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
	if (s.pause_state || s.layout || s.remap || s.llm || s.keylogger || s.hotstrings || s.logs) {
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

		// macOS only: the remap engine has no tray row, so a helper held until
		// Login Items approval is reported here as well as by a notification.
		if (s.remap) {
			var rm = s.remap;
			html += row('Remap engine', escapeHtml(String(rm.phase)));
			var approvalVal = rm.approval_required
				? '<span class="fail">required: System Settings &gt; General &gt; Login Items</span>'
				: '<span class="ok">' + escapeHtml(String(rm.guardian_status)) + '</span>';
			html += row('Login Items approval', approvalVal);
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
			var dirVal = lg.logs_dir
				? '<code>' + escapeHtml(String(lg.logs_dir)) + '</code>'
				: '<em>n/a</em>';
			var crashVal = lg.crash_reports_dir
				? '<code>' + escapeHtml(String(lg.crash_reports_dir)) + '</code>'
				: '<em>n/a</em>';
			html += row('Logs folder', dirVal);
			html += row('Log (unified)', logVal);
			html += row('Log (errors)', errVal);
			html += row('Crash reports', crashVal);
			html += row('Ring buffer lines', escapeHtml(String(lg.ring_lines || 0)));
		}

		html += '</table>';
	}


	// ── Last error ───────────────────────────────────────────────────────
	html += '<h2>Last recorded error</h2>';
	if (lastErr) {
		html += '<pre>' + escapeHtml(String(lastErr)) + '</pre>';
	} else {
		html += '<em>No error recorded.</em>';
	}

	// ── Recent issues ────────────────────────────────────────────────────
	// Read from today's errors file, which holds WARNING and ERROR only; the
	// in-memory ring, which DEBUG lines evict within minutes, is the fallback
	// before that file exists. The page says which one answered.
	var source = s.recent_issues_source;
	html += '<h2>Recent warnings / errors (' + issues.length + ')</h2>';
	if (source === 'errors_file') {
		html += '<p class="source">Newest entries of today&#x2019;s errors file.</p>';
	} else if (source === 'ring') {
		html += '<p class="source">From the in-memory log: today&#x2019;s errors file does not exist yet.</p>';
	} else if (source) {
		html += '<p class="source fail">The recent entries could not be read; see the log.</p>';
	}
	if (issues.length === 0) {
		html += '<em>' + (source === 'errors_file'
			? 'No warnings or errors today.'
			: 'No warnings or errors since startup.') + '</em>';
	} else {
		var lines = issues.map(function (l) { return escapeHtml(String(l)); }).join('\n');
		html += '<pre>' + lines + '</pre>';
	}

	// ── Developer details (collapsed, last) ──────────────────────────────
	html += renderDeveloperDetails(s, okList, failList, total);

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
