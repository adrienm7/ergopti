<script>
	import Ergopti from '#lib/components/Ergopti.svelte';
	import ErgoptiPlus from '#lib/components/ErgoptiPlus.svelte';
	import SFB from '#lib/components/SFB.svelte';

	import { version } from '#lib/stores_infos.js';
	import { asset, resolve } from '$app/paths';
	import { onMount } from 'svelte';
	import SiteFrame from '#lib/components/SiteFrame.svelte';
	import IntroductionBenchmarks from './introduction_benchmarks.svelte';
	import AnalyseErgoptiPlus from './analyse_ergopti_plus.svelte';
	import CommentComparer from './comment_comparer.svelte';
	import Corpus from './corpus.svelte';
	import ComparateursDispositions from './comparateurs_dispositions.svelte';
	import PageWrapper from '#lib/components/PageWrapper.svelte';

	let versionValue;
	version.subscribe((value) => {
		versionValue = value;
	});

	// The live comparison is the Studio's own Comparer (static/ergopti_plus/_shared/ui/
	// layout_analysis): the shared layout library, the shared engine and the shared
	// corpora, with no list or metric of its own here. It opens on a French corpus on
	// an ISO keyboard; every choice stays the visitor's.
	const BENCHMARK_CORPUS = 'fr_nemolivier';
	const BENCHMARK_KEYBOARD = 'iso';
	const comparerSrc =
		asset('ergopti_plus/_shared/ui/layout_analysis/index.html') +
		`?lang=fr&corpus=${BENCHMARK_CORPUS}&keyboard=${BENCHMARK_KEYBOARD}`;
	// The framed Comparer posts its height ({type, height}, comparer_page.js) so the
	// frame grows with it instead of scrolling inside the page.
	const HEIGHT_MESSAGE = 'ergopti-layout-analysis:height';
	let comparerFrame;
	let comparerHeight = 900;

	let ergol = 'en_fr';
	let version_1dfh = '_1dk';

	onMount(() => {
		const resize = (event) => {
			if (!comparerFrame || event.source !== comparerFrame.contentWindow) return;
			const data = event.data;
			if (data && data.type === HEIGHT_MESSAGE && Number.isFinite(data.height))
				comparerHeight = Math.ceil(data.height);
		};
		window.addEventListener('message', resize);
		return () => window.removeEventListener('message', resize);
	});

	function getErgolPdf() {
		return asset(`benchmarks/ergol/v2.1/analyse_ergol_ergopti${version_1dfh}_v2.1_${ergol}.pdf`);
	}
</script>

<svelte:head>
	<title>Benchmarks de la Disposition Ergopti</title>
	<meta
		name="description"
		content="Benchmarks de la Disposition Ergopti face aux autres dispositions, sur des corpus français, anglais et code"
	/>
</svelte:head>

<PageWrapper>
	<svelte:fragment slot="introduction">
		<bloc-introduction>
			<IntroductionBenchmarks />
		</bloc-introduction>
	</svelte:fragment>

	<div>
		<CommentComparer></CommentComparer>
		<Corpus></Corpus>

		<h2>Résultats de benchmarks</h2>
		<p>
			Voici enfin les résultats de benchmarks que vous attendiez. Comme vous pourrez le constater, <Ergopti
			/>
			fait beaucoup mieux que le BÉPO (et évidemment AZERTY) et au moins aussi bien qu’Optimot.
		</p>
		<!-- <p>
			À noter qu’en version ISO, la version Thumbshift d’Optimot fait systématiquement mieux qu’<Ergopti
			/>, avec notamment une grande différence en distance parcourue. C’était un résultat attendu,
			car dans cette disposition <kbd>Shift</kbd> est déplacé en <kbd>AltGr</kbd> tandis que
			<kbd>AltGr</kbd>
			est quant à lui déplacé en <kbd>Alt</kbd>. Cela explique aussi les excellents scores de
			Engram, qui a le même placement des touches <kbd>Shift</kbd> et <kbd>AltGr</kbd>.
		</p> -->
		<p>
			En version Ergodox, <Ergopti /> n’arrive cependant pas toujours au niveau d’Adextre, qui est probablement
			la disposition clavier française la mieux notée sur KLAnext. Là encore, ce n’est pas parce qu’Adextre
			est mieux notée que cette disposition est "meilleure". Par exemple, Adextre nécessite un clavier
			de type Ergodox et ne peut donc pas être utilisée sur les claviers standards (ISO). En outre, elle
			a une faible alternance des mains ainsi que la touche <kbd>E</kbd> sur le pouce gauche, ce qui
			peut entraver la fluidité lors de l’écriture de texte ainsi que le confort général.
		</p>
		<p>
			Enfin, gardez en tête que les dispositions dont le nom est suffixé par « en » plutôt que
			« fr » ne contiennent pas les touches accentuées nécessaires à l’écriture du français. Elles
			vont donc forcément surperformer sur les corpus français. Et même sur les corpus anglais,
			elles feront un peu mieux car il y aura moins de touches à disposer et donc davantage de bons
			emplacements.
		</p>

		<h3 id="comparaison">Comparaison en direct</h3>
		<p>
			Ces résultats sont calculés dans votre navigateur, avec le même moteur d’analyse, la même
			bibliothèque de dispositions et les mêmes corpus que l’onglet <a
				class="link"
				href={resolve('/studio/comparer')}>Comparer</a
			>
			d’Ergopti Studio et que le Studio d’<ErgoptiPlus></ErgoptiPlus>. Choisissez le corpus
			(français, anglais, code…), le clavier (ISO, Ergodox, Corne…) et les dispositions comparées.
			Chaque métrique est expliquée par son bouton « i », et les colonnes des autres analyseurs
			(KLAnext, Ergo‑L, Oxeylyzer…) donnent le score que chacun de ces outils calculerait.
		</p>
		<SiteFrame
			class="benchmark-frame"
			title="Benchmarks — comparaison des dispositions"
			src={comparerSrc}
			height={comparerHeight}
			bind:frame={comparerFrame}
		/>

		<h3>Analyse Ergo‑L</h3>
		<p>
			Réalisée à l’aide de l’analyseur disponible ici : <a
				class="link"
				href="https://github.com/Nuclear-Squid/ergol"
				target="_blank">https://github.com/Nuclear-Squid/ergol</a
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
		{#if true}
			<a href={getErgolPdf()}
				><button style="height: 2.5rem; margin-top:15px">Télécharger l’analyse Ergo‑L</button></a
			>
			<tiny-space></tiny-space>
			<embed src={getErgolPdf()} type="application/pdf" width="100%" height="600px" />
		{/if}

		<AnalyseErgoptiPlus></AnalyseErgoptiPlus>
		<ComparateursDispositions></ComparateursDispositions>
	</div>
</PageWrapper>

<style>
	/* The Comparer frame spans the text column; its height follows the framed page. */
	:global(.benchmark-frame) {
		border: 0;
		display: block;
		width: 100%;
	}
</style>
