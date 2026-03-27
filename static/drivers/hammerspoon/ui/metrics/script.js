// ui/metrics/script.js

window.log_lines = window.log_lines || [];
window.parsed_logs = [];

// ====================================
// ====================================
// ======= 1/ State & Helpers =========
// ====================================
// ====================================

const app_state = {
	data: {
		chars: {},
		bigrams: {},
		trigrams: {},
		quadrigrams: {},
		pentagrams: {},
		hexagrams: {},
		heptagrams: {},
		words: {}
	},
	totals: {
		chars: 0,
		bigrams: 0,
		trigrams: 0,
		quadrigrams: 0,
		pentagrams: 0,
		hexagrams: 0,
		heptagrams: 0,
		words: 0
	},
	time_series: {},
	current_tab: 'chars',
	sort_col: 'count',
	sort_asc: false,
	search_query: '',
	rendered_list: []
};

let chart_instance = null;

function add_metric(dict, key, delay_ms, is_error = false, is_synth = false) {
	// Track metrics and handle synthetic counts to exclude them from speed calculations
	if (!dict[key]) dict[key] = { count: 0, synth_count: 0, time: 0, errors: 0 };
	if (is_error) {
		dict[key].errors++;
	} else {
		dict[key].count++;
		if (is_synth) {
			dict[key].synth_count++;
		} else if (delay_ms > 0) {
			dict[key].time += delay_ms;
		}
	}
}

