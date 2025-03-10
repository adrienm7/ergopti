<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import { version } from '$lib/stores_infos.js';
	import AnalyseHypertextePlus from './analyse_ergopti+.svelte';
	import CommentComparer from './comment_comparer.svelte';
	import Corpus from './corpus.svelte';

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

	let liste_benchmarks_fr = [
		['Panaché (Pyjam)', 'panache'],
		['Essais (Pyjam)', 'essais'],
		['Corpus Johnix Mails', 'corpus_johnix_mails'],
		['Romans (24M)', 'romans'],
		['Corpus Nemolivier', 'corpus_nemolivier'],
		['Don Quichotte', 'don_quichotte'],
		['Corpus Leipzig news', 'leipzig_fra_news_2023_10K-sentences'],
		['Corpus Leipzig Wikipedia', 'leipzig_fra_wikipedia_2021_10K-sentences']
	];

	let liste_benchmarks_en = [
		['Chained English Bigrams 9 (3M)', 'chained_english_bigrams_9'],
		['Chained English Bigrams 7 (1M)', 'chained_english_bigrams_7'],
		['Chained Proglish Bigrams 7 (1M)', 'chained_proglish_bigrams_7'],
		['500 Common Words in Prose (664K)', '500_common_words_in_prose'],
		['Common English Words (6K)', 'common_english_words'],
		['Common SAT Words (9K)', 'common_sat_words'],
		['Basic Words (5K)', 'basic_words'],
		['Difficult Words (11K)', 'difficult_words']
	];

	let liste_benchmarks_code = [
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
	let corpus = 'fr/panache';
	let ergol = 'en_fr';
	let version_1dfh = '_1dk';
</script>

<svelte:head>
	<title>Benchmarks</title>
	<meta name="description" content="Benchmarks de la disposition Ergopti" />
</svelte:head>

<div>
	<CommentComparer></CommentComparer>
	<Corpus></Corpus>

	<h2>Résultats de benchmarks</h2>
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
		a une faible alternance des mains ainsi que la touche <kbd>E</kbd> sur le pouce gauche, ce qui peut
		entraver la fluidité lors de l’écriture de texte ainsi que le confort général.
	</p>
	<p>
		Enfin, gardez en tête que les dispositions dont le nom est suffixé par « en » plutôt que « fr »
		ne contiennent pas les touches accentuées nécessaires à l’écriture du français. Elles vont donc
		forcément surperformer sur les corpus français. Et même sur les corpus anglais, elles feront un
		peu mieux car il y aura moins de touches à disposer et donc davantage de bons emplacements.
	</p>

	<h3>Analyse KLAnext</h3>
	<div style="background: #00000091; padding: 0.5rem; margin:0 auto; text-align: center;">
		<button on:click={toggleClavier} style="height:2.5rem;">
			{#if clavier === 'ergodox'}
				{@html '<p><strong class="ergodox-text-gradient">Ergodox</strong> ➜&nbsp;ISO</p>'}
			{:else}
				{@html '<p><strong>ISO</strong> ➜ <span class="">Ergodox</span></p>'}
			{/if}
		</button>

		<div style="display:inline-block;">
			<select bind:value={corpus} style="height:2.5rem;">
				<option disabled>Français</option>
				{#each liste_benchmarks_fr as infos_benchmark}<option value={'fr/' + infos_benchmark[1]}
						>{infos_benchmark[0]}</option
					>{/each}
				<option disabled>Anglais</option>
				{#each liste_benchmarks_en as infos_benchmark}<option value={'en/' + infos_benchmark[1]}
						>{infos_benchmark[0]}</option
					>{/each}
				<option disabled>Code</option>
				{#each liste_benchmarks_code as infos_benchmark}<option value={'code/' + infos_benchmark[1]}
						>{infos_benchmark[0]}</option
					>{/each}
			</select>
		</div>
	</div>
	<mini-espace />
	<bloc-image>
		<img src="/benchmarks/{clavier}/{corpus}.jpg" />
	</bloc-image>

	<h3>Analyse Ergo-L</h3>
	<p>
		Réalisée à l’aide de l’analyseur disponible ici : <a
			href="https://github.com/Nuclear-Squid/ergol">https://github.com/Nuclear-Squid/ergol</a
		>.
	</p>
	<div style="display:flex; align-items:center; justify-content:left; flex-wrap: wrap;">
		<select bind:value={ergol} style="height: 2.5rem; display:block; margin-right: 15px">
			<option value="en_fr">Français + Anglais</option>
			<option value="fr">Français</option>
			<option value="en">Anglais</option>
			<option value="panache">Panaché (Pyjam)</option>
			<option value="essais">Essais (Pyjam)</option>
		</select>
		<select bind:value={version_1dfh} style="height: 2.5rem; display:block;">
			<option value="_1dk">1DFH avec touche 1DK</option>
			<option value="">Standard</option>
		</select>
	</div>
	<a
		href="/benchmarks/ergol/v{versionValue}/analyse_ergol_ergopti{version_1dfh}_v{versionValue}_{ergol}.pdf"
		><button style="height: 2.5rem; margin-top:15px">Télécharger l’analyse Ergo-L</button></a
	>
	<mini-espace />
	<embed
		src="/benchmarks/ergol/v{versionValue}/analyse_ergol_ergopti{version_1dfh}_v{versionValue}_{ergol}.pdf"
		type="application/pdf"
		width="100%"
		height="600px"
	/>

	<AnalyseHypertextePlus></AnalyseHypertextePlus>
</div>
