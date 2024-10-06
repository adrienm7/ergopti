<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import { version } from '$lib/stores_infos.js';
	import CommentComparer from './comment_comparer.svelte';
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

	<CommentComparer></CommentComparer>

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
	<h3 data-aos="fade-right" data-aos-mirror="true">Analyse KLAnext</h3>
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
				{@html '<p><strong>ISO</strong> ➜ <span class="ergodox-text-gradient">Ergodox</span></p>'}
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
	<bloc-image>
		{#if langue === 'fr'}
			<img src="/resultats/{versionValue}/{clavier}/{corpus_fr}.jpg" />
		{:else}
			<img src="/resultats/{versionValue}/{clavier}/{corpus_en}.jpg" />
		{/if}
	</bloc-image>
	<h3 data-aos="fade-right" data-aos-mirror="true">Analyse Ergo-L</h3>
	<p>
		Réalisée à l’aide de l’analyseur disponible ici : <a
			href="https://github.com/Nuclear-Squid/ergol">https://github.com/Nuclear-Squid/ergol</a
		>.
	</p>
	<div style="display:flex; align-items:center; justify-content:space-between;">
		<select bind:value={ergol} style="height: 2rem">
			<option value="en_fr">Français + Anglais</option>
			<option value="fr">Français</option>
			<option value="en">Anglais</option>
		</select>
		<a href="/resultats/{versionValue}/analyse_ergol_{ergol}.pdf" style="height: 2rem"
			><button>Télécharger l’analyse Ergo-L</button></a
		>
	</div>
	<mini-espace />
	<embed
		src="/resultats/{versionValue}/analyse_ergol_{ergol}.pdf"
		type="application/pdf"
		width="100%"
		height="600px"
	/>

	<section class="contenu">
		<h2 data-aos="zoom-out" data-aos-mirror="true">
			Analyse de la vraie disposition <NomPlus></NomPlus>
		</h2>
		<p>
			Une réelle analyse de <NomPlus></NomPlus> nécessite de modifier le corpus afin d’y refléter les
			nouvelles manières de taper les touches. Par exemple, il faut modifier toutes les doubles lettres
			du corpus pour les remplacer par la lettre suivie de <kbd>★</kbd>. De même, tous les <SFB
			></SFB>s pris en charge par <NomPlus></NomPlus>, comme <kbd-sortie>sc</kbd-sortie> en
			<kbd>,s</kbd>
			doivent être remplacés. Un <a href="/corpus/0_conversion_corpus.py">simple script Python</a> permet
			de faire ces modifications.
		</p>
		<p>
			Toutefois, modifier le corpus rend la comparaison avec les autres dispositions plus
			compliquée, car ce ne sera pas le même corpus pour toutes. Utiliser le même corpus modifié
			pour les autres dispositions peut engendrer des très bonnes performances chez elles, ceci car
			la touche <kbd>★</kbd> ne sera pas parmi leurs touches et sera donc systématiquement ignorée, améliorant
			sensiblement leurs stats.
		</p>
		<p>
			Voici les résultats de <NomPlus></NomPlus> obtenus sur le corpus français-anglais Essais :
		</p>
		<bloc-image>
			<img src="/resultats/hypertexte+_reduction_SFBs.jpg" />
		</bloc-image>
		<h3 data-aos="fade-right" data-aos-mirror="true">Analyse des <SFB></SFB>s</h3>
		<p>
			Cette analyse met en lumière la quasi-suppression des <SFB></SFB>s, avec une valeur d’environ
			3. Pour rappel, la valeur de cette métrique avec un corpus non modifié est de 25 pour la même
			disposition. Ainsi, l’utilisation d’<NomPlus></NomPlus> divise par environ 8 le nombre de <SFB
			></SFB>s de <Nom></Nom>.
		</p>
		<p>Voici une vue plus détaillée (attention, les axes des ordonnées ne sont pas les mêmes) :</p>
		<p><Nom></Nom> :</p>
		<bloc-image>
			<img src="/resultats/SFBs_hypertexte.jpg" />
		</bloc-image>
		<p><NomPlus></NomPlus> :</p>
		<bloc-image>
			<img src="/resultats/SFBs_hypertexte+.jpg" />
		</bloc-image>
		<p>
			Plusieurs <SFB></SFB>s se produisent maintenant sur l’index gauche en <kbd>★,</kbd> et
			<kbd>★.</kbd>, même s’ils sont déjà deux fois moins nombreux qu’avec <NomPlus></NomPlus>. Il y
			a sans doute possiblité d’améliorer cela, c’est un point à l’étude. En dehors de cela, les
			réductions de <SFB></SFB>s sont spectaculaires, en particulier sur les annulaires et
			auriculaires. Enfin, l’index droit voit son nombre de <SFB></SFB>s (<kbd>SC</kbd>,
			<kbd>DS</kbd>, etc.) chuter drastiquement, de 27 000 à 2500, soit une division par 10 !
		</p>
		<h3 data-aos="fade-right" data-aos-mirror="true">Analyse de la distance parcourue</h3>
		<p>
			Les gains de touches tapées ne sont pas reflétés sur la capture d’écran de résumé des scores.
			Avec le corpus normal, nous avions 50 306 touches tapées par <Nom></Nom>. Ce nombre tombe à 45
			525 touches tapées avec <NomPlus></NomPlus>. Cela peut paraître dérisoire, mais c’est quand
			même un gain de 10% de touches en moins à taper ! Ou autrement dit une augmentation de la
			vitesse de 10% sans effort (si ce n’est mémoriser les raccourcis de <NomPlus></NomPlus>).
		</p>
		<p>
			Les gains de touche peuvent encore s’accroître si vous personnalisez votre disposition pour y
			ajouter vos propres raccourcis. Dans la version <NomPlus></NomPlus> testés, seule une petite vingtaine
			de mots très courants ont été remplacés par un raccourci. Parmi ceux-ci :
			<kbd-sortie>ainsi</kbd-sortie>
			en <kbd>a★</kbd>, <kbd-sortie>exemple</kbd-sortie> en <kbd>x★</kbd> et
			<kbd-sortie>faire</kbd-sortie>
			en <kbd>f★</kbd>.
		</p>
		<h3 data-aos="fade-right" data-aos-mirror="true">
			Analyse de fréquence d’utilisation des doigts
		</h3>
		<bloc-image>
			<img src="/resultats/finger_usage_comparison.jpg" />
		</bloc-image>
		<p>
			Comme vous pouvez le constater sur l’image ci-dessous, l’index gauche est plus utilisé (6% vs
			8%) avec <NomPlus></NomPlus>. Cela vient des nombreuses utilisations de la touche
			<kbd>★</kbd>, dont la fréquence d’utilisation est désormais comparable à celle de la touche
			<kbd>É</kbd>, soit un peu moins de 2%.
		</p>
	</section>
</div>
