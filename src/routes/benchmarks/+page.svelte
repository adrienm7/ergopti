<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/Nom_Plus.svelte';

	function toggleClavier() {
		if (clavier === 'iso') {
			clavier = 'ergodox';
		} else {
			clavier = 'iso';
		}
	}

	function toggleLangue() {
		if (langue === 'fr') {
			langue = 'en';
		} else {
			langue = 'fr';
		}
	}

	let liste_benchmarks_fr = [
		['Essais', 'essais'],
		['Corpus Panaché', 'panache'],
		['Livre de Savoir II', 'LdS'],
		['Romans', 'romans']
	];

	let liste_benchmarks_en = [
		['Chained English Bigrams 7 (1M)', 'chained_english_bigrams7'],
		['Chained Proglish Bigrams 7 (1M)', 'chained_proglish_bigrams7'],
		['Chained Code Bigrams 7 (1M)', 'chained_code_bigrams7']
	];

	let clavier = 'iso';
	let langue = 'fr';
	let corpus_fr = 'essais';
	let corpus_en = 'chained_english_bigrams7';
</script>

<svelte:head>
	<title>Benchmarks</title>
	<meta name="description" content="About this app" />
</svelte:head>

<div class="contenu">
	<h1>Benchmarks</h1>

	<p>
		Il existe de nombreux comparateurs de dispositions, certains ayant même une interface en ligne.
		KLAnext est l’un d’entre eux et peut être gratuitement utilisé à l’adresse <a
			href="https://klanext.keyboard-design.com">https://klanext.keyboard-design.com</a
		>. Il est l’un des plus utilisés en raison de son algorithme de notation qui serait plus "juste"
		que les autres comparateurs du même type.
	</p>

	<h2>Comment bien utiliser KLAnext</h2>

	<p>
		Pour bien utiliser des comparateurs de disposition, il faut comparer ce qui est comparable. Ceci
		est très important. Ainsi, ne comparez pas une disposition ISO avec une disposition Ergodox.
		Sinon, logiquement la disposition Ergodox sera mieux notée. Elle aura en effet une distance aux
		touches moindre, car les pouces seront beaucoup plus mis à contribution. De plus, il y aura
		moins de SFBs, car Shift, Enter, etc. ne seront plus sur les auriculaires mais les pouces.
	</p>
	<mini-espace />
	<p>
		Un autre point à bien faire attention est de <strong
			>s’assurer que toutes les lettres soient bien dans les dispositions à comparer</strong
		>. Une disposition faite pour la langue anglaise aura de très bons scores pour des textes
		français. Cela s’explique parce que tous les caractères accentués seront "sautés", n’existant
		pas dans la disposition.
	</p>
	<mini-espace />
	<p>
		En conclusion, comparer des dispositions n’est pas aussi simple qu’on pourrait le penser.
		Comparez avec le même type de clavier et avec exactement les mêmes caractères sur les touches.
		En outre, la philosophie derrière la construction du clavier doit être prise en compte. En
		effet, certaines dispositions comme Optimot préfèrent mettre l’apostrophe droite en accès direct
		plutôt que celle typographique, partant du principe que la plupart des éditeurs de texte
		remplaceront de toute manière par l’apostrophe typographique. Dans ce cas précis, le caractère
		faisant office d’"apostrophe" est l’apostrophe droite, alors que d’autres dispositions comme <Nom
		/> fait la distinction entre les deux. Pour comparer avec le plus d’exactitude les dispositions,
		il faudrait modifier l’une des dispositions pour soit remplacer l’apostrophe typographique par une
		apostrophe droite, soit ajoutant une apostrophe typographique dans la disposition n’en ayant pas.
	</p>
	<p class="text-bold">
		➜ Comparer ce qui est comparable. Si le symbole n’existe pas dans la disposition, la touche ne
		sera pas tapée.
	</p>

	<h2>La question du corpus</h2>
	<p>
		Maintenant que vous avez été avertis sur comment bien comparer des dispositions, il reste encore
		la question du corpus. Effectivement, vos résultats vont également différer selon le corpus
		utilisé. Un corpus avec beaucoup de dialogues aura beaucoup de "je" alors qu’au contraire un
		corpus plus "sérieux" aura beaucoup de z dû au vouvoiement.
	</p>

	<p>
		Par conséquent, ne prenez les résultats ci-dessous que comme des indicatiosn générales. Une
		disposition meilleure de 2,48% sur un certain corpus n’implique pas que la disposition soit
		meilleure de 2,48% en général. En outre, passé une certaine performance, les gains sont
		marginaux. Par exemple, il serait probablement possible d’améliorer encore les résultats de <Nom
		/> sur KLAnext, mais cela se ferait au détriment d’autres choses pas forcément quantifiables comme
		le comfort général ou la disparition de certains roulements. Autre exemple, certaines dispositions
		optimisent tellement que les chiffres ne sont pas dans l’ordre mais plutôt du genre 3210987654. Cela
		rend la disposition beaucoup moins logique et donc plus difficile à apprendre, pour seulement optimiser
		légèrement leurs scores. Il serait aussi possible de faire cela pour les majuscules : il paraît évident
		que la majuscule d’une lettre soit en Shift + Lettre. Pourtant, il serait tout à fait possible que
		cela ne soit pas le cas, mais cela impliquerait alors d’apprendre deux fois plus de choses : où sont
		les lettren, et où sont les majuscules. Tout cela pour peu de gains si ce n’est avoir un score légèrement
		supérieur sur les comparateurs de dispositions.
	</p>

	<h2>Résultats de benchmarks</h2>
	<p>
		Voici enfin les résultats de benchmark que vous attendiez. Comme vous pouvez le constater, <Nom
		/>
		fait beaucoup mieux que le BÉPO et au moins aussi bien qu’Optimot. En version ISO, la version Thumbshift
		d’Optimot fait systématiquement mieux, avec notamment une grande différence en distance parcourrue.
		C’était un résultat attendu, car <kbd>Shift</kbd> est déplacé en <kbd>AltGr</kbd> et
		<kbd>AltGr</kbd>
		est déplacé en <kbd>Alt</kbd>. Cela explique aussi les excellents scores de Engram.
	</p>
	<p>
		Il n’arrive cependant pas toujours au niveau d’Adextre, qui est probablement la disposition
		clavier française la mieux notée sur KLAnext. Là encore, ce n’est pas parce qu’Adextre est mieux
		notée que cette disposition est "meilleure". Par exemple, Adextre nécessite un clavier de type
		Ergodox et ne peut donc pas être utilisée sur les claviers standards. En outre, elle a aussi une
		faible alternance des mains ainsi que la touche E sur le pouce gauche, ce qui peut entraver la
		fluidité lors de l’écriture de texte ainsi que le confort général.
	</p>

	<button on:click={toggleLangue}>
		{#if langue === 'fr'}
			<p>Français ➜ Anglais</p>
		{:else}
			<p>Anglais ➜ Français</p>
		{/if}
	</button>

	<button on:click={toggleClavier}>
		{#if clavier === 'iso'}
			<p>ISO ➜ Ergodox</p>
		{:else}
			<p>Ergodox ➜ ISO</p>
		{/if}
	</button>

	{#if langue === 'fr'}
		<select bind:value={corpus_fr}>
			{#each liste_benchmarks_fr as infos_benchmark}<option value={infos_benchmark[1]}
					>{infos_benchmark[0]}</option
				>{/each}
		</select>
	{/if}
	{#if langue === 'en'}
		<select bind:value={corpus_en}>
			{#each liste_benchmarks_en as infos_benchmark}<option value={infos_benchmark[1]}
					>{infos_benchmark[0]}</option
				>{/each}
		</select>
	{/if}

	<mini-espace />
	<div class="image">
		{#if langue === 'fr'}
			<img src="/img/benchmarks_{clavier}/{corpus_fr}.jpg" />
		{:else}
			<img src="/img/benchmarks_{clavier}/{corpus_en}.jpg" />
		{/if}
	</div>
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
