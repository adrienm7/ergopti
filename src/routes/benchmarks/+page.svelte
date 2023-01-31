<svelte:head>
	<title>Benchmarks</title>
	<meta name="description" content="About this app" />
</svelte:head>

<h1>Benchmarks</h1>
<h2>Comment utiliser KLAnext</h2>
<p>
	Pour bien utiliser des comparateurs de disposition, il faut comparer ce qui est comparable. Ainsi,
	ne comparez pas une disposition ISO avec une disposition Ergodox. Sinon, logiquement la
	disposition Ergodox sera mieux notée. Celle-ci aure en effet une distancec aux touches moindre,
	car les pouces seront bien mieux mis à contribution.
</p>
<mini-espace />
<p>
	Un autre point à bien faire attention est de <strong
		>s’assurer que toutes les lettres soient bien dans les dispositions à comparer</strong
	>. Une disposition faite pour la langue anglaise aura de très bons scores pour des textes
	français. Cela s’explique parce que tous les caractères accentuées seront "sautés", n’existant pas
	dans la disposition.
</p>
<mini-espace />
<p class="text-bold">
	➜ Comparer ce qui est comparable. Si le symbole n’existe pas dans la disposition, la touche ne
	sera pas tapée.
</p>

<h2>Résultats de benchmarks</h2>
<p>Les résultats vont différer selon le corpus utilisé</p>

<div class="image">
	<p>Benchmark sur du code informatique</p>
	<img src="/img/benchmark_code.jpg" />
	<p>Benchmark sur de l’anglais</p>
	<img src="/img/benchmark_english.jpg" />
</div>

<style>
	.image {
		margin: 0 auto;
		text-align: center;
	}

	.image img {
		width: 80%;
		margin: 0 auto;
		border-radius: 10px;
		text-align: center;
	}

	.image p {
		font-size: 1.3rem;
		font-weight: bold;
	}

</style>
