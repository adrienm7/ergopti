<!-- src/routes/ergopti-plus/fonctionnalites/+page.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ — Fonctionnalités
DESCRIPTION:
Sub-page of the Ergopti+ section; it loads only its own sections. The shell
(language, version, local navigation, sticky download) is ../+layout.svelte.
==============================================================================
-->

<script>
	import { t } from '../i18n.svelte.js';
	import KeyboardPower from '../KeyboardPower.svelte';
	import Trackpad from '../Trackpad.svelte';
	import MetricsSection from '../MetricsSection.svelte';

	// Populated at build time by +page.server.js from the driver's data files.
	let { data } = $props();

	// Window geometry lookup for the embedded driver frames.
	let winGeo = $derived(Object.fromEntries(data.webviews.map((w) => [w.id, w])));
</script>

<svelte:head>
	<title>{t('Fonctionnalités — Ergopti+')}</title>
	<meta
		name="description"
		content={t('Les tap-holds, raccourcis, gestes trackpad et métriques de frappe d’Ergopti+.')}
	/>
</svelte:head>

<h1 class="ep-subpage-title">{t('Fonctionnalités')}</h1>

<KeyboardPower actionGroups={data.actionGroups} />
<Trackpad />
<MetricsSection geo={winGeo} />
