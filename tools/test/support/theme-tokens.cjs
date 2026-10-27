// tools/test/support/theme-tokens.cjs

/**
 * ==============================================================================
 * MODULE: Theme Tokens Test Support
 * DESCRIPTION:
 * Gives a vm context what _shared/ui/theme_tokens.js reads in a page: a document
 * element whose computed style answers the custom properties of theme.css, as the
 * browser does for the light appearance. Tests that run a page script which draws
 * colours call installThemeTokens(context) before loading that script.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const UI = path.resolve(__dirname, '../../../static/ergopti_plus/_shared/ui');

/** Reads the custom properties declared in the first :root block of theme.css. */
function themeProperties() {
	const css = fs.readFileSync(path.join(UI, 'theme.css'), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');
	const properties = new Map();
	for (const block of css.matchAll(/:root\s*\{([^}]*)\}/g)) {
		for (const match of block[1].matchAll(/(--theme-[\w-]+)\s*:\s*([^;]+);/g)) {
			if (!properties.has(match[1])) properties.set(match[1], match[2].trim());
		}
	}
	return properties;
}

/**
 * Installs getComputedStyle, document.documentElement and ThemeTokens in a context.
 * @param {object} context A vm context (already created with vm.createContext).
 * @returns {object} The context.
 */
function installThemeTokens(context) {
	const properties = themeProperties();
	context.document = context.document || {};
	context.document.documentElement = context.document.documentElement || {};
	context.getComputedStyle = () => ({
		getPropertyValue: (name) => (properties.has(name) ? ` ${properties.get(name)} ` : '')
	});
	vm.runInContext(fs.readFileSync(path.join(UI, 'theme_tokens.js'), 'utf8'), context, {
		filename: 'theme_tokens.js'
	});
	return context;
}

module.exports = { installThemeTokens, themeProperties };
