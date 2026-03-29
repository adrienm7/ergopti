// ui/metrics/script.js

window.metrics_manifest = window.metrics_manifest || {};
window.app_icons = window.app_icons || {};
window._lua_request = null;

const app_state = {
	data: { c: {}, bg: {}, tg: {}, qg: {}, pg: {}, hx: {}, hp: {}, w: {} },
	time_series: {},
	available_apps: [],
	selected_apps: new Set(),
	current_tab: 'c',
	sort_col: 'count',
	sort_asc: false,
	search_query: '',
	rendered_list: []
};

let chart_instance = null;

// ====================================
// ====================================
// ======= 1/ Formatting Helpers ======
// ====================================
// ====================================

/**
 * Escapes characters to prevent HTML injections.
 * @param {string} str - The target string.
 * @returns {string} The escaped string.
 */
function escape_html(str) {
	return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/**
 * Formats special characters for readability in the table.
 * @param {string} str - The target sequence.
 * @returns {string} The HTML formatted string.
 */
function format_display_key(str) {
	return escape_html(str)
		.replace(/\n/g, '<span style="color:var(--text-muted);">↵</span>')
		.replace(/ /g, '<span class="space-reg" title="Espace standard">␣</span>')
		.replace(/\u00A0/g, '<span class="space-nbsp" title="Espace insécable">NBSP</span>')
		.replace(/\u202F/g, '<span class="space-nnbsp" title="Espace fine insécable">NNBSP</span>');
}

/**
 * Procedurally generates a color based on application name.
 * @param {string} appName - The target app.
 * @returns {string} A CSS valid HSL color.
 */
function get_app_color(appName) {
	let hash = 0;
	for (let i = 0; i < appName.length; i++) hash = appName.charCodeAt(i) + ((hash << 5) - hash);
	return `hsl(${Math.abs(hash) % 360}, 65%, 55%)`;
}

// ====================================
// ====================================
// ======= 2/ Data Pipeline ===========
// ====================================
// ====================================

/**
 * Merges raw dictionary from Lua applying active UI filters.
 * @param {Object} target - The mutated destination dictionary.
 * @param {Object} source - The chunk to merge.
 * @param {boolean} case_sensitive - The filter state.
 * @param {boolean} hide_spaces - The filter state.
 * @param {boolean} hide_hs - The filter state.
 * @param {boolean} hide_llm - The filter state.
 */
function merge_dict(target, source, case_sensitive, hide_spaces, hide_hs, hide_llm) {
	if (!source || typeof source !== 'object') return;

	Object.keys(source).forEach((k) => {
		let display_k = case_sensitive ? k : k.toLowerCase();
		if (
			hide_spaces &&
			(display_k.includes(' ') || display_k.includes('\u00A0') || display_k.includes('\u202F'))
		)
			return;

		let item = source[k];
		let real_count = item.c;
		if (hide_hs) real_count -= item.hs;
		if (hide_llm) real_count -= item.llm;
		if (real_count <= 0) return;

		if (!target[display_k]) {
			target[display_k] = {
				count: 0,
				time: 0,
				errors: 0,
				synth_hs: 0,
				synth_llm: 0,
				synth_other: 0
			};
		}
		target[display_k].count += real_count;
		target[display_k].time += item.t;
		target[display_k].errors += item.e;
		target[display_k].synth_hs += item.hs;
		target[display_k].synth_llm += item.llm;
		target[display_k].synth_other += item.o;
	});
}

/**
 * Instantly triggered on load to build charts without loading raw sequences.
 */
function process_manifest() {
	if (app_state.available_apps.length === 0 && Object.keys(window.metrics_manifest).length > 0) {
		const appSet = new Set();
		Object.keys(window.metrics_manifest).forEach((date) => {
			Object.keys(window.metrics_manifest[date]).forEach((appName) => {
				if (appName !== 'Unknown') appSet.add(appName);
			});
		});

		app_state.available_apps = Array.from(appSet).sort((a, b) => a.localeCompare(b));
		if (app_state.selected_apps.size === 0) {
			app_state.available_apps.forEach((app) => app_state.selected_apps.add(app));
		}

		const start_input = document.getElementById('date_start');
		if (start_input && !start_input.value) {
			const one_month_ago = new Date();
			one_month_ago.setMonth(one_month_ago.getMonth() - 1);
			start_input.value = one_month_ago.toISOString().split('T')[0];
		}
		const end_input = document.getElementById('date_end');
		if (end_input && !end_input.value) {
			end_input.value = new Date().toISOString().split('T')[0];
		}
	}

	update_app_btn_text();
	compute_manifest_metrics();
	request_range_data();
}

/**
 * Redraws the chart and global stats from the tiny manifest based on active dates.
 */
function compute_manifest_metrics() {
	app_state.time_series = {};
	let global_chars = 0;
	let global_time_ms = 0;
	let total_sentences = 0;
	let total_sentence_time = 0;
	let total_sentence_chars = 0;

	const start_val = document.getElementById('date_start').value;
	const end_val = document.getElementById('date_end').value;
	const hide_hs = document.getElementById('hide_hs') && document.getElementById('hide_hs').checked;
	const hide_llm =
		document.getElementById('hide_llm') && document.getElementById('hide_llm').checked;

	Object.keys(window.metrics_manifest).forEach((dateStr) => {
		if (start_val && dateStr < start_val) return;
		if (end_val && dateStr > end_val) return;

		const dayData = window.metrics_manifest[dateStr];
		Object.keys(dayData).forEach((appName) => {
			if (appName !== 'Unknown' && !app_state.selected_apps.has(appName)) return;
			const app = dayData[appName];

			if (!app_state.time_series[dateStr])
				app_state.time_series[dateStr] = { chars: 0, time_ms: 0 };

			global_chars += app.chars;
			global_time_ms += app.time;
			app_state.time_series[dateStr].chars += app.chars;
			app_state.time_series[dateStr].time_ms += app.time;

			total_sentences += app.sent;
			total_sentence_time += app.sent_time;
			total_sentence_chars += app.sent_chars;
		});
	});

	let summary_title =
		hide_hs && hide_llm ? 'Résumé des frappes manuelles' : 'Résumé global des frappes';
	const wpm = global_time_ms > 0 ? (global_chars / 5 / (global_time_ms / 60000)).toFixed(1) : 0;

	const sorted_keys = Object.keys(app_state.time_series).sort();
	const valid_wpm_points = sorted_keys
		.map((k) => {
			const d = app_state.time_series[k];
			return d.chars >= 10 && d.time_ms > 0 ? d.chars / 5 / (d.time_ms / 60000) : 0;
		})
		.filter((pt) => pt > 0);

	let trend_html = '';
	if (valid_wpm_points.length >= 2) {
		const half = Math.floor(valid_wpm_points.length / 2);
		const first_half = valid_wpm_points.slice(0, valid_wpm_points.length - half);
		const second_half = valid_wpm_points.slice(valid_wpm_points.length - half);

		const avg1 = first_half.reduce((a, b) => a + b, 0) / Math.max(1, first_half.length);
		const avg2 = second_half.reduce((a, b) => a + b, 0) / Math.max(1, second_half.length);

		if (avg2 > avg1 * 1.05)
			trend_html = '<span style="color: #34c759;" title="Tendance à la hausse (lissé)">📈</span>';
		else if (avg2 < avg1 * 0.95)
			trend_html = '<span style="color: #ff3b30;" title="Tendance à la baisse (lissé)">📉</span>';
		else trend_html = '<span style="color: #ffcc00;" title="Vitesse stable (lissé)">➡️</span>';
	}

	document.getElementById('global_stats').innerHTML = `
		<h2>${summary_title}</h2>
		<div style="font-size: 3em; font-weight: bold; color: var(--accent); margin: 10px 0; display: flex; align-items: baseline; gap: 8px; flex-wrap: wrap;">
			${wpm} <span style="font-size: 0.6em;">MPM</span> 
			<span style="font-size: 0.35em; color: var(--text-color); font-weight: normal;">(Mots par minute)</span>
			<span style="font-size: 0.7em; margin-left: auto;">${trend_html}</span>
		</div>
		<p><strong>Volume total tapé :</strong> ${global_chars.toLocaleString()} caractères</p>
	`;

	const avg_sent_len =
		total_sentences > 0 ? (total_sentence_chars / total_sentences).toFixed(1) : 0;
	const avg_sent_time =
		total_sentences > 0 ? (total_sentence_time / total_sentences / 1000).toFixed(2) : 0;
	document.getElementById('sentence_stats').innerHTML = `
		<h2>Métriques de phrases</h2>
		<p><strong>Longueur moyenne :</strong> ${avg_sent_len} caractères</p>
		<p><strong>Temps moyen d’écriture :</strong> ${avg_sent_time} s</p>
	`;

	render_chart();
}

/**
 * Triggers the Lua polling variable to start unpacking the massive indices in background.
 */
function request_range_data() {
	const req = {
		start_date: document.getElementById('date_start').value,
		end_date: document.getElementById('date_end').value,
		apps: Array.from(app_state.selected_apps)
	};
	document.getElementById('metrics_table_body').innerHTML =
		'<tr><td colspan="6" style="text-align:center; color:var(--text-muted); padding: 30px;">Chargement des données en cours... Veuillez patienter.</td></tr>';
	window._lua_request = JSON.stringify(req);
}

/**
 * Callbacked by Lua to dump the unzipped dictionaries into UI.
 * @param {Object} raw_data - Unfiltered massive dictionary.
 */
function receive_range_data(raw_data) {
	app_state.data = { c: {}, bg: {}, tg: {}, qg: {}, pg: {}, hx: {}, hp: {}, w: {} };

	const hide_hs = document.getElementById('hide_hs') && document.getElementById('hide_hs').checked;
	const hide_llm =
		document.getElementById('hide_llm') && document.getElementById('hide_llm').checked;
	const hide_spaces =
		document.getElementById('hide_spaces') && document.getElementById('hide_spaces').checked;
	const case_sensitive =
		document.getElementById('case_sensitive') && document.getElementById('case_sensitive').checked;

	merge_dict(app_state.data.c, raw_data.c, case_sensitive, hide_spaces, hide_hs, hide_llm);
	merge_dict(app_state.data.bg, raw_data.bg, case_sensitive, hide_spaces, hide_hs, hide_llm);
	merge_dict(app_state.data.tg, raw_data.tg, case_sensitive, hide_spaces, hide_hs, hide_llm);
	merge_dict(app_state.data.qg, raw_data.qg, case_sensitive, hide_spaces, hide_hs, hide_llm);
	merge_dict(app_state.data.pg, raw_data.pg, case_sensitive, hide_spaces, hide_hs, hide_llm);
	merge_dict(app_state.data.hx, raw_data.hx, case_sensitive, hide_spaces, hide_hs, hide_llm);
	merge_dict(app_state.data.hp, raw_data.hp, case_sensitive, hide_spaces, hide_hs, hide_llm);
	merge_dict(app_state.data.w, raw_data.w, case_sensitive, hide_spaces, hide_hs, hide_llm);

	render_current_tab();
}

/**
 * Resets visual and Lua queries based on inputs.
 */
function apply_filters() {
	compute_manifest_metrics();
	request_range_data();
}

/**
 * Clears parameters entirely.
 */
function reset_filters() {
	document.getElementById('date_start').value = '';
	document.getElementById('date_end').value = '';
	document.getElementById('hide_spaces').checked = false;
	document.getElementById('hide_hs').checked = false;
	document.getElementById('hide_llm').checked = false;
	document.getElementById('case_sensitive').checked = false;

	app_state.available_apps.forEach((app) => app_state.selected_apps.add(app));
	update_app_btn_text();
	apply_filters();
}

// ====================================
// ====================================
// ======= 3/ Modal Management ========
// ====================================
// ====================================

function update_app_btn_text() {
	const btn = document.getElementById('app_filter_btn');
	if (!btn) return;
	const sel = app_state.selected_apps.size;
	const tot = app_state.available_apps.length;
	if (sel === tot) btn.innerText = 'Apps (Toutes)';
	else if (sel === 0) btn.innerText = 'Apps (Aucune)';
	else btn.innerText = `Apps (${sel}/${tot})`;
}

function open_app_modal() {
	document.getElementById('app_search').value = '';
	render_app_list();
	document.getElementById('app_modal').style.display = 'flex';
	document.getElementById('app_search').focus();
}

function close_app_modal() {
	document.getElementById('app_modal').style.display = 'none';
	update_app_btn_text();
	apply_filters();
}

function select_all_apps() {
	app_state.available_apps.forEach((app) => app_state.selected_apps.add(app));
	render_app_list();
}

function deselect_all_apps() {
	app_state.selected_apps.clear();
	render_app_list();
}

function toggle_app_selection(checkbox) {
	if (checkbox.checked) app_state.selected_apps.add(checkbox.value);
	else app_state.selected_apps.delete(checkbox.value);
}

function render_app_list() {
	const query = document.getElementById('app_search').value.toLowerCase();
	const container = document.getElementById('app_list');
	let html = '';
	app_state.available_apps.forEach((app) => {
		if (app.toLowerCase().includes(query)) {
			const checked = app_state.selected_apps.has(app) ? 'checked' : '';

			let icon_html = '';
			if (window.app_icons && window.app_icons[app]) {
				icon_html = `<img src="${window.app_icons[app]}" class="app-icon-img" alt="${escape_html(app)}" />`;
			} else {
				const color = get_app_color(app);
				const initial = app.charAt(0).toUpperCase();
				icon_html = `<div class="app-icon-div" style="background-color: ${color}">${initial}</div>`;
			}

			html += `
			<label class="app-item">
				<input type="checkbox" value="${escape_html(app)}" ${checked} onchange="toggle_app_selection(this)">
				<div class="app-icon-wrapper">${icon_html}</div>
				<span class="app-name">${escape_html(app)}</span>
			</label>
			`;
		}
	});
	if (html === '')
		html =
			'<div style="padding: 15px; color: var(--text-muted); text-align: center;">Aucune application trouvée</div>';
	container.innerHTML = html;
}

// ====================================
// ====================================
// ======= 4/ Chart Rendering =========
// ====================================
// ====================================

function render_chart() {
	const ctx = document.getElementById('wpm_chart').getContext('2d');
	const sorted_keys = Object.keys(app_state.time_series).sort();
	const data_points = sorted_keys
		.map((k) => {
			const d = app_state.time_series[k];
			let wpm = d.chars >= 10 && d.time_ms > 0 ? d.chars / 5 / (d.time_ms / 60000) : 0;
			return { x: new Date(k + 'T12:00:00'), y: wpm };
		})
		.filter((pt) => pt.y > 0);

	if (chart_instance) chart_instance.destroy();

	chart_instance = new Chart(ctx, {
		type: 'line',
		data: {
			datasets: [
				{
					label: 'Vitesse (MPM)',
					data: data_points,
					borderColor: '#007aff',
					backgroundColor: 'rgba(0, 122, 255, 0.2)',
					borderWidth: 2,
					tension: 0.3,
					fill: true,
					pointRadius: 4
				}
			]
		},
		options: {
			responsive: true,
			maintainAspectRatio: false,
			plugins: {
				legend: { display: false },
				tooltip: { callbacks: { label: (ctx) => `${ctx.parsed.y.toFixed(1)} MPM` } },
				zoom: {
					pan: { enabled: true, mode: 'x' },
					zoom: { wheel: { enabled: true }, pinch: { enabled: true }, mode: 'x' }
				}
			},
			scales: {
				x: {
					type: 'time',
					time: {
						unit: 'day',
						tooltipFormat: 'dd MMM yyyy',
						displayFormats: { day: 'd MMM', week: 'd MMM', month: 'MMM yyyy' }
					},
					grid: {
						color: (context) =>
							context.tick && context.tick.major
								? 'rgba(128, 128, 128, 0.5)'
								: 'rgba(128, 128, 128, 0.2)',
						lineWidth: (context) => (context.tick && context.tick.major ? 2 : 1)
					},
					ticks: { major: { enabled: true } }
				},
				y: {
					beginAtZero: true,
					grid: { color: 'rgba(128, 128, 128, 0.2)' },
					title: { display: true, text: 'MPM' }
				}
			}
		}
	});
}

// ====================================
// ====================================
// ======= 5/ Table Rendering =========
// ====================================
// ====================================

function switch_tab(tab_name) {
	app_state.current_tab = tab_name;
	document.querySelectorAll('.tabs .tab-btn').forEach((btn) => btn.classList.remove('active'));
	document.querySelector(`[onclick="switch_tab('${tab_name}')"]`).classList.add('active');
	app_state.sort_col = 'count';
	app_state.sort_asc = false;
	document.getElementById('search_input').value = '';
	app_state.search_query = '';
	render_current_tab();
}

function handle_search() {
	app_state.search_query = document.getElementById('search_input').value.toLowerCase();
	render_table();
}

function handle_sort(col_name) {
	if (app_state.sort_col === col_name) {
		app_state.sort_asc = !app_state.sort_asc;
	} else {
		app_state.sort_col = col_name;
		app_state.sort_asc = col_name === 'key';
	}
	render_table();
}

function render_current_tab() {
	const source_dict = app_state.data[app_state.current_tab];
	let filtered_total = 0;
	let data_arr = [];

	Object.keys(source_dict).forEach((k) => {
		const item = source_dict[k];
		const manual_count = item.count - item.synth_hs - item.synth_llm - item.synth_other;
		const avg = manual_count > 0 ? item.time / manual_count : 0;

		let seq_length =
			app_state.current_tab === 'w'
				? Array.from(k).length
				: app_state.current_tab === 'hp'
					? 7
					: app_state.current_tab === 'hx'
						? 6
						: app_state.current_tab === 'pg'
							? 5
							: app_state.current_tab === 'qg'
								? 4
								: app_state.current_tab === 'tg'
									? 3
									: app_state.current_tab === 'bg'
										? 2
										: 1;

		let wpm = avg > 0 ? seq_length / 5 / (avg / 60000) : 0;
		let acc = item.count > 0 ? ((item.count - item.errors) / item.count) * 100 : 0;

		filtered_total += item.count;

		data_arr.push({
			key: k,
			count: item.count,
			synth_hs: item.synth_hs,
			synth_llm: item.synth_llm,
			synth_other: item.synth_other,
			avg: avg,
			wpm: wpm < 800 ? wpm : 0,
			acc: Math.max(0, acc)
		});
	});

	data_arr.forEach((i) => {
		i.freq = filtered_total > 0 ? (i.count / filtered_total) * 100 : 0;
	});

	document.getElementById('total_occurrences').innerText = `(${filtered_total.toLocaleString()})`;
	app_state.rendered_list = data_arr.filter((i) => i.count >= 2);

	render_table();
}

function render_table() {
	let arr = [...app_state.rendered_list];
	if (app_state.search_query)
		arr = arr.filter((i) => i.key.toLowerCase().includes(app_state.search_query));

	arr.sort((a, b) => {
		let val_a = a[app_state.sort_col],
			val_b = b[app_state.sort_col];
		if (typeof val_a === 'string')
			return app_state.sort_asc ? val_a.localeCompare(val_b) : val_b.localeCompare(val_a);
		return app_state.sort_asc ? val_a - val_b : val_b - val_a;
	});

	const tbody = document.getElementById('metrics_table_body');
	let html = '';
	arr.slice(0, 1000).forEach((item) => {
		let synth_details = [];
		if (item.synth_hs > 0) synth_details.push(`${item.synth_hs.toLocaleString()} HS`);
		if (item.synth_llm > 0) synth_details.push(`${item.synth_llm.toLocaleString()} IA`);
		if (item.synth_other > 0) synth_details.push(`${item.synth_other.toLocaleString()} Autres`);

		let synth_html =
			synth_details.length > 0
				? `<br><span style="font-size:10px; color:var(--text-muted);">(dont ${synth_details.join(', ')})</span>`
				: '';
		let display_key = format_display_key(item.key);

		html += `
			<tr>
				<td><span class="mono-space">${display_key}</span></td>
				<td>${item.count.toLocaleString()} ${synth_html}</td>
				<td>${item.freq.toFixed(2)} %</td>
				<td>${item.avg > 0 ? item.avg.toFixed(1) + ' ms' : '<span style="color:var(--text-muted)">-</span>'}</td>
				<td><strong style="color: ${item.wpm > 60 ? '#34c759' : item.wpm > 0 && item.wpm < 30 ? '#ff3b30' : item.wpm === 0 ? 'var(--text-muted)' : 'inherit'}">${item.wpm > 0 ? item.wpm.toFixed(1) + ' MPM' : '-'}</strong></td>
				<td><strong style="color: ${item.acc >= 95 ? '#34c759' : item.acc < 80 ? '#ff3b30' : '#ffcc00'}">${item.acc.toFixed(1)} %</strong></td>
			</tr>`;
	});

	if (arr.length === 0)
		html =
			'<tr><td colspan="6" style="text-align:center; color:var(--text-muted);">Aucune donnée</td></tr>';
	tbody.innerHTML = html;
}

// Bindings to Window
window.process_manifest = process_manifest;
window.apply_filters = apply_filters;
window.reset_filters = reset_filters;
window.switch_tab = switch_tab;
window.handle_search = handle_search;
window.handle_sort = handle_sort;
window.open_app_modal = open_app_modal;
window.close_app_modal = close_app_modal;
window.select_all_apps = select_all_apps;
window.deselect_all_apps = deselect_all_apps;
window.toggle_app_selection = toggle_app_selection;
window.render_app_list = render_app_list;
window.receive_range_data = receive_range_data;