function escape_html(str) {
	return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function format_display_key(str) {
	// Securely format the string, replacing newlines and mapping exact space types to visual badges
	return escape_html(str)
		.replace(/\n/g, '<span style="color:#666;">↵</span>')
		.replace(/ /g, '<span class="space-reg" title="Espace standard">␣</span>')
		.replace(/\u00A0/g, '<span class="space-nbsp" title="Espace insécable">NBSP</span>')
		.replace(/\u202F/g, '<span class="space-nnbsp" title="Espace fine insécable">NNBSP</span>');
}

// ====================================
// ====================================
// ======= 2/ Data Processing =========
// ====================================
// ====================================

function process_logs() {
	// Parse the JSON only once to optimize loading times
	if (window.parsed_logs.length === 0 && window.log_lines.length > 0) {
		window.log_lines.forEach((line) => {
			try {
				const entry = JSON.parse(line);
				if (entry.timestamp) {
					entry.date_obj = new Date(entry.timestamp.replace(' ', 'T'));
					window.parsed_logs.push(entry);
				}
			} catch (e) {
				// Silently ignore corrupted log lines
			}
		});

		// By default, restrict parsing to the last month
		const start_input = document.getElementById('date_start');
		if (start_input && !start_input.value) {
			const one_month_ago = new Date();
			one_month_ago.setMonth(one_month_ago.getMonth() - 1);
			start_input.value = one_month_ago.toISOString().split('T')[0];
		}
	}
	compute_metrics();
}

function compute_metrics() {
	// Reset the state objects to process filtered data
	app_state.data = {
		chars: {},
		bigrams: {},
		trigrams: {},
		quadrigrams: {},
		pentagrams: {},
		hexagrams: {},
		heptagrams: {},
		words: {}
	};
	app_state.totals = {
		chars: 0,
		bigrams: 0,
		trigrams: 0,
		quadrigrams: 0,
		pentagrams: 0,
		hexagrams: 0,
		heptagrams: 0,
		words: 0
	};
	app_state.time_series = {};

	let global_chars = 0;
	let global_time_ms = 0;
	let total_sentences = 0;
	let total_sentence_time = 0;
	let total_sentence_chars = 0;

	const delay_input = document.getElementById('max_delay');
	const max_valid_delay = delay_input && delay_input.value ? parseInt(delay_input.value) : 99999999;

	const start_val = document.getElementById('date_start').value;
	const end_val = document.getElementById('date_end').value;
	const start_date = start_val ? new Date(start_val + 'T00:00:00') : null;
	const end_date = end_val ? new Date(end_val + 'T23:59:59') : null;

	window.parsed_logs.forEach((entry) => {
		if (start_date && entry.date_obj < start_date) return;
		if (end_date && entry.date_obj > end_date) return;

		const date_hour = entry.timestamp.substring(0, 13) + ':00:00';
		if (!app_state.time_series[date_hour]) {
			app_state.time_series[date_hour] = { chars: 0, time_ms: 0 };
		}

		// Flawless hotstring and LLM reconstruction
		let unified_events = [];
		if (entry.type === 'typing' && entry.events) {
			entry.events.forEach((ev) =>
				unified_events.push({
					char: ev[0],
					delay: ev[1],
					is_synth: (ev[2] || {}).s || false,
					is_bs: ev[0] === '[BS]'
				})
			);
		} else if (entry.type === 'hotstring') {
			if (entry.trigger)
				for (let i = 0; i < Array.from(entry.trigger).length; i++)
					unified_events.push({ char: '[BS]', delay: 0, is_synth: true, is_bs: true });
			if (entry.replacement)
				for (let c of Array.from(entry.replacement))
					unified_events.push({ char: c, delay: 0, is_synth: true, is_bs: false });
		} else if (entry.type === 'llm_generation') {
			if (entry.deletes && entry.deletes > 0)
				for (let i = 0; i < entry.deletes; i++)
					unified_events.push({ char: '[BS]', delay: 0, is_synth: true, is_bs: true });
			if (entry.predictions && entry.predictions[0])
				for (let c of Array.from(entry.predictions[0]))
					unified_events.push({ char: c, delay: 0, is_synth: true, is_bs: false });
		}

		let prev1 = null,
			prev2 = null,
			prev3 = null,
			prev4 = null,
			prev5 = null,
			prev6 = null;
		let current_word_final = '',
			current_word_time = 0;
		let word_has_error = false,
			word_is_synth = false,
			word_has_timeout = false;
		let history = [],
			entry_time = 0,
			entry_chars = 0;

		unified_events.forEach((ev) => {
			if (ev.is_bs) {
				if (history.length > 0) {
					let last = history.pop();
					if (last.c) add_metric(app_state.data.chars, last.c, 0, true);
					if (last.bg) add_metric(app_state.data.bigrams, last.bg, 0, true);
					if (last.tg) add_metric(app_state.data.trigrams, last.tg, 0, true);
					if (last.qg) add_metric(app_state.data.quadrigrams, last.qg, 0, true);
					if (last.pg) add_metric(app_state.data.pentagrams, last.pg, 0, true);
					if (last.hx) add_metric(app_state.data.hexagrams, last.hx, 0, true);
					if (last.hp) add_metric(app_state.data.heptagrams, last.hp, 0, true);
				}
				word_has_error = true;
				// Array.from securely removes a single multi-byte string/emoji character
				let arr = Array.from(current_word_final);
				if (arr.length > 0) {
					arr.pop();
					current_word_final = arr.join('');
				}
				return;
			}

			// Raw character kept intact for accurate regex checking later
			let c_key = ev.char;
			let bg_key = prev1 ? prev1 + c_key : null;
			let tg_key = prev2 ? prev2 + prev1 + c_key : null;
			let qg_key = prev3 ? prev3 + prev2 + prev1 + c_key : null;
			let pg_key = prev4 ? prev4 + prev3 + prev2 + prev1 + c_key : null;
			let hx_key = prev5 ? prev5 + prev4 + prev3 + prev2 + prev1 + c_key : null;
			let hp_key = prev6 ? prev6 + prev5 + prev4 + prev3 + prev2 + prev1 + c_key : null;

			let h_obj = {};

			if (ev.is_synth || (ev.delay >= 0 && ev.delay < max_valid_delay)) {
				add_metric(app_state.data.chars, c_key, ev.delay, false, ev.is_synth);
				app_state.totals.chars++;
				h_obj.c = c_key;
				if (bg_key) {
					add_metric(app_state.data.bigrams, bg_key, ev.delay, false, ev.is_synth);
					app_state.totals.bigrams++;
					h_obj.bg = bg_key;
				}
				if (tg_key) {
					add_metric(app_state.data.trigrams, tg_key, ev.delay, false, ev.is_synth);
					app_state.totals.trigrams++;
					h_obj.tg = tg_key;
				}
				if (qg_key) {
					add_metric(app_state.data.quadrigrams, qg_key, ev.delay, false, ev.is_synth);
					app_state.totals.quadrigrams++;
					h_obj.qg = qg_key;
				}
				if (pg_key) {
					add_metric(app_state.data.pentagrams, pg_key, ev.delay, false, ev.is_synth);
					app_state.totals.pentagrams++;
					h_obj.pg = pg_key;
				}
				if (hx_key) {
					add_metric(app_state.data.hexagrams, hx_key, ev.delay, false, ev.is_synth);
					app_state.totals.hexagrams++;
					h_obj.hx = hx_key;
				}
				if (hp_key) {
					add_metric(app_state.data.heptagrams, hp_key, ev.delay, false, ev.is_synth);
					app_state.totals.heptagrams++;
					h_obj.hp = hp_key;
				}

				if (!ev.is_synth) {
					global_chars++;
					global_time_ms += ev.delay;
					app_state.time_series[date_hour].chars++;
					app_state.time_series[date_hour].time_ms += ev.delay;
					entry_time += ev.delay;
					entry_chars++;
				}
			} else {
				if (!ev.is_synth && ev.delay >= max_valid_delay) word_has_timeout = true;
			}

			history.push(h_obj);

			if (ev.char.match(/[\s.,!?;:'"()\[\]{}\n\r]/)) {
				if (Array.from(current_word_final).length >= 2 && !word_has_timeout) {
					add_metric(
						app_state.data.words,
						current_word_final,
						current_word_time,
						false,
						word_is_synth
					);
					if (word_has_error)
						add_metric(app_state.data.words, current_word_final, 0, true, word_is_synth);
					app_state.totals.words++;
				}
				current_word_final = '';
				current_word_time = 0;
				word_has_error = false;
				word_is_synth = false;
				word_has_timeout = false;
			} else {
				current_word_final += ev.char.toLowerCase();
				if (ev.is_synth) word_is_synth = true;
				if (!ev.is_synth && Array.from(current_word_final).length > 1) {
					if (ev.delay >= 0 && ev.delay < max_valid_delay) current_word_time += ev.delay;
					else word_has_timeout = true;
				}
			}

			prev6 = prev5;
			prev5 = prev4;
			prev4 = prev3;
			prev3 = prev2;
			prev2 = prev1;
			prev1 = c_key;
		});

		if (Array.from(current_word_final).length >= 2 && !word_has_timeout) {
			add_metric(app_state.data.words, current_word_final, current_word_time, false, word_is_synth);
			if (word_has_error)
				add_metric(app_state.data.words, current_word_final, 0, true, word_is_synth);
			app_state.totals.words++;
		}

		if (entry_chars > 0 && entry.type === 'typing') {
			total_sentences++;
			total_sentence_time += entry_time;
			total_sentence_chars += entry_chars;
		}
	});

	const wpm = global_time_ms > 0 ? (global_chars / 5 / (global_time_ms / 60000)).toFixed(1) : 0;
	document.getElementById('global_stats').innerHTML = `
		<h2>Résumé des frappes manuelles</h2>
		<div style="font-size: 3em; font-weight: bold; color: var(--accent); margin: 10px 0;">
			${wpm} <span style="font-size: 0.35em; color: var(--text-color);">MPM (Mots Par Minute)</span>
		</div>
		<p><strong>Volume total tapé :</strong> ${global_chars.toLocaleString()} caractères</p>
	`;

	const avg_sent_len =
		total_sentences > 0 ? (total_sentence_chars / total_sentences).toFixed(1) : 0;
	const avg_sent_time =
		total_sentences > 0 ? (total_sentence_time / total_sentences / 1000).toFixed(2) : 0;
	document.getElementById('sentence_stats').innerHTML = `
		<h2>Métriques de Phrases</h2>
		<p><strong>Longueur moyenne :</strong> ${avg_sent_len} caractères</p>
		<p><strong>Temps moyen d'écriture :</strong> ${avg_sent_time} s</p>
	`;

	render_chart();
	render_current_tab();
}

function apply_filters() {
	compute_metrics();
}

function reset_filters() {
	document.getElementById('date_start').value = '';
	document.getElementById('date_end').value = '';

	const delay_input = document.getElementById('max_delay');
	if (delay_input) delay_input.value = '5000'; // Default to 5s

	document.getElementById('hide_spaces').checked = false;
	document.getElementById('hide_synth').checked = false;
	compute_metrics();
}

// ====================================
// ====================================
// ======= 3/ Chart Rendering =========
// ====================================
// ====================================

function render_chart() {
	const ctx = document.getElementById('wpm_chart').getContext('2d');
	const sorted_keys = Object.keys(app_state.time_series).sort();
	const data_points = sorted_keys
		.map((k) => {
			const d = app_state.time_series[k];
			let wpm = d.chars >= 10 && d.time_ms > 0 ? d.chars / 5 / (d.time_ms / 60000) : 0;
			return { x: new Date(k.replace(' ', 'T')), y: wpm };
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
					pointRadius: 3
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
				x: { type: 'time', time: { tooltipFormat: 'dd MMM yyyy HH:mm' }, grid: { color: '#444' } },
				y: { beginAtZero: true, grid: { color: '#444' }, title: { display: true, text: 'MPM' } }
			}
		}
	});
}

// ====================================
// ====================================
// ======= 4/ Table Rendering =========
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
	const hide_spaces = document.getElementById('hide_spaces').checked;
	const hide_synth = document.getElementById('hide_synth').checked;

	let filtered_total = 0;
	let data_arr = [];

	Object.keys(source_dict).forEach((k) => {
		const item = source_dict[k];

		// Apply newly requested filters
		if (hide_spaces && (k.includes(' ') || k.includes('\u00A0') || k.includes('\u202F'))) return;
		if (hide_synth && item.synth_count === item.count) return;

		const real_count = item.count - item.synth_count;
		const avg = real_count > 0 ? item.time / real_count : 0;

		let seq_length =
			app_state.current_tab === 'words'
				? Array.from(k).length
				: app_state.current_tab === 'heptagrams'
					? 7
					: app_state.current_tab === 'hexagrams'
						? 6
						: app_state.current_tab === 'pentagrams'
							? 5
							: app_state.current_tab === 'quadrigrams'
								? 4
								: app_state.current_tab === 'trigrams'
									? 3
									: app_state.current_tab === 'bigrams'
										? 2
										: 1;

		let wpm = avg > 0 ? seq_length / 5 / (avg / 60000) : 0;
		let acc = item.count > 0 ? ((item.count - item.errors) / item.count) * 100 : 0;

		filtered_total += item.count;

		data_arr.push({
			key: k,
			count: item.count,
			synth_count: item.synth_count,
			avg: avg,
			wpm: wpm < 800 ? wpm : 0,
			acc: Math.max(0, acc)
		});
	});

	// Recalculate relative frequency based on the filtered set
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
		let synth_html =
			item.synth_count > 0
				? `<br><span style="font-size:10px; color:#aaa;">(dont ${item.synth_count.toLocaleString()} Auto)</span>`
				: '';

		// Map special spaces exclusively during the visual render phase
		let display_key = format_display_key(item.key);

		html += `
			<tr>
				<td><span class="mono-space">${display_key}</span></td>
				<td>${item.count.toLocaleString()} ${synth_html}</td>
				<td>${item.freq.toFixed(2)} %</td>
				<td>${item.avg > 0 ? item.avg.toFixed(1) : '<span style="color:#666">-</span>'}</td>
				<td><strong style="color: ${item.wpm > 60 ? '#34c759' : item.wpm > 0 && item.wpm < 30 ? '#ff3b30' : item.wpm === 0 ? '#666' : 'inherit'}">${item.wpm > 0 ? item.wpm.toFixed(1) : '-'}</strong></td>
				<td><strong style="color: ${item.acc >= 95 ? '#34c759' : item.acc < 80 ? '#ff3b30' : '#ffcc00'}">${item.acc.toFixed(1)} %</strong></td>
			</tr>`;
	});

	if (arr.length === 0)
		html = `<tr><td colspan="6" style="text-align:center; color:#888;">Aucune donnée</td></tr>`;
	tbody.innerHTML = html;
}

// Bind functions to global scope for HTML event attributes (snake_case)
window.process_logs = process_logs;
window.apply_filters = apply_filters;
window.reset_filters = reset_filters;
window.switch_tab = switch_tab;
window.handle_search = handle_search;
window.handle_sort = handle_sort;
