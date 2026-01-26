<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import KeyboardBasis from '$lib/keyboard/KeyboardBasis.svelte';
	import KeyboardControls from '$lib/keyboard/controls/KeyboardControls.svelte';
	import Layout from './+layout.svelte';

	import AlternanceMains from './accueil/alternance_mains.svelte';
	import DistanceDoigtsTouches from './accueil/distance_doigts_touches.svelte';
	import MinimisationSfbs from './accueil/minimisation_sfbs.svelte';
	import PlacementLogiqueTouches from './accueil/placement_logique_touches.svelte';
	import ChiffresAccesDirect from './accueil/chiffres_acces_direct.svelte';
	import UtilisationUneMain from './accueil/utilisation_une_main.svelte';
	import OptimisationRoulements from './accueil/optimisation_roulements.svelte';
	import IntroductionDisposition from './accueil/introduction_ergopti.svelte';
	import EspaceInsecableAutomatique from './accueil/espace_insecable_automatique.svelte';
	import DispositionPlus from './accueil/ergopti_plus.svelte';
	import PageWrapper from './PageWrapper.svelte';
</script>

<svelte:head>
	<title>Disposition Ergopti</title>
	<meta
		name="description"
		content="Ergopti, une disposition clavier ergonomique optimisée pour le français, l'anglais et le code"
	/>
</svelte:head>

<PageWrapper>
	<svelte:fragment slot="introduction">
		<bloc-introduction>
			<IntroductionDisposition />
		</bloc-introduction>
	</svelte:fragment>

	<DistanceDoigtsTouches />
	<MinimisationSfbs />
	<AlternanceMains />
	<OptimisationRoulements />
	<ChiffresAccesDirect />
	<PlacementLogiqueTouches />
	<EspaceInsecableAutomatique />
	<UtilisationUneMain />

	<svelte:fragment slot="bloc-fin">
		<bloc-fin>
			<DispositionPlus />
		</bloc-fin>
	</svelte:fragment>
</PageWrapper>
