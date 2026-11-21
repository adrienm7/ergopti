// _shared/ui/metrics_chart_values.js

// ==============================================================================
// MODULE: Metrics chart values
// DESCRIPTION:
// Gives the keyboard what a pointer reads on a metrics chart, and draws the
// chart text in the reader's font and spacing. A Chart.js
// canvas shows its values in tooltips while hovered, which only a mouse can
// do (WCAG 2.1.1, 1.4.13). This plugin writes, next to every chart, a
// disclosure listing the same values in the same words, the tooltip's own
// title and label callbacks, and points the canvas at it
// (data-keyboard-equivalent, read by tools/test/lib/keyboard-operability.cjs).
//
// FEATURES & RATIONALE:
// 1. Same words as the tooltip: each value is the text the chart's resolved
//    tooltip callbacks give for that point, so the two never disagree.
// 2. No change for a pointer user: the disclosure is visually hidden until it
//    holds the focus or is open (theme.css, .theme-chart-values).
// 3. Loaded by both metrics dashboards. The typing dashboard defers Chart.js,
//    so the plugin registers once the document is parsed when Chart is not
//    there yet; a page without Chart.js then is an error, never silence.
// 4. Drawings too. A calendar or heatmap the page writes as SVG markup shows
//    its values in <title> tooltips, out of reach of the keyboard and of a
//    screen reader inside its role="img" (MET-16); markup() gives it the same
//    disclosure, written beside it.
// 5. A canvas draws its own text, out of reach of the reading font and
//    spacing that a11y_prefs.js writes on the root and theme.css styles. The
//    chart text takes them from the page body's computed style once it is
//    parsed: the font family and line height as Chart.js defaults, the
//    letter and word spacing on each chart's context, in multiples of the
//    font size as theme.css states them. A reading change reaches a native
//    window by its reopening (its host retires a warm window, MET-03), so
//    the values are read once per page. A WebKit too old for the canvas
//    letterSpacing and wordSpacing properties draws the font without them.
// ==============================================================================

