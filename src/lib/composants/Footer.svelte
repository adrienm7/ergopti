<script>
	import Nom from '$lib/composants/Nom.svelte';
	import { page } from '$app/stores';
	const date = new Date().getFullYear();
</script>

<footer>
	<p>
		Disposition <Nom></Nom> — <a href="https://github.com/adrienm7/ergopti">Repo GitHub</a>
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
</style>
