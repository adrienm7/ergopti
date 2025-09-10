<script>
	import { createEventDispatcher } from 'svelte';
	const dispatch = createEventDispatcher();

	export let plusValue;
	export let typeValue;
	export let colorValue;
	export let layerValue;

	let couches_standard = [
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
	let couches_plus = couches_standard.concat([
		['★ Layer', 'Layer'],
		['★ Virgule', ','],
		['★ À', 'À']
	]);

	function toggleCouche(nouvelleCouche) {
		layerValue = nouvelleCouche;
		dispatch('message', {
			plus: plusValue,
			type: typeValue,
			color: colorValue,
			layer: layerValue
		});
	}
</script>

<keyboard-control-layer>
	{#if plusValue === 'yes'}
		<select bind:value={layerValue} on:change={() => toggleCouche(layerValue)}>
			{#each couches_plus as value}<option value={value[1]}>{value[0]}</option>{/each}
		</select>
	{:else}
		<select bind:value={layerValue} on:change={() => toggleCouche(layerValue)}>
			{#each couches_standard as value}<option value={value[1]}>{value[0]}</option>{/each}
		</select>
	{/if}
</keyboard-control-layer>
