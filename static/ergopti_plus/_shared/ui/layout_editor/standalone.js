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

	/** Saves a file as a browser download. */
	function download(filename, text, mime) {
		const url = URL.createObjectURL(new Blob([text], { type: `${mime};charset=utf-8` }));
		const link = document.createElement('a');
		link.href = url;
		link.download = filename;
		document.body.append(link);
		link.click();
		link.remove();
		setTimeout(() => URL.revokeObjectURL(url), 0);
	}

	// The site passes ?lang=<code>; i18n.js loads that locale, then English and French.
	const lang = new URLSearchParams(location.search).get('lang');
	if (lang && /^[a-z]{2}$/.test(lang)) window._i18n_locale = lang;

	window.layoutEditor = LayoutEditorPage.mount(document.getElementById('layout-editor'), {
		saveFile: download
	});
})();
