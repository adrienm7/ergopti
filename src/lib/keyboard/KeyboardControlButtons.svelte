<script>
	import '$lib/keyboard/KeyboardControlButtons.css';
	import { Keyboard } from '$lib/keyboard/Keyboard.js';
	import { onMount } from 'svelte';

	import ChangementType from '$lib/keyboard/controls/ChangementType.svelte';
	import ChangementCouleur from '$lib/keyboard/controls/ChangementCouleur.svelte';
	import ChangementPlus from '$lib/keyboard/controls/ChangementPlus.svelte';
	import ChangementCouche from '$lib/keyboard/controls/ChangementCouche.svelte';

	export let name;
	let keyboardConfiguration;
	let clavier = new Keyboard(name);
	clavier.data_clavier.subscribe((value) => {
		keyboardConfiguration = value;
	});
	onMount(() => {
		clavier.updateKeyboard();
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
		clavier.updateKeyboard();
	}
</script>

<keyboard-controls id={'controls_' + name}>
	<ChangementType
		on:message={handleMessage}
		layerValue={keyboardConfiguration.layer}
		typeValue={keyboardConfiguration.type}
		couleurValue={keyboardConfiguration.couleur}
		plusValue={keyboardConfiguration.plus}
	/>
	<ChangementPlus
		on:message={handleMessage}
		layerValue={keyboardConfiguration.layer}
		typeValue={keyboardConfiguration.type}
		couleurValue={keyboardConfiguration.couleur}
		plusValue={keyboardConfiguration.plus}
	/>
	<ChangementCouleur
		on:message={handleMessage}
		layerValue={keyboardConfiguration.layer}
		typeValue={keyboardConfiguration.type}
		couleurValue={keyboardConfiguration.couleur}
		plusValue={keyboardConfiguration.plus}
	/>
	<ChangementCouche
		on:message={handleMessage}
		layerValue={keyboardConfiguration.layer}
		typeValue={keyboardConfiguration.type}
		couleurValue={keyboardConfiguration.couleur}
		plusValue={keyboardConfiguration.plus}
	/>
</keyboard-controls>
