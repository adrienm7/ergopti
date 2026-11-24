// tools/test/lib/wcag-tags.cjs

/**
 * ==============================================================================
 * MODULE: WCAG Tags Scanned by axe-core
 * DESCRIPTION:
 * The single list of axe-core tags the accessibility gates run: WCAG 2.0, 2.1
 * and 2.2 at levels A, AA and AAA. The maintainer set WCAG 2.2 AAA as the
 * target on 2026-11-23 (TODO « Full accessibility »), so the site and Studio
 * scan (site-accessibility.playwright.cjs) and the app windows' scan
 * (app-windows-accessibility.playwright.cjs) both read it from here. axe-core
 * 4.14 tags three rules AAA (color-contrast-enhanced, identical-links-same-
 * purpose, meta-refresh-no-exceptions) and none wcag21aaa or wcag22aaa; those
 * two tags stay listed so a later axe release that adds such rules is run
 * without a change here. The AAA criteria no tool measures are listed with
 * their manual check in docs/audits/accessibility/aaa-criteria.md.
 * ==============================================================================
 */

'use strict';

const WCAG_TAGS = Object.freeze([
	'wcag2a',
	'wcag2aa',
	'wcag2aaa',
	'wcag21a',
	'wcag21aa',
	'wcag21aaa',
	'wcag22a',
	'wcag22aa',
	'wcag22aaa'
]);

module.exports = { WCAG_TAGS };
