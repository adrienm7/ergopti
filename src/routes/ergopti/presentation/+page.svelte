<script>
	import Ergopti from '#lib/components/Ergopti.svelte';
	import ErgoptiPlus from '#lib/components/ErgoptiPlus.svelte';
	import SFB from '#lib/components/SFB.svelte';

	import KeyboardBasis from '#lib/keyboard/KeyboardBasis.svelte';
	import KeyboardControls from '#lib/keyboard/controls/KeyboardControls.svelte';

	import AlternanceMains from './alternance_mains.svelte';
	import DistanceDoigtsTouches from './distance_doigts_touches.svelte';
	import MinimisationSfbs from './minimisation_sfbs.svelte';
	import PlacementLogiqueTouches from './placement_logique_touches.svelte';
	import ChiffresAccesDirect from './chiffres_acces_direct.svelte';
	import UtilisationUneMain from './utilisation_une_main.svelte';
	import OptimisationRoulements from './optimisation_roulements.svelte';
	import IntroductionDisposition from './introduction_ergopti.svelte';
	import EspaceInsecableAutomatique from './espace_insecable_automatique.svelte';
	import DispositionPlus from './ergopti_plus.svelte';
	import PageWrapper from '#lib/components/PageWrapper.svelte';
</script>

<svelte:head>
	<title>Présentation de la Disposition Ergopti</title>
	<meta
		name="description"
		content="La Disposition Ergopti, une disposition clavier ergonomique optimisée pour le français, l’anglais et le code : ses principes et ses choix"
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
