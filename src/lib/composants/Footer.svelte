<script>
	import Nom from '$lib/composants/Nom.svelte';
	import { page } from '$app/stores';
	const date = new Date().getFullYear();
</script>

<footer>
	<p>
		<a href="https://github.com/adrienm7/ergopti"><i class="fa-brands fa-github"></i></a>
		Disposition <Nom></Nom>
		<a href="https://discord.gg/ptxRzBqcQP" style="position:relative; bottom:-0.1em"
			><i class="fa-brands fa-discord"></i></a
		>
	</p>
</footer>

<style>
	:root {
		--hauteur-footer: 60px;
	}

	footer {
		display: flex;
		align-items: center;
		justify-content: center;
		height: var(--hauteur-footer);
		margin: 0;
		padding: 2px;
		background-color: rgba(0, 0, 0, 0.8);
		color: white;
		box-shadow: 0 0 3px 2px var(--couleur-ombre);
	}

	footer p {
		font-size: 0.9rem;
		text-align: center;
	}

	footer i::before {
		-webkit-background-clip: text;
		background-clip: text;
		-webkit-text-fill-color: transparent;
		color: transparent;
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		background-image: linear-gradient(to right, white, white);
	}
</style>
