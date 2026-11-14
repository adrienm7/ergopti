<!-- src/routes/ergopti-plus/installation/+page.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ — Installation
DESCRIPTION:
Sub-page of the Ergopti+ section; it loads only its own sections. The shell
(language, version, local navigation, sticky download) is ../+layout.svelte.
==============================================================================
-->

<script>
	import { t } from '../i18n.svelte.js';
	import Steps from '../Steps.svelte';
	import Platforms from '../Platforms.svelte';

	// Populated at build time by +page.server.js from the driver's data files.
	let { data } = $props();
</script>

<svelte:head>
	<title>{t('Installation — Ergopti+')}</title>
	<meta
		name="description"
		content={t('Démarrer avec Ergopti+ et le télécharger pour Windows, macOS ou Linux.')}
	/>
</svelte:head>

<h1 class="ep-subpage-title">{t('Installation')}</h1>

<Steps />
<Platforms macosApps={data.macosApps} />
