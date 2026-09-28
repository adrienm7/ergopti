// _shared/ui/release_notes/script.js

/**
 * ==============================================================================
 * MODULE: Release Notes Pane
 * DESCRIPTION:
 * Renders the changelog of one release inside a native dialog (the Windows
 * update prompt). The host seeds the release body; the page shows only its
 * changelog section, through the same splitter and DOM-only Markdown renderer
 * as the Versions window, so both show identical notes.
 *
 * FEATURES & RATIONALE:
 * 1. One renderer: the prompt used to build its own HTML string and hand it to
 *    innerHTML, with a looser link policy than the Versions window.
 * 2. Changelog only: the prompt installs the update itself, so the download
 *    tables of the release body would only compete with its buttons.
 * 3. Links: repository URLs only, posted to the host with the seeded session
 *    token; the host validates the session and the URL again before opening.
 * ==============================================================================
 */

(function () {
	'use strict';

	var seed = window.__release_notes;
	if (!seed || typeof seed !== 'object' || typeof seed.body !== 'string') {
		throw new Error('release notes pane: the host seeded no window.__release_notes body');
	}
	var post = makeHostBridge('release_notes_bridge');

	/** Posts a clicked repository link to the host. */
	function openUrl(url) {
		post({ action: 'open_url', url: url, session: seed.session });
	}

	/** Renders the changelog section, or the empty-notes message. */
	function render() {
		var container = document.getElementById('release-notes');
		var empty = document.getElementById('empty-notes');
		var changelog = splitReleaseBody(seed.body).changelog;
		if (changelog === '') {
			container.replaceChildren();
			empty.hidden = false;
			return;
		}
		empty.hidden = true;
		renderMarkdownInto(container, changelog, {
			allow: function (url) {
				return isRepositoryUrl(url, seed.owner, seed.repo);
			},
			open: openUrl
		});
	}

	if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', render);
	else render();
})();
