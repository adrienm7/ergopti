// src/lib/js/siteNavigation.js

/**
 * ==============================================================================
 * MODULE: Site Navigation Map
 * DESCRIPTION:
 * Single source of the site's structure: Ergopti is the project and its three
 * products each own a section of the site. The header menu, the home page
 * cards, the local navigation of the Disposition Ergopti and Ergopti+ pages
 * and the redirects of the former addresses all read this map, so a page
 * moves in one place.
 * ==============================================================================
 */

/** The three products, in the header and home page order (maintainer, 2026-11-14). */
export const PRODUCTS = Object.freeze([
	Object.freeze({
		id: 'disposition',
		route: '/ergopti',
		menuLabel: 'Ergopti',
		name: 'Disposition Ergopti',
		icon: 'img/logo/logo.svg',
		// The « français, anglais et code » wording stays on the layout's own pages.
		summary:
			'La disposition clavier ergonomique qui rend la frappe plus fluide, plus rapide et plus confortable.'
	}),
	Object.freeze({
		id: 'ergopti-plus',
		route: '/ergopti-plus',
		menuLabel: 'Ergopti+',
		name: 'Ergopti+',
		icon: 'img/logo/logo_simple.svg',
		summary:
			'Le logiciel qui accélère votre frappe : hotstrings, tap-holds, raccourcis, métriques et IA locale.'
	}),
	Object.freeze({
		id: 'studio',
		route: '/studio',
		menuLabel: 'Studio',
		name: 'Ergopti Studio',
		icon: 'img/logo/studio.svg',
		summary: 'L’éditeur pour créer, modifier et exporter votre propre disposition clavier.'
	})
]);

/** Sub-pages of the Disposition Ergopti section; the first one is the overview. */
export const LAYOUT_PAGES = Object.freeze([
	Object.freeze({ route: '/ergopti', label: 'Aperçu', summary: '' }),
	Object.freeze({
		route: '/ergopti/presentation',
		label: 'Présentation',
		summary: 'La disposition et ses principes : distances, SFBs, alternance, roulements, symboles.'
	}),
	Object.freeze({
		route: '/ergopti/utilisation',
		label: 'Essayer',
		summary: 'Taper avec la disposition dans le navigateur et parcourir ses remplacements de texte.'
	}),
	Object.freeze({
		route: '/ergopti/installation',
		label: 'Installation',
		summary: 'Télécharger et installer la disposition sur Windows, macOS et Linux.'
	}),
	Object.freeze({
		route: '/ergopti/benchmarks',
		label: 'Benchmarks',
		summary: 'Comparer la disposition aux autres sur des corpus français, anglais et code.'
	}),
	Object.freeze({
		route: '/ergopti/informations',
		label: 'Informations',
		summary: 'Genèse, autocritiques, historique des versions, licence et contact.'
	})
]);

/** Sub-pages of the Ergopti+ section (French source labels, translated by its i18n). */
export const ERGOPTI_PLUS_PAGES = Object.freeze([
	Object.freeze({ route: '/ergopti-plus', label: 'Aperçu', summary: '' }),
	Object.freeze({
		route: '/ergopti-plus/presentation',
		label: 'Présentation',
		summary: 'Pour qui, ce qu’il ajoute à la disposition Ergopti et comment il se compare.'
	}),
	Object.freeze({
		route: '/ergopti-plus/hotstrings',
		label: 'Hotstrings',
		summary: 'Expansions, corrections et vos propres hotstrings.'
	}),
	Object.freeze({
		route: '/ergopti-plus/ia',
		label: 'IA',
		summary: 'Prédictions par IA locale ou distante, modèles et profils.'
	}),
	Object.freeze({
		route: '/ergopti-plus/fonctionnalites',
		label: 'Fonctionnalités',
		summary: 'Tap-holds, raccourcis, gestes trackpad et métriques de frappe.'
	}),
	Object.freeze({
		route: '/ergopti-plus/configuration',
		label: 'Configuration',
		summary: 'Réglages, langues d’interface et vie privée.'
	}),
	Object.freeze({
		route: '/ergopti-plus/installation',
		label: 'Installation',
		summary: 'Démarrer en quelques étapes et télécharger pour Windows, macOS ou Linux.'
	}),
	Object.freeze({
		route: '/ergopti-plus/faq',
		label: 'FAQ',
		summary: 'Les réponses aux questions fréquentes.'
	})
]);

/**
 * Former Ergopti+ anchors and the sub-page that now holds each of them. The
 * overview keeps #ep-demo and #ep-promesses.
 */
export const ERGOPTI_PLUS_ANCHORS = Object.freeze({
	'ep-pourqui': '/ergopti-plus/presentation',
	'ep-ergopti': '/ergopti-plus/presentation',
	'ep-comparatif': '/ergopti-plus/presentation',
	'ep-hotstrings': '/ergopti-plus/hotstrings',
	'ep-perso-hotstrings': '/ergopti-plus/hotstrings',
	'ep-ia': '/ergopti-plus/ia',
	'ep-tapholds': '/ergopti-plus/fonctionnalites',
	'ep-raccourcis': '/ergopti-plus/fonctionnalites',
	'ep-trackpad': '/ergopti-plus/fonctionnalites',
	'ep-metriques': '/ergopti-plus/fonctionnalites',
	'ep-personnalisation': '/ergopti-plus/configuration',
	'ep-confidentialite': '/ergopti-plus/configuration',
	'ep-demarrer': '/ergopti-plus/installation',
	'ep-telecharger': '/ergopti-plus/installation',
	'ep-faq': '/ergopti-plus/faq'
});

/**
 * Former top-level pages: the default target, then the anchors that moved to
 * another sub-page. An anchor not listed follows the default target.
 */
export const LEGACY_PAGES = Object.freeze({
	'/benchmarks': Object.freeze({ target: '/ergopti/benchmarks', anchors: Object.freeze({}) }),
	'/informations': Object.freeze({ target: '/ergopti/informations', anchors: Object.freeze({}) }),
	'/utilisation': Object.freeze({
		target: '/ergopti/installation',
		anchors: Object.freeze({
			keyboard_emulation: '/ergopti/utilisation',
			'input-text': '/ergopti/utilisation'
		})
	})
});

/** Every anchor of the former home page now lives on the layout presentation. */
export const LEGACY_HOME_ANCHOR_TARGET = '/ergopti/presentation';

/**
 * Whether a pathname is the given section route or one of its sub-pages.
 * @param {string} pathname - Current URL pathname, base path included.
 * @param {string} sectionPath - Resolved section path, base path included.
 * @returns {boolean}
 */
export function isInSection(pathname, sectionPath) {
	const path = pathname.replace(/\/$/, '') || '/';
	return path === sectionPath || path.startsWith(sectionPath + '/');
}

/**
 * Pick the address an old URL's anchor now lives at.
 * @param {{target: string, anchors: Record<string, string>}} legacy - LEGACY_PAGES entry.
 * @param {string} hash - location.hash, with or without its leading '#'.
 * @returns {string} Route (without base path) followed by the anchor, if any.
 */
export function legacyTarget(legacy, hash) {
	const anchor = decodeURIComponent(String(hash).replace(/^#/, ''));
	if (!anchor) return legacy.target;
	return (legacy.anchors[anchor] ?? legacy.target) + '#' + encodeURIComponent(anchor);
}
