<script>
	import Ergopti from '#lib/components/Ergopti.svelte';
	import ErgoptiPlus from '#lib/components/ErgoptiPlus.svelte';
	import SFB from '#lib/components/SFB.svelte';

	import IntroductionInformations from './introduction_informations.svelte';
	import Autocritiques from './autocritiques.svelte';
	import Changelog from './changelog.svelte';
	import Contact from './contact.svelte';
	import GeneseSources from './genese_sources.svelte';
	import Licence from './licence.svelte';
	import PageWrapper from '#lib/components/PageWrapper.svelte';
</script>

<svelte:head>
	<title>Informations sur la Disposition Ergopti</title>
	<meta
		name="description"
		content="Genèse, autocritiques, historique des versions, licence et contact de la Disposition Ergopti"
	/>
</svelte:head>

<PageWrapper>
	<svelte:fragment slot="introduction">
		<bloc-introduction>
			<IntroductionInformations />
		</bloc-introduction>
	</svelte:fragment>

	<GeneseSources></GeneseSources>
	<Autocritiques></Autocritiques>
	<Changelog></Changelog>
	<Licence></Licence>
	<Contact></Contact>
</PageWrapper>
