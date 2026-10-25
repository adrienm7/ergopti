// _shared/ui/release_notes/pane.js

/**
 * ==============================================================================
 * MODULE: Release Notes Renderer
 * DESCRIPTION:
 * Draws the changelog section of one release body into a container. The Windows
 * update prompt's pane (release_notes/script.js) and the update-check window
 * (update_check/script.js, on every desktop) both call it, so the two show
 * identical notes.
 *
 * FEATURES & RATIONALE:
 * 1. One renderer: the same splitter and DOM-only Markdown renderer as the
 *    Versions window; remote text only ever reaches the page as text nodes.
 * 2. Changelog only: the windows that use it install the update themselves, so
 *    the download tables of the release body would only compete with their
 *    buttons.
 * 3. Links: repository URLs only. The caller decides how a clicked link reaches
 *    its host; the host validates the URL again before opening it.
 * 4. Needs markdown.js, repository_links.js and changelog/release_body.js
 *    loaded first.
 * ==============================================================================
 */

(function (global) {
	'use strict';

	/**
	 * Renders the changelog section of a release body, or shows the empty-notes line.
	 * @param {Element} container - Receives the rendered changelog.
	 * @param {Element} empty - The "no notes" line, shown when there is no changelog.
	 * @param {{body: string, owner: string, repo: string}} notes - The release body
	 *   and the repository whose links may be clicked.
	 * @param {function(string): void} openUrl - Called with a clicked repository URL.
	 */
	function renderReleaseNotes(container, empty, notes, openUrl) {
		var changelog = splitReleaseBody(notes.body).changelog;
		if (changelog === '') {
			container.replaceChildren();
			empty.hidden = false;
			return;
		}
		empty.hidden = true;
		renderMarkdownInto(container, changelog, {
			allow: function (url) {
				return isRepositoryUrl(url, notes.owner, notes.repo);
			},
			open: openUrl
		});
	}

	global.renderReleaseNotes = renderReleaseNotes;
})(window);
