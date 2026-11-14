<!-- src/routes/ergopti-plus/faq/+page.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ — FAQ
DESCRIPTION:
Sub-page of the Ergopti+ section; it loads only its own sections. The shell
(language, version, local navigation, sticky download) is ../+layout.svelte.
==============================================================================
-->

<script>
	import { t } from '../i18n.svelte.js';
	import Faq from '../Faq.svelte';
	import { FAQ_DATA } from '../faq-data.js';

	// SEO structured data (schema.org) of the FAQ, serialized once in French —
	// the canonical language. The script tag is assembled from split halves
	// because Svelte ends a component script at its first literal closing tag.
	const stripTags = (html) => html.replace(/<[^>]+>/g, '');
	const jsonLd =
		'<scr' +
		'ipt type="application/ld+json">' +
		JSON.stringify({
			'@context': 'https://schema.org',
			'@type': 'FAQPage',
			mainEntity: FAQ_DATA.map((f) => ({
				'@type': 'Question',
				name: f.q,
				acceptedAnswer: { '@type': 'Answer', text: stripTags(f.a) }
			}))
		}) +
		'</scr' +
		'ipt>';
</script>

<svelte:head>
	<title>{t('FAQ — Ergopti+')}</title>
	<meta
		name="description"
		content={t(
			'Les questions fréquentes sur Ergopti+ : vie privée, compatibilité, IA, installation.'
		)}
	/>
	{@html jsonLd}
</svelte:head>

<h1 class="ep-subpage-title">{t('FAQ')}</h1>

<Faq />
