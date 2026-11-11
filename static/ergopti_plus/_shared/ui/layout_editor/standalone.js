// _shared/ui/layout_editor/standalone.js

/**
 * ==============================================================================
 * MODULE: Layout Editor Standalone Host
 * DESCRIPTION:
 * Mounts the unified layout editor as a page of its own, the way the website
 * frames it: files open through the browser's file picker and save as
 * downloads; the Linux XKB and Windows KLC downloads load the Lua VM, the
 * shared Lua export adapter and the KLC generator the first time they run.
 * ErgoptiPlus mounts the same editor in its layout manager window
 * with a host that saves through the driver instead (layout_manager/script.js).
 * ==============================================================================
 */

(function () {
	'use strict';

	/** Saves a file (text, or bytes such as a ZIP archive) as a browser download. */
	function download(filename, content, mime) {
		const type = typeof content === 'string' ? `${mime};charset=utf-8` : mime;
		const url = URL.createObjectURL(new Blob([content], { type }));
		const link = document.createElement('a');
		link.href = url;
		link.download = filename;
		document.body.append(link);
		link.click();
		link.remove();
		setTimeout(() => URL.revokeObjectURL(url), 0);
	}

	// The registry folder the site serves beside the drivers (static/layouts/registry).
	const REGISTRY = new URL('../../../../layouts/registry/', location.href);

	/** The registry layouts a layer can be filled from, as the drivers' composer host lists them. */
	async function registrySources() {
		const response = await fetch(new URL('index.json', REGISTRY));
		if (!response.ok) throw { code: 'registry_unavailable', path: String(response.status) };
		const index = await response.json();
		return Promise.all(
			index.layouts.map(async (entry) => {
				const layout = await fetch(new URL(entry.file, REGISTRY));
				if (!layout.ok) throw { code: 'registry_unavailable', path: entry.file };
				return {
					id: entry.id,
					name: entry.name,
					convention: entry.keycode_convention,
					text: await layout.text()
				};
			})
		);
	}

	// The shared Lua root and the XKB converter data the site serves (static/).
	const LUA_ROOT = new URL('../../lua/', location.href);
	const XKB_DATA = new URL('../../../../ergopti/linux/xkb_generation/data/', location.href);
	// Loaded on the first XKB or KLC download only: the Lua VM and the KLC generator.
	const ON_DEMAND_SCRIPTS = ['../vendor/fengari-web.js', '_generated/klc_generator.js'];
	let exportAssets = null;

	/** Runs a classic script of the page once. */
	function loadScript(src) {
		return new Promise((resolve, reject) => {
			const script = document.createElement('script');
			script.src = src;
			script.onload = resolve;
			script.onerror = () => reject({ code: 'export_assets_unavailable', path: src });
			document.head.append(script);
		});
	}

	/** The text of a file the site serves, or the refusal naming it. */
	async function fetchText(url) {
		const response = await fetch(url);
		if (!response.ok) throw { code: 'export_assets_unavailable', path: url.pathname };
		return response.text();
	}

	/**
	 * What the XKB and KLC downloads run (LayoutSourceIO.xkbArchive, klcFile): the
	 * shared Lua export adapter in fengari, the XKB converter data, the KLC generator.
	 */
	function loadExportAssets() {
		exportAssets =
			exportAssets ||
			(async () => {
				for (const src of ON_DEMAND_SCRIPTS) await loadScript(src);
				const sources = {};
				for (const name of LayoutLuaRunner.MODULES)
					sources[name] = await fetchText(new URL(LayoutLuaRunner.modulePath(name), LUA_ROOT));
				const [keysyms, template, types] = await Promise.all(
					['key_sym.json', 'xkb_symbols.txt', 'xkb_types.txt'].map((file) =>
						fetchText(new URL(file, XKB_DATA))
					)
				);
				return {
					lua: LayoutLuaRunner.create(LayoutLuaRunner.loadedVm(window), sources),
					keysyms: JSON.parse(keysyms),
					template,
					types,
					generator: LayoutKlcGenerator
				};
			})().catch((error) => {
				// A failed load (offline, a missing file) is retried on the next click.
				exportAssets = null;
				throw error;
			});
		return exportAssets;
	}

	// The site passes ?lang=<code>; i18n.js loads that locale, then English and French.
	const lang = new URLSearchParams(location.search).get('lang');
	if (lang && /^[a-z]{2}$/.test(lang)) window._i18n_locale = lang;

	window.layoutEditor = LayoutEditorPage.mount(document.getElementById('layout-editor'), {
		saveFile: download,
		saveBinary: download,
		loadSources: registrySources,
		exportAssets: loadExportAssets
	});
})();