(function () {
	'use strict';

	var SUMMARY_KEY = 'common.chart_values';
	var CLASS = 'theme-chart-values';
	var count = 0;

	/** The text a tooltip callback returns, joined when it gives several lines. */
	function textOf(value) {
		if (Array.isArray(value)) return value.filter(Boolean).join(' ');
		return value == null ? '' : String(value);
	}

	/**
	 * The tooltip's words for every visible point: one list per dataset.
	 * @param {Chart} chart
	 * @returns {{name: string, items: string[]}[]}
	 */
	function valuesOf(chart) {
		var callbacks = chart.options.plugins.tooltip.callbacks;
		var lists = [];
		chart.data.datasets.forEach(function (dataset, datasetIndex) {
			if (!chart.isDatasetVisible(datasetIndex)) return;
			var meta = chart.getDatasetMeta(datasetIndex);
			var items = [];
			meta.data.forEach(function (element, dataIndex) {
				var labelled = meta.controller.getLabelAndValue(dataIndex);
				var item = {
					chart: chart,
					label: labelled.label,
					parsed: meta._parsed[dataIndex],
					raw: dataset.data[dataIndex],
					formattedValue: labelled.value,
					dataset: dataset,
					dataIndex: dataIndex,
					datasetIndex: datasetIndex,
					element: element
				};
				var title = textOf(callbacks.title.call(chart.tooltip, [item]));
				var label = textOf(callbacks.label.call(chart.tooltip, item));
				items.push(title ? title + ' — ' + label : label);
			});
			if (items.length) lists.push({ name: dataset.label || '', items: items });
		});
		return lists;
	}

	/** The disclosure of one chart, made once and kept next to its canvas. */
	function disclosureOf(canvas) {
		var existing = canvas.__ergoptiChartValues;
		if (existing && existing.isConnected) return existing;
		var details = document.createElement('details');
		details.className = CLASS;
		var summary = document.createElement('summary');
		summary.id = 'chart-values-' + ++count;
		summary.setAttribute('data-i18n', SUMMARY_KEY);
		var strings = window._i18n_strings || {};
		if (strings[SUMMARY_KEY]) summary.textContent = strings[SUMMARY_KEY];
		details.appendChild(summary);
		(canvas.closest('figure, section') || canvas.parentElement).appendChild(details);
		canvas.__ergoptiChartValues = details;
		canvas.setAttribute('data-keyboard-equivalent', '#' + summary.id);
		return details;
	}

	var PLUGIN = {
		id: 'ergoptiChartValues',
		afterUpdate: function (chart) {
			var details = disclosureOf(chart.canvas);
			while (details.childNodes.length > 1) details.removeChild(details.lastChild);
			valuesOf(chart).forEach(function (list) {
				if (list.name) {
					var name = document.createElement('p');
					name.textContent = list.name;
					details.appendChild(name);
				}
				var ul = document.createElement('ul');
				list.items.forEach(function (text) {
					var li = document.createElement('li');
					li.textContent = text;
					ul.appendChild(li);
				});
				details.appendChild(ul);
			});
		}
	};

	// The body's spacing until the page is parsed: none.
	var spacing = { letter: '0em', word: '0em' };

	/** A computed length as a multiple of the font size, for the canvas. */
	function emOf(length, fontSize) {
		var pixels = parseFloat(length);
		return isFinite(pixels) ? pixels / fontSize : 0;
	}

	/** Takes the reading font and spacing of the parsed page body. */
	function applyReading() {
		var style = getComputedStyle(document.body);
		var fontSize = parseFloat(style.fontSize);
		if (!(fontSize > 0)) throw new Error('metrics_chart_values.js: the page body has no font size');
		Chart.defaults.font.family = style.fontFamily;
		if (style.lineHeight !== 'normal')
			Chart.defaults.font.lineHeight = emOf(style.lineHeight, fontSize);
		spacing = {
			letter: emOf(style.letterSpacing, fontSize) + 'em',
			word: emOf(style.wordSpacing, fontSize) + 'em'
		};
	}

	/** Chart.js measures, then draws, through one context: space both. */
	function spaceText(chart) {
		chart.ctx.letterSpacing = spacing.letter;
		chart.ctx.wordSpacing = spacing.word;
	}

	var READING_PLUGIN = {
		id: 'ergoptiChartReading',
		// A resized canvas resets its context, and a resize always updates.
		beforeUpdate: spaceText,
		beforeDraw: spaceText
	};

	function register() {
		if (typeof Chart === 'undefined')
			throw new Error('metrics_chart_values.js: Chart.js is not loaded on this page');
		Chart.register(PLUGIN, READING_PLUGIN);
		// The apps dashboard loads Chart.js in the head, before the body exists.
		if (document.readyState === 'loading')
			document.addEventListener('DOMContentLoaded', applyReading);
		else applyReading();
	}

	/** Escapes text for markup a page writes through innerHTML. */
	function escapeText(text) {
		return String(text).replace(/[&<>"]/g, function (character) {
			return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[character];
		});
	}

	/**
	 * The disclosure of a drawing written as markup: the drawing's tag takes
	 * `attribute`, `html` follows the drawing.
	 * @param {string} id - Id of the disclosure's summary, unique on the page.
	 * @param {string[]} items - Every value, in the words of its tooltip.
	 * @returns {{attribute: string, html: string}}
	 */
	function markup(id, items) {
		if (!/^[a-z][a-z0-9_-]*$/.test(id))
			throw new Error('metrics_chart_values.js: invalid id ' + id);
		var strings = window._i18n_strings || {};
		var list = items
			.map(function (text) {
				return '<li>' + escapeText(text) + '</li>';
			})
			.join('');
		return {
			attribute: ' data-keyboard-equivalent="#' + id + '"',
			html:
				'<details class="' +
				CLASS +
				'"><summary id="' +
				id +
				'" data-i18n="' +
				SUMMARY_KEY +
				'">' +
				escapeText(strings[SUMMARY_KEY] || '') +
				'</summary><ul>' +
				list +
				'</ul></details>'
		};
	}

	window.ErgoptiChartValues = { plugin: PLUGIN, valuesOf: valuesOf, markup: markup };
	if (typeof Chart !== 'undefined') register();
	else document.addEventListener('DOMContentLoaded', register);
})();
