<script>
	import ChangementType from '$lib/clavier/controles/ChangementType.svelte';
	import ChangementCouleur from '$lib/clavier/controles/ChangementCouleur.svelte';
	import ChangementPlus from '$lib/clavier/controles/ChangementPlus.svelte';
	import ChangementCouche from '$lib/clavier/controles/ChangementCouche.svelte';

	import { Clavier } from '$lib/clavier/FonctionsClavier.js';
	import { onMount } from 'svelte';

	export let nom;
	let infos_clavier;
	let clavier = new Clavier(nom);
	clavier.data_clavier.subscribe((value) => {
		infos_clavier = value;
	});
	onMount(() => {
		clavier.majClavier();
	});

	let texte = '';

	function handleMessage(event) {
		// Permet de mettre à jour les données du clavier en fonction des contrôles
		clavier.data_clavier.update((currentData) => {
			currentData['type'] = event.detail.type;
			currentData['couleur'] = event.detail.couleur;
			currentData['plus'] = event.detail.plus;
			currentData['couche'] = event.detail.couche;
			return currentData;
		});
		clavier.majClavier();
	}
</script>

<controles-clavier id={'controles_' + nom}>
	<ChangementType
		on:message={handleMessage}
		coucheValue={infos_clavier.couche}
		typeValue={infos_clavier.type}
		couleurValue={infos_clavier.couleur}
		plusValue={infos_clavier.plus}
	/>
	<ChangementPlus
		on:message={handleMessage}
		coucheValue={infos_clavier.couche}
		typeValue={infos_clavier.type}
		couleurValue={infos_clavier.couleur}
		plusValue={infos_clavier.plus}
	/>
	<ChangementCouleur
		on:message={handleMessage}
		coucheValue={infos_clavier.couche}
		typeValue={infos_clavier.type}
		couleurValue={infos_clavier.couleur}
		plusValue={infos_clavier.plus}
	/>
	<ChangementCouche
		on:message={handleMessage}
		coucheValue={infos_clavier.couche}
		typeValue={infos_clavier.type}
		couleurValue={infos_clavier.couleur}
		plusValue={infos_clavier.plus}
	/>
</controles-clavier>
