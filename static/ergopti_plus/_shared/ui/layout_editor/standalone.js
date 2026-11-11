// _shared/ui/layout_editor/standalone.js

/**
 * ==============================================================================
 * MODULE: Layout Editor Standalone Host
 * DESCRIPTION:
 * Mounts the unified layout editor as a page of its own, the way the website
 * frames it: files open through the browser's file picker and save as
 * downloads. ErgoptiPlus mounts the same editor in its layout manager window
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

	// The site passes ?lang=<code>; i18n.js loads that locale, then English and French.
	const lang = new URLSearchParams(location.search).get('lang');
	if (lang && /^[a-z]{2}$/.test(lang)) window._i18n_locale = lang;

	window.layoutEditor = LayoutEditorPage.mount(document.getElementById('layout-editor'), {
		saveFile: download,
		saveBinary: download,
		loadSources: registrySources
	});
})();
