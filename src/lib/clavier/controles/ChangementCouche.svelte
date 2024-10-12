<script>
	import { createEventDispatcher } from 'svelte';
	const dispatch = createEventDispatcher();

	export let typeValue;
	export let coucheValue;
	export let couleurValue;
	export let plusValue;

	let couches_standard = [
		['Visuel', 'Visuel'],
		['➀ Primaire', 'Primary'],
		['➁ Shift', 'Shift'],
		['➂ AltGr', 'AltGr'],
		['➃ Shift + AltGr', 'ShiftAltGr'],
		['Ctrl', 'Ctrl'],
		['Circonflexe', '^'],
		['Tréma', 'trema'],
		['Exposant', 'e'],
		['Indice', 'i'],
		['ℝ', 'R']
	];
	let couches_plus = couches_standard.concat([
		['★ Layer', 'Layer'],
		['★ Virgule', ','],
		['★ À', 'À']
	]);

	function toggleCouche(nouvelleCouche) {
		coucheValue = nouvelleCouche;
		dispatch('message', {
			type: typeValue,
			couche: coucheValue,
			couleur: couleurValue,
			plus: plusValue
		});
	}
</script>

<div class="select-degrade">
	{#if plusValue === 'oui'}
		<select bind:value={coucheValue} on:change={() => toggleCouche(coucheValue)}>
			{#each couches_plus as value}<option value={value[1]}>{value[0]}</option>{/each}
		</select>
	{:else}
		<select bind:value={coucheValue} on:change={() => toggleCouche(coucheValue)}>
			{#each couches_standard as value}<option value={value[1]}>{value[0]}</option>{/each}
		</select>
	{/if}
</div>
