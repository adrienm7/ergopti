<!-- src/routes/ergopti-plus/ia/+page.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ — IA
DESCRIPTION:
Sub-page of the Ergopti+ section; it loads only its own sections. The shell
(language, version, local navigation, sticky download) is ../+layout.svelte.
==============================================================================
-->

<script>
	import { t } from '../i18n.svelte.js';
	import AiSection from '../AiSection.svelte';

	// Populated at build time by +page.server.js from the driver's data files.
	let { data } = $props();

	// Window geometry lookup for the embedded driver frames.
	let winGeo = $derived(Object.fromEntries(data.webviews.map((w) => [w.id, w])));
</script>

<svelte:head>
	<title>{t('IA — Ergopti+')}</title>
	<meta
		name="description"
		content={t(
			'Les prédictions par IA d’Ergopti+ : modèles locaux ou distants, profils et réglages.'
		)}
	/>
</svelte:head>

<h1 class="ep-subpage-title">{t('IA')}</h1>

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
