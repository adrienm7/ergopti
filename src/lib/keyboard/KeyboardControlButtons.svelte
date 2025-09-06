<script>
	import '$lib/keyboard/KeyboardControlButtons.css';
	import { Keyboard } from '$lib/keyboard/Keyboard.js';
	import { onMount } from 'svelte';

	import ChangementType from '$lib/keyboard/controls/ChangementType.svelte';
	import ChangementCouleur from '$lib/keyboard/controls/ChangementCouleur.svelte';
	import ChangementPlus from '$lib/keyboard/controls/ChangementPlus.svelte';
	import ChangementCouche from '$lib/keyboard/controls/ChangementCouche.svelte';

	export let nom;
	let keyboardInformation;
	let clavier = new Keyboard(nom);
	clavier.data_clavier.subscribe((value) => {
		keyboardInformation = value;
	});
	onMount(() => {
		clavier.keyboardUpdate();
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
		clavier.keyboardUpdate();
	}
</script>

<keyboard-controls id={'controls_' + nom}>
	<ChangementType
		on:message={handleMessage}
		layerValue={keyboardInformation.layer}
		typeValue={keyboardInformation.type}
		couleurValue={keyboardInformation.couleur}
		plusValue={keyboardInformation.plus}
	/>
	<ChangementPlus
		on:message={handleMessage}
		layerValue={keyboardInformation.layer}
		typeValue={keyboardInformation.type}
		couleurValue={keyboardInformation.couleur}
		plusValue={keyboardInformation.plus}
	/>
	<ChangementCouleur
		on:message={handleMessage}
		layerValue={keyboardInformation.layer}
		typeValue={keyboardInformation.type}
		couleurValue={keyboardInformation.couleur}
		plusValue={keyboardInformation.plus}
	/>
	<ChangementCouche
		on:message={handleMessage}
		layerValue={keyboardInformation.layer}
		typeValue={keyboardInformation.type}
		couleurValue={keyboardInformation.couleur}
		plusValue={keyboardInformation.plus}
	/>
</keyboard-controls>
