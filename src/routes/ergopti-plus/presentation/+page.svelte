<!-- src/routes/ergopti-plus/presentation/+page.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ — Présentation
DESCRIPTION:
Sub-page of the Ergopti+ section; it loads only its own sections. The shell
(language, version, local navigation, sticky download) is ../+layout.svelte.
==============================================================================
-->

<script>
	import { t } from '../i18n.svelte.js';
	import Personas from '../Personas.svelte';
	import ErgoptiExclusives from '../ErgoptiExclusives.svelte';
	import Compare from '../Compare.svelte';
</script>

<svelte:head>
	<title>{t('Présentation — Ergopti+')}</title>
	<meta
		name="description"
		content={t(
			'Pour qui est Ergopti+, ce qu’il ajoute à la disposition Ergopti et comment il se compare aux autres outils.'
		)}
	/>
</svelte:head>

<h1 class="ep-subpage-title">{t('Présentation')}</h1>

<Personas />
<ErgoptiExclusives />
<Compare />
