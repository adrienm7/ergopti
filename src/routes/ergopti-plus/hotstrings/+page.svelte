<!-- src/routes/ergopti-plus/hotstrings/+page.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ — Hotstrings
DESCRIPTION:
Sub-page of the Ergopti+ section; it loads only its own sections. The shell
(language, version, local navigation, sticky download) is ../+layout.svelte.
==============================================================================
-->

<script>
	import { t } from '../i18n.svelte.js';
	import Hotstrings from '../Hotstrings.svelte';
	import PersonalHotstrings from '../PersonalHotstrings.svelte';

	// Populated at build time by +page.server.js from the driver's data files.
	let { data } = $props();

	// Window geometry lookup for the embedded driver frames.
	let winGeo = $derived(Object.fromEntries(data.webviews.map((w) => [w.id, w])));
</script>

<svelte:head>
	<title>{t('Hotstrings — Ergopti+')}</title>
	<meta
		name="description"
		content={t('Les hotstrings d’Ergopti+ : expansions, corrections et vos propres hotstrings.')}
	/>
</svelte:head>

<h1 class="ep-subpage-title">{t('Hotstrings')}</h1>

<Hotstrings categories={data.hotstringCategories} total={data.hotstringTotal} geo={winGeo} />
<PersonalHotstrings geo={winGeo} />
