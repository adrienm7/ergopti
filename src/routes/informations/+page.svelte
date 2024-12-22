<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import Autocritiques from './autocritiques.svelte';
	import Changelog from './changelog.svelte';
	import Contact from './contact.svelte';
	import GeneseSources from './genese_sources.svelte';
	import Licence from './licence.svelte';
</script>

<svelte:head>
	<title>Informations</title>
	<meta name="description" content="Informations sur la disposition Ergopti" />
</svelte:head>

<GeneseSources></GeneseSources>
<Autocritiques></Autocritiques>
<Changelog></Changelog>
<Licence></Licence>
<Contact></Contact>
