<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
	import AlternanceMains from './alternance_mains.svelte';
	import DistanceDoigtsTouches from './distance_doigts_touches.svelte';
	import MinimisationSfbs from './minimisation_sfbs.svelte';
	import PlacementLogiqueTouches from './placement_logique_touches.svelte';
	import ChiffresAccesDirect from './chiffres_acces_direct.svelte';
	import UtilisationUneMain from './utilisation_une_main.svelte';
	import OptimisationRoulements from './optimisation_roulements.svelte';
</script>

<DistanceDoigtsTouches />
<MinimisationSfbs />
<AlternanceMains />
<OptimisationRoulements />
<PlacementLogiqueTouches />
<ChiffresAccesDirect />
<UtilisationUneMain />
