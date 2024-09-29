<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import { version } from '$lib/stores_infos.js';
	let versionValue;
	version.subscribe((value) => {
		versionValue = value;
	});

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
		['Corpus Panaché (Pyjam)', 'panache'],
		['Essais (Pyjam)', 'essais'],
		['Corpus Johnix Mails', 'corgus_johnix_mails'],
		['Romans (24M)', 'romans']
	];

	let liste_benchmarks_en = [
		['Chained English Bigrams 9 (3M)', 'chained_english_bigrams_9'],
		['Chained English Bigrams 7 (1M)', 'chained_english_bigrams_7'],
		['Chained Proglish Bigrams 7 (1M)', 'chained_proglish_bigrams_7'],
		['500 Common Words in Prose (664K)', '500_common_words_in_prose'],
		['Common English Words (6K)', 'common_english_words'],
		['Common SAT Words (9K)', 'common_sat_words'],
		['Chained Code Bigrams 7 (1M)', 'chained_code_bigrams_7'],
		['Programming Ponctuation (10K)', 'programming_punctuation'],
		['Python for Everybody (437K)', 'python_for_everybody'],
		['Think C++ (330K)', 'think_c++'],
		['Think Java (380K)', 'think_java'],
		['Data Munging with Perl (600K)', 'data_munging_with_perl'],
		['Practical PHP Testing  (95K)', 'practical_php_testing'],
		['Random Text (30K)', 'random_text']
	];

	let clavier = 'iso';
	let langue = 'fr';
	let ergol = 'en_fr';
	let corpus_fr = 'panache';
	let corpus_en = 'chained_english_bigrams_9';
</script>

<svelte:head>
	<title>Benchmarks</title>
	<meta name="description" content="Benchmarks de la disposition HyperTexte" />
</svelte:head>

