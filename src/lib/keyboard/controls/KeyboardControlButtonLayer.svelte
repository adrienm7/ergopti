<script>
	import { createEventDispatcher } from 'svelte';
	const dispatch = createEventDispatcher();

	export let plusValue;
	export let layerValue;

	const baseLayers = [
		['Visuel', 'Visuel'],
		['➀ Primaire', 'Primary'],
		['➁ Shift', 'Shift'],
		['➂ AltGr', 'AltGr'],
		['➃ Shift + AltGr', 'ShiftAltGr'],
		['Ctrl', 'Ctrl'],
		['Circonflexe', 'Circonflexe'],
		['Circonflexe Shift', 'CirconflexeShift'],
		['Tréma', 'Trema'],
		['Tréma Shift', 'TremaShift'],
		['Grec', 'Greek'],
		['Grec Shift', 'GreekShift'],
		['Exposant', 'Exposant'],
		['Indice', 'Indice'],
		['ℝ', 'R']
	];

	const extraLayers = [
		['★ Layer', 'Layer'],
		['★ Virgule', ','],
		['★ À', 'À']
	];

	// Pick the right list depending on plusValue
	$: availableLayers = plusValue === 'yes' ? baseLayers.concat(extraLayers) : baseLayers;

	function changeLayer(newLayer) {
		layerValue = newLayer;
		dispatch('message', { layer: newLayer });
	}
</script>

<keyboard-control-layer>
	<select bind:value={layerValue} on:change={() => changeLayer(layerValue)}>
		{#each availableLayers as [label, value]}
			<option {value}>{label}</option>
		{/each}
	</select>
</keyboard-control-layer>
