<script>
	import '$lib/keyboard/KeyboardControlButtons.css';
	import { Keyboard } from '$lib/keyboard/Keyboard.js';
	import { onMount } from 'svelte';

	import ChangementType from '$lib/keyboard/controles/ChangementType.svelte';
	import ChangementCouleur from '$lib/keyboard/controles/ChangementCouleur.svelte';
	import ChangementPlus from '$lib/keyboard/controles/ChangementPlus.svelte';
	import ChangementCouche from '$lib/keyboard/controles/ChangementCouche.svelte';

	export let nom;
	let infos_clavier;
	let clavier = new Keyboard(nom);
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
			currentData['layer'] = event.detail.layer;
			return currentData;
		});
		clavier.majClavier();
	}
</script>

<controles-clavier id={'controles_' + nom}>
	<ChangementType
		on:message={handleMessage}
		coucheValue={infos_clavier.layer}
		typeValue={infos_clavier.type}
		couleurValue={infos_clavier.couleur}
		plusValue={infos_clavier.plus}
	/>
	<ChangementPlus
		on:message={handleMessage}
		coucheValue={infos_clavier.layer}
		typeValue={infos_clavier.type}
		couleurValue={infos_clavier.couleur}
		plusValue={infos_clavier.plus}
	/>
	<ChangementCouleur
		on:message={handleMessage}
		coucheValue={infos_clavier.layer}
		typeValue={infos_clavier.type}
		couleurValue={infos_clavier.couleur}
		plusValue={infos_clavier.plus}
	/>
	<ChangementCouche
		on:message={handleMessage}
		coucheValue={infos_clavier.layer}
		typeValue={infos_clavier.type}
		couleurValue={infos_clavier.couleur}
		plusValue={infos_clavier.plus}
	/>
</controles-clavier>
