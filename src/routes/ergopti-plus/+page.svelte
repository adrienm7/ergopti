<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import Menu from './menu.svelte';
	import Abreviations from './abreviations.svelte';
	import Confort from './confort.svelte';
	import Raccourcis from './raccourcis.svelte';
	import Roulements from './roulements.svelte';
	import Reduction_SFBs from './reduction_sfbs.svelte';
</script>

<svelte:head>
	<title>Ergopti+</title>
	<meta name="description" content="Disposition Ergopti+" />
</svelte:head>

<Menu />
<Confort />
<Roulements />
<Reduction_SFBs />
<Abreviations />
<Raccourcis />
