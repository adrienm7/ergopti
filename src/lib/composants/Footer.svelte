<script>
	import { page } from '$app/stores';
	const date = new Date().getFullYear();
</script>

<footer>
	<p>Copyright © {date} — <strong>HyperTexte</strong></p>
</footer>

<style>
	footer {
		display: block;
		margin: 0;
		margin-top: 10vh;
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
