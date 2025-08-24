<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import { page } from '$app/stores';
	const date = new Date().getFullYear();
</script>

<footer>
	<p>
		Disposition <Ergopti></Ergopti> —
		<a href="https://github.com/adrienm7/ergopti" style="color:white"
			>GitHub <i class="icon-github"></i></a
		>
		|
		<a href="https://discord.gg/ptxRzBqcQP" style="position:relative; bottom:-0.1em; color:white"
			>Discord <i class="icon-discord"></i></a
		>
	</p>
</footer>

<style>
	:root {
		--hauteur-footer: 60px;
	}

	footer {
		display: flex;
		justify-content: center;
		align-items: center;
		margin: 0;
		box-shadow: 0 0 3px 2px var(--couleur-ombre);
		background-color: rgba(0, 0, 0, 0.8);
		padding: 2px;
		height: var(--hauteur-footer);
		color: white;
	}

	footer p {
		font-size: 0.9rem;
		text-align: center;
	}
</style>
