<script>
	import { Keyboard } from '$lib/keyboard/Keyboard.js';
	import { onMount, afterUpdate } from 'svelte';

	export let nom;
	let clavier = new Keyboard(nom);
	onMount(() => {
		clavier.keyboardUpdate();
	});
</script>

<keyboard id={'clavier_' + nom}>
	{#each Array(7) as _, i}
		<keyboard-row data-row={i + 1}>
			{#each Array(16) as _, j}
				<keyboard-key data-key="vide" data-row={i + 1} data-column={j} style="--size: 1;">
					<div>&nbsp;</div>
				</keyboard-key>
			{/each}
		</keyboard-row>
	{/each}
</keyboard>
