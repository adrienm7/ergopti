<script>
	import * as stores_infos from '$lib/stores_infos.js';
	import '$lib/keyboard/controls/KeyboardControls.css';
	import { Keyboard } from '$lib/keyboard/Keyboard.js';
	import { onMount } from 'svelte';

	import KeyboardControlButtonType from '$lib/keyboard/controls/KeyboardControlButtonType.svelte';
	import KeyboardControlButtonColor from '$lib/keyboard/controls/KeyboardControlButtonColor.svelte';
	import KeyboardControlButtonPlus from '$lib/keyboard/controls/KeyboardControlButtonPlus.svelte';
	import KeyboardControlButtonLayer from '$lib/keyboard/controls/KeyboardControlButtonLayer.svelte';

	export let name;
	let keyboardConfiguration;
	let keyboard = new Keyboard(name);
	stores_infos[keyboard.id].subscribe((value) => {
		keyboardConfiguration = value;
	});
	onMount(() => {
		keyboard.updateKeyboard();
	});

	function handleMessage(event) {
		// Permet de mettre à jour les données du clavier en fonction des contrôles
		stores_infos[keyboard.id].update((currentData) => {
			currentData['type'] = event.detail['type'];
			currentData['color'] = event.detail['color'];
			currentData['plus'] = event.detail['plus'];
			currentData['layer'] = event.detail['layer'];
			return currentData;
		});
		keyboard.updateKeyboard();
	}
</script>

<keyboard-controls id={'controls_' + name}>
	<KeyboardControlButtonType
		on:message={handleMessage}
		layerValue={keyboardConfiguration['layer']}
		typeValue={keyboardConfiguration['type']}
		colorValue={keyboardConfiguration['color']}
		plusValue={keyboardConfiguration['plus']}
	/>
	<KeyboardControlButtonPlus
		on:message={handleMessage}
		layerValue={keyboardConfiguration['layer']}
		typeValue={keyboardConfiguration['type']}
		colorValue={keyboardConfiguration['color']}
		plusValue={keyboardConfiguration['plus']}
	/>
	<KeyboardControlButtonColor
		on:message={handleMessage}
		layerValue={keyboardConfiguration['layer']}
		typeValue={keyboardConfiguration['type']}
		colorValue={keyboardConfiguration['color']}
		plusValue={keyboardConfiguration['plus']}
	/>
	<KeyboardControlButtonLayer
		on:message={handleMessage}
		layerValue={keyboardConfiguration['layer']}
		typeValue={keyboardConfiguration['type']}
		colorValue={keyboardConfiguration['color']}
		plusValue={keyboardConfiguration['plus']}
	/>
</keyboard-controls>
