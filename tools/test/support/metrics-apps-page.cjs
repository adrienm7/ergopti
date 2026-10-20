/**
 * tools/test/support/metrics-apps-page.cjs
 * ==============================================================================
 * MODULE: Loaded Metrics Apps Page Fixture
 * DESCRIPTION:
 * Executes every script declared by the real HTML with explicit browser ports.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const page = path.resolve(
	__dirname,
	'../../../static/ergopti_plus/_shared/ui/metrics_apps/index.html'
);

/**
 * Loads the real page declarations; timers, network and canvas remain browser ports.
 * @param {string} host Host transport to expose.
 * @param {function(string, object): void} [afterScript] Read-only observer after each real script.
 */
function loadMetricsAppsPage(host = 'macos', afterScript) {
	const listeners = [];
	const timers = [];
	const posts = [];
	const diagnostics = [];
	const elements = new Map();
	const messageListeners = [];
	function element() {
		const node = {
			children: [],
			style: {},
			classList: { toggle() {} },
			addEventListener() {},
			appendChild(child) {
				child.parentNode = this;
				this.children.push(child);
			},
			insertBefore(child) {
				child.parentNode = this;
				this.children.unshift(child);
			},
			setAttribute(name, value) {
				this[name] = value;
			},
			querySelectorAll() {
				return [];
			}
		};
		Object.defineProperty(node, 'innerHTML', {
			get() {
				return this.html || '';
			},
			set(value) {
				this.html = value;
				this.children = [];
			}
		});
		return node;
	}
	// Only the selected DOM boundary is supplied. Optional chart canvases and
	// panels are absent, so the actual rendering code skips those native ports.
	for (const id of [
		'date-select',
		'period-select',
		'date-select-container',
		'btn-refresh',
		'btn-add-app',
		'kpi-switches',
		'kpi-unlocks',
		'kpi-wifi',
		'apps-tbody'
	]) {
		elements.set(id, element());
	}
	const document = {
		readyState: 'loading',
		currentScript: null,
		hidden: false,
		documentElement: { lang: 'fr', style: {} },
		body: element(),
		head: element(),
		addEventListener(name, callback) {
			listeners.push({ name, callback });
		},
		querySelectorAll() {
			return [];
		},
		getElementById(id) {
			return elements.get(id) || null;
		},
		createElement: element
	};
	const context = vm.createContext({
		document,
		URL,
		URLSearchParams,
		addEventListener(name, callback) {
			listeners.push({ name, callback });
		},
		location: { href: 'about:blank', hash: '', search: '', protocol: 'about:' },
		navigator: { language: 'fr-FR', userAgent: 'metrics-page-test' },
		console: Object.fromEntries(
			['log', 'info', 'debug', 'warn', 'error'].map((level) => [
				level,
				(...args) => diagnostics.push({ level, args })
			])
		),
		setTimeout(callback) {
			timers.push(callback);
			return timers.length;
		},
		clearTimeout() {},
		setInterval(callback) {
			timers.push(callback);
			return timers.length;
		},
		clearInterval() {},
		requestAnimationFrame(callback) {
			timers.push(callback);
			return timers.length;
		},
		cancelAnimationFrame() {},
		fetch() {
			return Promise.resolve({ ok: false });
		},
		webkit: {
			messageHandlers: {
				metrics_apps_bridge: {
					postMessage(body) {
						posts.push(body);
					}
				}
			}
		},
		_i18n_locale: 'fr',
		_i18n_strings: JSON.parse(
			fs.readFileSync(path.resolve(path.dirname(page), '../../data/locales/fr.json'), 'utf8')
		)
	});
	context.window = context;
	context.self = context;
	if (host === 'linux') context.__ergopti_host = 'linux';
	if (host === 'windows')
		context.chrome = {
			webview: {
				addEventListener(name, callback) {
					messageListeners.push({ name, callback });
				},
				postMessage(body) {
					posts.push(body);
				}
			}
		};
	const scripts = [];
	const html = fs.readFileSync(page, 'utf8');
	for (const match of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
		const src = /\bsrc="([^"]+)"/.exec(match[1]);
		const filename = src ? path.resolve(path.dirname(page), src[1]) : `${page}#inline`;
		const code = src ? fs.readFileSync(filename, 'utf8') : match[2];
		scripts.push(src ? src[1] : '#inline');
		vm.runInContext(code, context, { filename, timeout: 1000 });
		if (afterScript) afterScript(scripts[scripts.length - 1], context);
	}
	return { context, scripts, elements, listeners, timers, posts, diagnostics, messageListeners };
}

module.exports = { loadMetricsAppsPage };
