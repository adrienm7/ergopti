// tools/test/lib/app-window-host.cjs

/**
 * ==============================================================================
 * MODULE: App Window Host
 * DESCRIPTION:
 * What the browser tests of the app's own WebView windows put in place of a
 * native host: a loopback server serving static/ as the hosts' virtual hosts
 * do, and the fake host run in the page before its scripts (the locale seed,
 * one driver family's bridge and a log of the messages the page posts).
 * The accessibility scan (app-windows-accessibility.playwright.cjs) and the
 * reading preferences check (app-windows-reading.playwright.cjs) share it.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const TYPES = {
	'.html': 'text/html',
	'.js': 'text/javascript',
	'.mjs': 'text/javascript',
	'.css': 'text/css',
	'.json': 'application/json',
	'.svg': 'image/svg+xml',
	'.png': 'image/png',
	'.woff2': 'font/woff2',
	'.toml': 'text/plain'
};

/**
 * Serves a static/ folder read-only on loopback, as the hosts' virtual hosts
 * serve a window.
 * @param {string} root - Absolute path of the static/ folder.
 * @param {number} port - 0 for any free port.
 */
function serveStatic(root, port) {
	const server = http.createServer((request, response) => {
		const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
		const file = path.resolve(root, pathname.slice(1));
		if (!file.startsWith(root + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
			response.writeHead(404);
			response.end();
			return;
		}
		response.setHeader('Content-Type', TYPES[path.extname(file)] || 'application/octet-stream');
		fs.createReadStream(file).pipe(response);
	});
	return new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen(port, '127.0.0.1', () => resolve(server));
	});
}

/**
 * The fake host, run in the page before its own scripts: the seed the real
 * hosts prepend (locale), the bridge of one driver family, and a message log.
 * A fixture's host function, when it has one, answers each message the page
 * posts, as the native host does with ExecuteScript / evaluateJavaScript.
 * @param {{bridge: string, family: string, locale: string, host: string|null}} seed
 */
function installFakeHost(seed) {
	window._i18n_locale = seed.locale;
	window.__hostMessages = [];
	// The fixture's answer, compiled from its source in the page's own realm.
	const answer = seed.host ? (0, eval)('(' + seed.host + ')') : null;
	const receive = (raw) => {
		let message = raw;
		if (typeof raw === 'string')
			try {
				message = JSON.parse(raw);
			} catch (_) {
				message = raw;
			}
		window.__hostMessages.push(message);
		if (answer) setTimeout(() => answer(message), 0);
	};
	if (seed.family === 'windows')
		window.chrome = {
			webview: {
				postMessage: receive,
				addEventListener() {},
				removeEventListener() {}
			}
		};
	else
		window.webkit = {
			messageHandlers: {
				[seed.bridge]: { postMessage: (payload) => receive(JSON.parse(JSON.stringify(payload))) }
			}
		};
}

module.exports = { serveStatic, installFakeHost };
