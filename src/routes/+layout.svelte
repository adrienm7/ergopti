<script>
	import Header from './Header.svelte';

	import '$lib/css/normalize.css';
	import '$lib/css/global.css';
	import '$lib/css/typography.css';
	import '$lib/css/buttons.css';
	import '$lib/css/miscellaneous.css';

	const date = new Date().getFullYear();
</script>

<div id="page">
	<main>
		<Header />
		<slot />
	</main>

	<footer>
		<p>Copyright © {date} <strong>HyperTexte</strong></p>
	</footer>
</div>