<div class="contenu">
	<h1 data-aos="zoom-in" data-aos-mirror="true">Benchmarks</h1>

	<div class="encadre">
		Il existe de nombreux comparateurs de dispositions, certains ayant même une interface en ligne.
		<span class="important">KLAnext</span> est l’un d’entre eux et est gratuitement accessible à
		l’adresse
		<a href="https://klanext.keyboard-design.com">https://klanext.keyboard-design.com</a>. C’est
		l’un des comparateurs en ligne les plus utilisés en raison de son algorithme de notation qui
		serait meilleur que les autres.
	</div>

	<h2 data-aos="zoom-out" data-aos-mirror="true">Comment bien utiliser KLAnext</h2>
	<section>
		<p>
			Pour bien utiliser des comparateurs de disposition, il faut <span class="important"
				>comparer ce qui est comparable</span
			>. Ceci est très important, car si vous ne le faites pas, alors vos résultats n’auront aucune
			valeur.
		</p>
		<mini-espace />
		<h3>Comparer le même type de clavier</h3>
		<p>
			Ne comparez pas une disposition ISO avec une disposition Ergodox. Sinon, logiquement la
			disposition Ergodox sera mieux notée. Elle aura en effet une distance aux touches moindre, car
			les pouces seront beaucoup plus mis à contribution. En outre, les <SFB />s seront diminués,
			car <kbd>Shift</kbd>, <kbd>Enter</kbd>, etc. ne seront plus sur les auriculaires mais sur les
			pouces.
		</p>

		<mini-espace />
		<h3>Comparer des claviers possédant une touche pour tous les caractères du corpus</h3>
		<p>
			Un autre point à bien faire attention est de <span class="important"
				>s’assurer que toutes les lettres soient bien dans les dispositions à comparer</span
			>. Une disposition faite pour la langue anglaise aura de très bons scores pour des textes
			français. Cela s’explique parce que tous les caractères accentués seront "sautés", n’existant
			pas dans la disposition anglophone.
		</p>

		<mini-espace />
		<h3>Conclusion sur la comparaison de dispositions</h3>
		<p>
			Comparer des dispositions n’est pas aussi simple qu’on pourrait de prime abord le penser. Il
			ne suffit pas de balancer son texte et sa disposition dans un comparateur et de le faire
			tourner.
		</p>

		<p>
			En outre, la philosophie derrière la construction du clavier doit être prise en compte.
			Certaines dispositions comme Optimot préfèrent mettre l’apostrophe droite en accès direct
			plutôt que celle typographique, partant du principe que la plupart des éditeurs de texte la
			remplaceront de toute manière par l’apostrophe typographique. Dans ce cas précis, le caractère
			faisant office d’"apostrophe" est l’apostrophe droite, alors que d’autres dispositions comme
			une version précédente d’<Nom /> font la distinction entre les deux.
		</p>
		<p>
			Pour comparer avec le plus d’exactitude les dispositions, il faudrait alors les modifier pour
			soit remplacer l’apostrophe typographique par une apostrophe droite, soit en ajoutant une
			apostrophe typographique dans la disposition n’en ayant pas.
		</p>
		<p class="important">
			➜ Comparer ce qui est comparable. Si le symbole n’existe pas dans la disposition, la touche ne
			sera pas tapée.
		</p>
	</section>

	<h2 data-aos="zoom-out" data-aos-mirror="true">La question du corpus</h2>
	<section>
		<p>
			Maintenant que vous avez été avertis sur comment bien comparer des dispositions, il reste
			encore la <span class="important">question fondamentale du corpus</span>. Effectivement, vos
			résultats vont sensiblement différer selon le corpus utilisé. Un corpus avec beaucoup de
			dialogues aura beaucoup de "je", un corpus plus "sérieux" aura beaucoup de z dû au vouvoiement
			tandis qu’un corpus parlant de trains aura plus de <kbd>W</kbd> dû à une fréquence plus élevée
			du mot "wagon".
		</p>
		<p>
			Évidemment, plus votre corpus sera volumineux, plus vos résultats seront crédibles. Toutefois,
			cela augmentera d’autant les temps de calcul.
		</p>

		<p>
			En conclusion, <span class="important"
				>ne prenez les résultats des benchmarks que comme des tendances générales</span
			>. Une disposition meilleure de 2,48% sur un certain corpus n’implique pas que la disposition
			soit meilleure de 2,48% en général. En outre, passé une certaine performance, les gains sont
			marginaux.
		</p>
		<p>
			Par exemple, il serait probablement possible d’améliorer encore les résultats de <Nom /> sur KLAnext,
			mais cela se ferait au détriment d’autres choses pas forcément quantifiables comme le comfort général
			ou la disparition de certains roulements. Autre exemple, certaines dispositions optimisent tellement
			que les chiffres ne sont pas dans l’ordre mais plutôt du genre 3210987654. Cela rend la disposition
			beaucoup moins logique et donc plus difficile à apprendre, pour seulement optimiser légèrement
			leurs scores.
		</p>
		<p>
			Il serait aussi possible de faire cela pour les majuscules. Cela nous paraît évident que la
			majuscule d’une lettre soit en Shift + Lettre. Pourtant, il serait tout à fait possible que
			cela ne soit pas le cas, mais cela impliquerait alors d’apprendre deux fois plus de choses :
			où sont les lettres, et où sont les majuscules. Tout cela pour peu de gains si ce n’est
			d’avoir un score légèrement supérieur sur les comparateurs de dispositions.
		</p>
	</section>

	<h2 data-aos="zoom-out" data-aos-mirror="true">Résultats de benchmarks</h2>
	<section>
		<p>
			Voici enfin les résultats de benchmarks que vous attendiez. Comme vous pourrez le constater, <Nom
			/>
			fait beaucoup mieux que le BÉPO (et évidemment AZERTY) et au moins aussi bien qu’Optimot.
		</p>
		<!-- <p>
			À noter qu’en version ISO, la version Thumbshift d’Optimot fait systématiquement mieux qu’<Nom
			/>, avec notamment une grande différence en distance parcourue. C’était un résultat attendu,
			car dans cette disposition <kbd>Shift</kbd> est déplacé en <kbd>AltGr</kbd> tandis que
			<kbd>AltGr</kbd>
			est quant à lui déplacé en <kbd>Alt</kbd>. Cela explique aussi les excellents scores de
			Engram, qui a le même placement des touches <kbd>Shift</kbd> et <kbd>AltGr</kbd>.
		</p> -->
		<p>
			En version Ergodox, <Nom /> n’arrive cependant pas toujours au niveau d’Adextre, qui est probablement
			la disposition clavier française la mieux notée sur KLAnext. Là encore, ce n’est pas parce qu’Adextre
			est mieux notée que cette disposition est "meilleure". Par exemple, Adextre nécessite un clavier
			de type Ergodox et ne peut donc pas être utilisée sur les claviers standards (ISO). En outre, elle
			a une faible alternance des mains ainsi que la touche E sur le pouce gauche, ce qui peut entraver
			la fluidité lors de l’écriture de texte ainsi que le confort général.
		</p>
		<p>
			Enfin, gardez en tête que les dispositions dont le nom est préfixé par « en » plutôt que « fr
			» ne contiennent pas les touches accentuées nécessaires à l’écriture du français. Elles vont
			donc forcément surperformer sur les corpus français. Et même sur les corpus anglais, elles
			feront un peu mieux car il y aura moins de touches à disposer et donc davantage de bons
			emplacements.
		</p>
	</section>
	<h3>Analyse KLAnext</h3>
	<div style="background: #00000091; padding: 0.5rem; margin:0 auto; text-align: center;">
		<button on:click={toggleLangue} style="height:2.5rem;">
			{#if langue === 'fr'}
				{@html '<p><strong class="hyper">Français</strong>➜&nbsp;<span class="texte">Anglais</span></p>'}
			{:else}
				{@html '<p><strong class="texte">Anglais</strong> ➜&nbsp;<span class="hyper">Français</span></p>'}
			{/if}
		</button>

		<button on:click={toggleClavier} style="height:2.5rem;">
			{#if clavier === 'ergodox'}
				{@html '<p><strong class="ergodox-text-gradient">Ergodox</strong> ➜&nbsp;ISO</p>'}
			{:else}
				{@html '<strong>ISO</strong> ➜ <span class="ergodox-text-gradient">Ergodox</span>'}
			{/if}
		</button>
		<div style="display:inline-block;">
			{#if langue === 'fr'}
				<select bind:value={corpus_fr} style="height:2.5rem;">
					{#each liste_benchmarks_fr as infos_benchmark}<option value={infos_benchmark[1]}
							>{infos_benchmark[0]}</option
						>{/each}
				</select>
			{/if}
			{#if langue === 'en'}
				<select bind:value={corpus_en} style="height:2.5rem;">
					{#each liste_benchmarks_en as infos_benchmark}<option value={infos_benchmark[1]}
							>{infos_benchmark[0]}</option
						>{/each}
				</select>
			{/if}
		</div>
	</div>

	<mini-espace />
	<div class="image">
		{#if langue === 'fr'}
			<img src="/img/benchmarks_{versionValue}/{clavier}/{corpus_fr}.jpg" />
		{:else}
			<img src="/img/benchmarks_{versionValue}/{clavier}/{corpus_en}.jpg" />
		{/if}
	</div>
	<h3>Analyse Ergo-L</h3>
	<div style="display:flex; align-items:center; justify-content:space-between;">
		<select bind:value={ergol} style="height: 2rem">
			<option value="en_fr" selected>Français + Anglais</option>
			<option value="fr">Français</option>
			<option value="en">Anglais</option>
		</select>
		<a href="/img/benchmarks_{versionValue}/analyse_ergol_{ergol}.pdf" style="height: 2rem"
			><button>Télécharger l’analyse Ergo-L {ergol}</button></a
		>
	</div>
	<!-- <mini-espace />
	<embed
		src="/img/benchmarks_{versionValue}/analyse_ergol_{langue}.pdf"
		type="application/pdf"
		width="100%"
		height="600px"
	/> -->
</div>

<style>
	.image {
		margin: 0 auto;
		text-align: center;
	}

	.image img {
		width: 100%;
		margin: 0 auto;
		border: 10px solid rgb(255, 255, 255);
		border-radius: 10px;
		box-shadow: rgba(209, 209, 209, 0.8) 0 0 10px 1px;
		text-align: center;
	}

	.image p {
		font-size: 1.3rem;
		font-weight: bold;
	}
</style>
