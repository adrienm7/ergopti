/**
 * tools/test/support/banner-dom.cjs
 * ==============================================================================
 * MODULE: Metrics Banner Page Fixture
 * DESCRIPTION:
 * Runs one real metrics banner script against the few DOM calls it makes,
 * with the locale seeded late the way the Windows host injects it on ready.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const vm = require('node:vm');

/** A node with the members the banners use. */
function node(tag) {
	const classes = new Set();
	return {
		tag,
		children: [],
		style: {},
		textContent: '',
		attributes: {},
		classList: {
			toggle(name, on) {
				if (on) classes.add(name);
				else classes.delete(name);
			},
			contains: (name) => classes.has(name)
		},
		setAttribute(name, value) {
			this.attributes[name] = value;
		},
		appendChild(child) {
			this.children.push(child);
		}
	};
}

/**
 * Loads `file` in a page whose locale has not landed yet.
 * @param {string} file - Absolute path of the banner script.
 * @returns {{window: object, body: object, applyLocale: function(object, string): void}}
 */
function loadBanner(file) {
	const listeners = [];
	const body = node('body');
	body.insertBefore = (child) => body.children.unshift(child);
	const document = {
		head: node('head'),
		body,
		createElement: node,
		addEventListener(name, callback) {
			listeners.push({ name, callback });
		}
	};
	const context = vm.createContext({
		document,
		ThemeTokens: { color: () => '#000000' }
	});
	context.window = context;
	vm.runInContext(fs.readFileSync(file, 'utf8'), context, { filename: file });
	return {
		window: context,
		body,
		// What i18n.js does once the host's strings arrive.
		applyLocale(strings, locale) {
			context._i18n_strings = strings;
			context._i18n_locale = locale;
			for (const { name, callback } of listeners) if (name === 'i18n:applied') callback();
		}
	};
}

module.exports = { loadBanner };
