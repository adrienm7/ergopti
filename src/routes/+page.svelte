<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
	import BlocControlesClavier from '$lib/clavier/BlocControlesClavier.svelte';
	import Layout from './+layout.svelte';

	import AlternanceMains from './accueil/alternance_mains.svelte';
	import DistanceDoigtsTouches from './accueil/distance_doigts_touches.svelte';
	import MinimisationSfbs from './accueil/minimisation_sfbs.svelte';
	import PlacementLogiqueTouches from './accueil/placement_logique_touches.svelte';
	import ChiffresAccesDirect from './accueil/chiffres_acces_direct.svelte';
	import UtilisationUneMain from './accueil/utilisation_une_main.svelte';
	import OptimisationRoulements from './accueil/optimisation_roulements.svelte';
	import IntroductionHypertexte from './accueil/introduction_ergopti.svelte';
	import EspaceInsecableAutomatique from './accueil/espace_insecable_automatique.svelte';
</script>

<svelte:head>
	<title>Disposition Ergopti</title>
	<meta
		name="description"
		content="Ergopti, une disposition clavier ergonomique optimisée pour le français, l’anglais et le code"
	/>
</svelte:head>

<DistanceDoigtsTouches />
<MinimisationSfbs />
<AlternanceMains />
<OptimisationRoulements />
<ChiffresAccesDirect />
<PlacementLogiqueTouches />
<EspaceInsecableAutomatique />
<UtilisationUneMain />
