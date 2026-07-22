<!-- src/routes/ergopti-plus/+page.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Marketing Page
DESCRIPTION:
Sales page for the Ergopti+ driver suite. Assembles the section components,
holds the layout-required stubs (#page-toc-pc / #page-toc — Header.svelte
queries them on every resize) and bootstraps the shared page state (OS chrome
style, GitHub release).

FEATURES & RATIONALE:
1. Data-Driven: every factual number (hotstrings, models, providers,
   profiles, windows, locales, actions, bundled apps) is measured at build
   time by +page.server.js from the same files the drivers load at boot.
2. Dispatched Windows: the driver's real webview windows are embedded
   inside the sections that discuss them (editor with the hotstrings,
   catalog with the AI, changelog with the updater) via DriverFrame.
==============================================================================
-->

<script>
	import { onMount } from 'svelte';
	import { getRelease } from '$lib/js/getGitHubRelease.js';

	import './ergopti-plus.css';
	import { ui, restoreOS } from './state.svelte.js';
	import { t, restoreLang } from './i18n.svelte.js';
	import LangToggle from './LangToggle.svelte';
	import { FAQ_DATA } from './faq-data.js';

	import Hero from './Hero.svelte';
	import KpiStrip from './KpiStrip.svelte';
	import StickyNav from './StickyNav.svelte';
	import Promises from './Promises.svelte';
	import Hotstrings from './Hotstrings.svelte';
	import PersonalHotstrings from './PersonalHotstrings.svelte';
	import AiSection from './AiSection.svelte';
	import KeyboardPower from './KeyboardPower.svelte';
	import Trackpad from './Trackpad.svelte';
	import MetricsSection from './MetricsSection.svelte';
	import Customization from './Customization.svelte';
	import ErgoptiExclusives from './ErgoptiExclusives.svelte';
	import Platforms from './Platforms.svelte';
	import Personas from './Personas.svelte';
	import Privacy from './Privacy.svelte';
	import Compare from './Compare.svelte';
	import Steps from './Steps.svelte';
	import Faq from './Faq.svelte';
	import StickyCta from './StickyCta.svelte';

	// Populated at build time by +page.server.js from the driver's data files.
	let { data } = $props();

	// Window geometry lookup for the embedded driver frames.
	const winGeo = Object.fromEntries(data.webviews.map((w) => [w.id, w]));

	// $derived so labels re-translate the instant the language toggles.
	let kpis = $derived([
		{ value: data.hotstringTotal, suffix: '', label: t('hotstrings prêts à l’emploi') },
		{ value: data.aiTotalModels, suffix: '', label: t('modèles d’IA locale au catalogue') },
		{ value: 335, suffix: '', label: t('réglages, tous optionnels') },
		{ value: data.localesCount, suffix: '', label: t('langues d’interface') }
	]);

	let navItems = $derived([
		{ id: 'ep-pourqui', label: t('Pour qui ?') },
		{ id: 'ep-hotstrings', label: 'Hotstrings' },
		{ id: 'ep-ia', label: t('IA') },
		{ id: 'ep-tapholds', label: 'Tap-Holds' },
		{ id: 'ep-raccourcis', label: t('Raccourcis') },
		{ id: 'ep-trackpad', label: 'Trackpad' },
		{ id: 'ep-metriques', label: t('Métriques') },
		{ id: 'ep-confidentialite', label: t('Vie privée') },
		{ id: 'ep-personnalisation', label: t('Réglages') },
		{ id: 'ep-ergopti', label: t('Déjà en Ergopti ?') },
		{ id: 'ep-comparatif', label: t('Comparatif') },
		{ id: 'ep-faq', label: 'FAQ' },
		{ id: 'ep-telecharger', label: t('Télécharger') }
	]);

	// SEO structured data (schema.org): the application itself plus the FAQ,
	// serialized once in French — the page's canonical language. The script
	// tag is assembled from split halves because Svelte ends a component
	// script at the first literal closing tag it sees, even inside a string
	const stripTags = (html) => html.replace(/<[^>]+>/g, '');
	const jsonLd =
		'<scr' +
		'ipt type="application/ld+json">' +
		JSON.stringify([
			{
				'@context': 'https://schema.org',
				'@type': 'SoftwareApplication',
				name: 'Ergopti+',
				operatingSystem: 'Windows, macOS, Linux',
				applicationCategory: 'UtilitiesApplication',
				offers: { '@type': 'Offer', price: '0', priceCurrency: 'EUR' },
				url: 'https://ergopti.fr/ergopti-plus',
				description: `Ergopti+ transforme votre frappe en temps réel : ${data.hotstringTotal} expansions et corrections, prédictions IA 100 % locales, tap-holds, gestes trackpad, métriques de frappe. Gratuit et open-source.`
			},
			{
				'@context': 'https://schema.org',
				'@type': 'FAQPage',
				mainEntity: FAQ_DATA.map((f) => ({
					'@type': 'Question',
					name: f.q,
					acceptedAnswer: { '@type': 'Answer', text: stripTags(f.a) }
				}))
			}
		]) +
		'</scr' +
		'ipt>';

	onMount(async () => {
		restoreLang();
		restoreOS();
		ui.release = await getRelease();

		// Live GitHub trust signals (stars + licence). Best-effort: if the
		// unauthenticated API is rate-limited or offline, the badges stay hidden.
		try {
			const r = await fetch('https://api.github.com/repos/adrienm7/ergopti');
			if (r.ok) {
				const d = await r.json();
				ui.repo = { stars: d.stargazers_count ?? 0, license: d.license?.spdx_id || '' };
			}
		} catch (_) {
			/* ignore — trust badges are optional */
		}
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
	<!-- The GitHub star badge fetches on mount — warm the connection up front -->
	<link rel="preconnect" href="https://api.github.com" crossorigin="anonymous" />
	{@html jsonLd}
</svelte:head>

<!--
  The site-wide layout (+layout.svelte) and the shared Header expect these
  IDs to exist on every page:
    #main-content — scanned by makeIds() on each afterUpdate
    #page-toc-pc, #page-toc — moved around by Header.toggleOverflowMenu()
  This page uses a custom marketing layout, so it renders hidden stubs to
  keep those layout $effects from throwing.
-->
<div id="main-content" class="ep-shell">
	<div id="page-toc-pc" style="display: none">
		<div id="page-toc"></div>
	</div>

	<main class="ep-main">
		<div class="ep-root">
			<!-- Top bar: language selector + temporary link to the old page -->
			<div class="ep-topbar">
				<LangToggle />
				<p class="legacy-link">
					<a href="ergopti-plus-old"
						>{t('Ancienne version de cette page →')}</a
					>
				</p>
			</div>

			<Hero />
			<KpiStrip items={kpis} />
			<StickyNav items={navItems} />
			<Promises />
			<Personas />
			<Hotstrings categories={data.hotstringCategories} total={data.hotstringTotal} geo={winGeo} />
			<PersonalHotstrings geo={winGeo} />
			<AiSection
				catalog={data.aiProviders}
				totals={{
					providers: data.aiTotalProviders,
					models: data.aiTotalModels,
					families: data.aiTotalFamilies
				}}
				range={data.aiParamRange}
				apiProviders={data.apiProviders}
				profiles={data.aiProfiles}
				defaults={data.llmDefaults}
				geo={winGeo}
			/>
			<KeyboardPower actionGroups={data.actionGroups} />
			<Trackpad />
			<MetricsSection geo={winGeo} />
			<Privacy />
			<Customization locales={data.locales} webviews={data.webviews} geo={winGeo} />
			<ErgoptiExclusives />
			<Compare />
			<Steps />
			<Faq />
			<Platforms macosApps={data.macosApps} />

			<div class="ep-endspace"></div>
		</div>
	</main>

	<StickyCta />
</div>

<style>
	.ep-topbar {
		align-items: center;
		display: flex;
		gap: 14px;
		justify-content: space-between;
		margin: 10px 0 0;
	}

	.legacy-link {
		margin: 0;
		text-align: right;
	}

	.legacy-link a {
		color: rgba(255, 255, 255, 0.35);
		font-size: 0.78rem;
		text-decoration: none;
		transition: color 0.25s ease;
	}

	.legacy-link a:hover {
		color: rgba(255, 255, 255, 0.7);
		text-decoration: underline;
	}

	.ep-endspace {
		height: clamp(56px, 8vw, 110px);
	}
</style>
