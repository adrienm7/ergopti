// tools/test/browser/app-windows-fixtures.cjs

/**
 * ==============================================================================
 * MODULE: App Windows Fixtures
 * DESCRIPTION:
 * The WebView windows of Ergopti+ that app-windows-accessibility.playwright.cjs
 * scans and walks, each with the fake host that fills it. One entry per
 * window:
 *   id     — the page's folder under _shared/ui/ and its apps.manifest.json key
 *            (the window's size comes from there);
 *   size   — only for a pane with no window of its own: { width, height };
 *   seed   — optional { script, arg } run before the page's scripts, the
 *            boot data a host prepends (addInitScript);
 *   bridge — the message handler name the page posts to (host_bridge.js);
 *   host   — optional `function (message) {...}` run in the page for each
 *            message it posts, answering as the native host does; it is sent
 *            as source text, so it may only use the page's own globals;
 *   fill   — optional async (page) => {...} run after the page loads;
 *   ready  — a selector shown once the fixture data has rendered;
 *   states — optional further states, each { name, enter: async (page) => {} },
 *            scanned and walked from a freshly filled window.
 * The data fills every section a user can reach, so the scan sees each control.
 * ==============================================================================
 */

'use strict';

const WINDOWS = Object.freeze([
	...require('./app-windows-fixtures/dialogs.cjs'),
	...require('./app-windows-fixtures/editors.cjs'),
	...require('./app-windows-fixtures/metrics.cjs')
]);

module.exports = { WINDOWS };
