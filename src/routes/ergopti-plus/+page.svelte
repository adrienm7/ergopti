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

	// Populated at build time by +page.server.js from the driver's data files.
	let { data } = $props();

	// Window geometry lookup for the embedded driver frames.
	const winGeo = Object.fromEntries(data.webviews.map((w) => [w.id, w]));

	const kpis = [
		{ value: data.hotstringTotal, suffix: '', label: 'hotstrings prêts à l’emploi' },
		{ value: data.aiTotalModels, suffix: '', label: 'modèles d’IA locale au catalogue' },
		{ value: 335, suffix: '', label: 'réglages, tous optionnels' },
		{ value: data.localesCount, suffix: '', label: 'langues d’interface' }
	];

	const navItems = [
		{ id: 'hotstrings', label: 'Hotstrings' },
		{ id: 'ia', label: 'IA' },
		{ id: 'clavier', label: 'Clavier' },
		{ id: 'trackpad', label: 'Trackpad' },
		{ id: 'metriques', label: 'Métriques' },
		{ id: 'personnalisation', label: 'Réglages' },
		{ id: 'ergopti', label: 'Ergopti' },
		{ id: 'telecharger', label: 'Télécharger' }
	];

	onMount(async () => {
		restoreOS();
		ui.release = await getRelease();
	});
</script>

<svelte:head>
	<title>Ergopti+ — la frappe augmentée, gratuite et locale</title>
	<meta
		name="description"
		content="Ergopti+ transforme votre frappe en temps réel : {data.hotstringTotal} expansions et corrections, prédictions IA 100 % locales ({data.aiTotalModels} modèles), tap-holds, gestes trackpad, métriques de frappe. Gratuit et open-source, sur Windows et macOS (Linux en alpha)."
	/>
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
			<!-- Lien temporaire vers l'ancienne page le temps de valider celle-ci -->
			<p class="legacy-link">
				<a href="ergopti-plus-old">Ancienne version de cette page →</a>
			</p>

			<Hero />
			<KpiStrip items={kpis} />
			<StickyNav items={navItems} />
			<Promises />
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
			<Customization locales={data.locales} webviews={data.webviews} geo={winGeo} />
			<ErgoptiExclusives />
			<Platforms macosApps={data.macosApps} />

			<div class="ep-endspace"></div>
		</div>
	</main>
</div>

<style>
	.legacy-link {
		margin: 10px 0 0;
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
