<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import IntroductionDispositionPlus from './introduction_ergopti_plus.svelte';
	import Menu from './menu.svelte';
	import Abreviations from './abreviations.svelte';
	import Confort from './confort.svelte';
	import Raccourcis from './raccourcis.svelte';
	import Roulements from './roulements.svelte';
	import Reduction_SFBs from './reduction_sfbs.svelte';
	import PageWrapper from '../PageWrapper.svelte';
</script>

<svelte:head>
	<title>Ergopti+</title>
	<meta name="description" content="Disposition Ergopti+" />
</svelte:head>

<PageWrapper>
	<svelte:fragment slot="introduction">
		<bloc-introduction>
			<IntroductionDispositionPlus />
		</bloc-introduction>
	</svelte:fragment>

	<Menu />
	<Confort />
	<Roulements />
	<Reduction_SFBs />
	<Abreviations />
	<Raccourcis />
</PageWrapper>
