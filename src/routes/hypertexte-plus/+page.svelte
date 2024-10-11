<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import Abreviations from './abreviations.svelte';
	import Confort from './confort.svelte';
	import Raccourcis from './raccourcis.svelte';
	import Roulements from './roulements.svelte';
	import Reduction_SFBs from './reduction_sfbs.svelte';
	import IntroductionHypertextePlus from './introduction_hypertexte_plus.svelte';
</script>

<svelte:head>
	<title>HyperTexte +</title>
	<meta name="description" content="Découvrez HyperTexte +" />
</svelte:head>

<Confort />
<Roulements />
<Reduction_SFBs />
<Abreviations />
<Raccourcis />
