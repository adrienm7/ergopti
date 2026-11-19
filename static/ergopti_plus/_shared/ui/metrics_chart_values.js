// _shared/ui/metrics_chart_values.js

// ==============================================================================
// MODULE: Metrics chart values
// DESCRIPTION:
// Gives the keyboard what a pointer reads on a metrics chart. A Chart.js
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

	function register() {
		if (typeof Chart === 'undefined')
			throw new Error('metrics_chart_values.js: Chart.js is not loaded on this page');
		Chart.register(PLUGIN);
	}

	window.ErgoptiChartValues = { plugin: PLUGIN, valuesOf: valuesOf };
	if (typeof Chart !== 'undefined') register();
	else document.addEventListener('DOMContentLoaded', register);
})();
