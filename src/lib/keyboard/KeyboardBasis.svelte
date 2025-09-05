<script>
	import '$lib/keyboard/Keyboard.css';
	import { Keyboard } from '$lib/keyboard/Keyboard.js';
	import { onMount, afterUpdate } from 'svelte';

	export let nom;
	let clavier = new Keyboard(nom);
	onMount(() => {
		clavier.keyboardUpdate();
	});
</script>

<bloc-clavier id={'clavier_' + nom}>
	{#each Array(7) as _, i}
		<bloc-ligne data-row={i + 1}>
			{#each Array(16) as _, j}
				<bloc-touche data-key="vide" data-row={i + 1} data-column={j} style="--size: 1;">
					<div>&nbsp;</div>
				</bloc-touche>
			{/each}
		</bloc-ligne>
	{/each}
</bloc-clavier>
