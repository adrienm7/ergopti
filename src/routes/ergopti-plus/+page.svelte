<!-- src/routes/ergopti-plus/+page.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Overview Page
DESCRIPTION:
Entry page of the Ergopti+ section: the hero with its demo and download
button, the key figures, the promises and the sub-pages that hold the
details. It only loads its own sections; the shell (language, version, local
navigation, sticky download) is +layout.svelte. A link to an anchor of the
former one-page version is forwarded to the sub-page that now holds it.
==============================================================================
-->

<script>
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { ERGOPTI_PLUS_ANCHORS, ERGOPTI_PLUS_PAGES } from '#lib/js/siteNavigation.js';

	import { t } from './i18n.svelte.js';
	import Hero from './Hero.svelte';
	import KpiStrip from './KpiStrip.svelte';
	import Promises from './Promises.svelte';

	// Populated at build time by +page.server.js from the driver's data files.
	let { data } = $props();

	// $derived so labels re-translate the instant the language toggles.
	let kpis = $derived([
		{ value: data.hotstringTotal, suffix: '', label: t('hotstrings prêts à l’emploi') },
		{ value: data.aiTotalModels, suffix: '', label: t('modèles d’IA locale au catalogue') },
		{ value: 335, suffix: '', label: t('réglages, tous optionnels') },
		{ value: data.localesCount, suffix: '', label: t('langues d’interface') }
	]);

	// SEO structured data (schema.org) for the application, serialized once in
	// French — the page's canonical language. The script tag is assembled from
	// split halves because Svelte ends a component script at the first literal
	// closing tag it sees, even inside a string
	let jsonLd = $derived(
		'<scr' +
			'ipt type="application/ld+json">' +
			JSON.stringify({
				'@context': 'https://schema.org',
				'@type': 'SoftwareApplication',
				name: 'Ergopti+',
				operatingSystem: 'Windows, macOS, Linux',
				applicationCategory: 'UtilitiesApplication',
				offers: { '@type': 'Offer', price: '0', priceCurrency: 'EUR' },
				url: 'https://ergopti.fr/ergopti-plus',
				description: `Ergopti+ transforme votre frappe en temps réel : ${data.hotstringTotal} expansions et corrections, prédictions IA 100 % locales, tap-holds, gestes trackpad, métriques de frappe. Gratuit et open-source.`
			}) +
			'</scr' +
			'ipt>'
	);

	onMount(() => {
		const anchor = location.hash.slice(1);
		const route = ERGOPTI_PLUS_ANCHORS[anchor];
		if (route) goto(resolve(route) + '#' + anchor, { replaceState: true });
	});
</script>

<svelte:head>
	<title>{t('Ergopti+ — la frappe augmentée, gratuite et locale')}</title>
	<meta
		name="description"
		content={t(
			'Ergopti+ transforme votre frappe en temps réel : {n} expansions et corrections, prédictions IA 100 % locales ({m} modèles), tap-holds, gestes trackpad, métriques de frappe. Gratuit et open-source, sur Windows et macOS (Linux en alpha).',
			{ n: data.hotstringTotal, m: data.aiTotalModels }
		)}
	/>
	{@html jsonLd}
</svelte:head>

<Hero />
<KpiStrip items={kpis} />
<Promises />

<section class="ep-pages" aria-labelledby="ep-pages-title">
	<div class="ep-wrap">
		<h2 id="ep-pages-title" class="ep-pages-title">{t('Tout Ergopti+, page par page')}</h2>
		<ul class="ep-pages-list">
			{#each ERGOPTI_PLUS_PAGES.slice(1) as entry (entry.route)}
				<li>
					<a href={resolve(entry.route)}>
						<strong>{t(entry.label)}</strong>
						<span>{t(entry.summary)}</span>
					</a>
				</li>
			{/each}
		</ul>
	</div>
</section>

<style>
	.ep-pages-title {
		font-size: clamp(1.5rem, 3vw, 2rem);
		margin-bottom: 1.25rem;
		text-align: center;
	}

	.ep-pages-list {
		display: grid;
		gap: 12px;
		grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
		list-style: none;
	}

	.ep-pages-list a {
		background: var(--surface-strong);
		border: 1px solid var(--border);
		border-radius: 14px;
		color: var(--ink);
		display: flex;
		flex-direction: column;
		gap: 6px;
		height: 100%;
		padding: 16px 18px;
		text-decoration: none;
	}

	.ep-pages-list a span {
		color: var(--ink-soft);
	}

	.ep-pages-list a:hover,
	.ep-pages-list a:focus-visible {
		border-color: var(--border-strong);
	}
</style>
