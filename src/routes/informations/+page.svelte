<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import Autocritiques from './autocritiques.svelte';
	import Contact from './contact.svelte';
	import GeneseSources from './genese_sources.svelte';
	import License from './license.svelte';
</script>

<svelte:head>
	<title>Informations</title>
	<meta name="description" content="Informations sur la disposition HyperTexte" />
</svelte:head>

<GeneseSources></GeneseSources>
<Autocritiques></Autocritiques>
<License></License>
<Contact></Contact>
