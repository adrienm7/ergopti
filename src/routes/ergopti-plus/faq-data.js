// src/routes/ergopti-plus/faq-data.js

/**
 * ==============================================================================
 * MODULE: Ergopti+ Page — FAQ Data
 * DESCRIPTION:
 * The FAQ question/answer list, extracted from the component so the page head
 * can also serialize it as schema.org FAQPage structured data (rich results in
 * search engines). Answers may contain inline HTML (<strong>…); the JSON-LD
 * serializer strips the tags.
 * ==============================================================================
 */

/** @type {Array<{q: string, a: string}>} */
export const FAQ_DATA = [
	{
		q: 'Est-ce que quelque chose part sur Internet ?',
		a: 'Non. Tout — hotstrings, prédictions IA, métriques — est calculé et stocké <strong>sur votre machine</strong>. Les modèles d’IA tournent en local ; si vous branchez une clé d’API distante (optionnel), elle est chiffrée dans le Trousseau macOS ou via DPAPI sur Windows, et vous choisissez explicitement quand l’utiliser.'
	},
	{
		q: 'Est-ce que ça ralentit ma frappe ?',
		a: 'Non perceptiblement. Les expansions sont synchrones et instantanées ; les prédictions IA sont asynchrones et n’interrompent jamais la frappe — une suggestion s’affiche quand elle est prête, et vous l’ignorez ou l’acceptez d’une touche.'
	},
	{
		q: 'Quelle différence entre Ergopti et Ergopti+ ?',
		a: '<strong>Ergopti</strong> est la disposition clavier — l’agencement des lettres. <strong>Ergopti+</strong> est le logiciel compagnon : hotstrings, IA, tap-holds, gestes, métriques, qui fonctionne sur n’importe quelle disposition. Utilisez l’un sans l’autre, ou les deux ensemble pour le gain maximal.'
	},
	{
		q: 'Ça marche dans toutes mes applications ?',
		a: 'Oui, le driver agit au niveau du système : navigateur, éditeur de code, messagerie, traitement de texte… Les champs de mot de passe sont volontairement <strong>ignorés</strong>. Quelques applications très verrouillées (certains jeux anti-triche) peuvent bloquer l’injection de touches.'
	},
	{
		q: 'Faut-il utiliser la disposition Ergopti ?',
		a: 'Non. <strong>Tout fonctionne sur n’importe quelle disposition</strong> (AZERTY, QWERTY, Bépo…). La disposition Ergopti débloque des bonus supplémentaires (roulements, super-touches), mais elle est totalement optionnelle.'
	},
	{
		q: 'C’est vraiment gratuit ?',
		a: 'Oui : gratuit, open-source, sans compte et sans télémétrie. Le code est auditable publiquement sur GitHub.'
	},
	{
		q: 'Comment on désinstalle ?',
		a: 'Chaque fonctionnalité se désactive d’un clic dans le menu, et l’application se retire comme n’importe quelle autre. Vos données (base SQLite locale) vous appartiennent et partent avec.'
	},
	{
		q: 'Windows, macOS ou Linux ?',
		a: 'Windows (AutoHotkey) et macOS (Hammerspoon) sont à parité et prêts à l’emploi. Le driver Linux (kanata + daemon Lua) est complet mais en alpha — il cherche ses premiers testeurs.'
	}
];
