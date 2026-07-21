<!-- src/routes/ergopti-plus/AiSection.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — AI Predictions
DESCRIPTION:
The LLM story, entirely data-driven: local backends, the nine remote API
providers, the model catalog and the prompt profiles all come from the same
JSON files the drivers load at boot (via +page.server.js). The tooltip
mockups faithfully mirror the driver's real color code.

FEATURES & RATIONALE:
1. Zero Drift: add a provider/model/profile to the driver and this section
   updates on the next deploy — nothing here is hand-maintained.
2. Local First: the privacy argument (local inference, loopback-only
   servers, encrypted API keys) is a core differentiator and is stated
   prominently.
==============================================================================
-->

<script>
	import DriverFrame from './DriverFrame.svelte';
	import { reveal } from './reveal.js';
	import WindowChrome from './WindowChrome.svelte';
	import { ui } from './state.svelte.js';

	/**
	 * @type {{
	 *   catalog: Array<{name: string, modelCount: number, familyCount: number, families: string, range: string | null}>,
	 *   totals: {providers: number, models: number, families: number},
	 *   range: {min: string, max: string},
	 *   apiProviders: Array<{id: string, label: string, defaultModel: string}>,
	 *   profiles: Array<{id: string, label: string, batch: boolean}>,
	 *   defaults: {debounceMs: number, numPredictions: number, contextLength: number, ollamaPort: number, mlxPort: number},
	 *   geo: Record<string, {width: number, height: number}>
	 * }}
	 */
	let { catalog, totals, range, apiProviders, profiles, defaults, geo } = $props();

	// Tooltip mockup tabs — the three usage modes of the AI tooltip, using
	// the driver's real color code (gray context, green corrections, orange
	// predictions, yellow active-line marker).
	const modes = [
		{ id: 'predict', label: 'Prédiction' },
		{ id: 'correct', label: 'Correction' },
		{ id: 'both', label: 'Correction + prédiction' }
	];
	let activeMode = $state('both');

	// Descriptions used on the profile cards, keyed by profile id. The
	// labels themselves come from the driver's locale files at build time.
	const profileNotes = {
		raw: 'Aucune instruction injectée : le modèle reçoit le contexte brut et continue. Idéal pour le code et les formats stricts.',
		basic:
			'Instruction minimale : continuer le texte entre N et M mots, sans commentaire. Le compromis vitesse/qualité par défaut.',
		advanced:
			'Deux lignes en sortie : la fin de phrase corrigée, puis la suite prédite. Bilingue FR/EN, avec exemples intégrés pour les petits modèles.',
		batch_advanced:
			'Le contrat « Avancé », mais N suggestions distinctes en une seule requête — beaucoup plus économique que N appels.'
	};
</script>

<section class="ai" id="ia" style="--section-accent: var(--family-ia);">
	<div class="ai-glow" aria-hidden="true"></div>
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">Prédictions IA</p>
			<h2>Une IA qui écrit avec vous. Chez vous.</h2>
			<p class="lead">
				Le driver embarque un pont vers un modèle de langage qui tourne <strong
					>sur votre machine</strong
				>. Il corrige la fin de votre phrase et propose la suite — validables en une touche, sans
				que rien ne parte dans le cloud.
			</p>
		</header>

		<!-- Faithful tooltip mockup with mode tabs -->
		<div class="ai-demo" use:reveal>
			<div class="mode-tabs" role="tablist" aria-label="Mode du tooltip IA">
				{#each modes as m}
					<button
						type="button"
						role="tab"
						aria-selected={activeMode === m.id}
						class:active={activeMode === m.id}
						onclick={() => (activeMode = m.id)}
					>
						{m.label}
					</button>
				{/each}
			</div>

			<div class="ai-window ep-window os-{ui.osStyle}">
				<WindowChrome title="~/inbox/brouillon.eml" />

				<div class="ai-body">
					{#if activeMode === 'predict'}
						<p class="ai-context">
							Bonjour Madame, je vous écris pour <span class="caret"></span>
						</p>
						<div class="hs-tooltip">
							<div class="tt-line tt-line--selected">
								<span class="tt-spark">✨</span>
								<span class="tt-eq">…je vous écris pour</span>
								<span class="tt-nw"> vous proposer un rendez-vous mardi prochain.</span>
								<span class="tt-shortcut">⌥1</span>
							</div>
							<div class="tt-line">
								<span class="tt-eq tt-dim">…je vous écris pour</span>
								<span class="tt-nw tt-dim">
									faire suite à notre échange de la semaine dernière.</span
								>
								<span class="tt-shortcut tt-dim">⌥2</span>
							</div>
							<div class="tt-line">
								<span class="tt-eq tt-dim">…je vous écris pour</span>
								<span class="tt-nw tt-dim"> accuser réception de votre dossier complet.</span>
								<span class="tt-shortcut tt-dim">⌥3</span>
							</div>
							<div class="tt-hint">Tab = accepter · ↑↓ = naviguer · Échap = ignorer</div>
							<div class="tt-info">Llama 3.2 3B · Ollama · Basique — ⏱ 0,18 s</div>
						</div>
					{:else if activeMode === 'correct'}
						<p class="ai-context">
							Je vous remercie de me <span class="typo">recevoire</span> demain matin.<span
								class="caret"
							></span>
						</p>
						<div class="hs-tooltip">
							<div class="tt-line tt-line--selected">
								<span class="tt-spark">✨</span>
								<span class="tt-eq">Je vous remercie de me</span>
								<span class="tt-corr"> recevoir</span>
								<span class="tt-eq"> demain matin.</span>
								<span class="tt-shortcut">⌥1</span>
							</div>
							<div class="tt-hint">Tab = accepter</div>
							<div class="tt-info">Llama 3.2 3B · Ollama · Avancé — ⏱ 0,21 s</div>
						</div>
					{:else}
						<p class="ai-context">
							Le projet est <span class="typo">paralèle</span> à <span class="caret"></span>
						</p>
						<div class="hs-tooltip">
							<div class="tt-line tt-line--selected">
								<span class="tt-spark">✨</span>
								<span class="tt-eq">Le projet est</span>
								<span class="tt-corr"> parallèle</span>
								<span class="tt-eq"> à</span>
								<span class="tt-nw"> celui de l’an dernier, avec un budget revu à la hausse.</span>
								<span class="tt-shortcut">⌥1</span>
							</div>
							<div class="tt-line">
								<span class="tt-eq tt-dim">Le projet est</span>
								<span class="tt-corr tt-dim"> parallèle</span>
								<span class="tt-eq tt-dim"> à</span>
								<span class="tt-nw tt-dim"> ceux que nous avons livrés en 2024.</span>
								<span class="tt-shortcut tt-dim">⌥2</span>
							</div>
							<div class="tt-hint">Tab = accepter la correction ET la suite</div>
							<div class="tt-info">Mistral 7B · Ollama · Avancé — ⏱ 0,34 s</div>
						</div>
						<p class="ai-punch">
							Un seul <kbd>Tab</kbd> insère la correction <strong>et</strong> la suite : 80 caractères
							pour 1 frappe.
						</p>
					{/if}
				</div>
			</div>

			<p class="ai-legend">
				Code couleur réel du driver : <span class="lg-gray">contexte</span> ·
				<span class="lg-green">correction</span>
				· <span class="lg-orange">prédiction</span> ·
				<span class="lg-yellow">✨ ligne active</span>.
				{defaults.numPredictions} suggestions, déclenchées après {defaults.debounceMs} ms d’inactivité
				sur les {defaults.contextLength} derniers caractères — tout est réglable.
			</p>
		</div>

		<!-- Step 1 — local backends -->
		<div class="ai-step" use:reveal>
			<h3><span class="step-badge">1</span> Choisissez votre moteur — local d’abord</h3>
			<div class="backend-grid">
				<article class="ep-card ep-card--hover backend-card">
					<header>
						<span class="backend-icon" aria-hidden="true">🦙</span>
						<div>
							<h4>Ollama</h4>
							<p class="backend-aud">Windows · macOS · Linux</p>
						</div>
						<span class="backend-port">port {defaults.ollamaPort}</span>
					</header>
					<p>
						Le plus simple à installer — le driver propose même de le faire pour vous. Catalogue de
						modèles immense, serveur local en écoute uniquement sur votre machine.
					</p>
				</article>

				<article class="ep-card ep-card--hover backend-card">
					<header>
						<span class="backend-icon" aria-hidden="true">⚡</span>
						<div>
							<h4>MLX</h4>
							<p class="backend-aud">macOS · Apple Silicon (M1 → M4)</p>
						</div>
						<span class="backend-port">port {defaults.mlxPort}</span>
					</header>
					<p>
						Inférence accélérée par le GPU des puces Apple. Détecté et sélectionné automatiquement
						sur les machines compatibles — réponses sous 100 ms sur les petits modèles.
					</p>
				</article>
			</div>

			<!-- Remote API providers — dynamic, from api_providers.json -->
			<div class="api-band">
				<p class="api-lead">
					Envie d’un modèle plus puissant ? Branchez une clé API — <strong
						>{apiProviders.length} fournisseurs</strong
					> pris en charge, clés chiffrées localement (Trousseau macOS, DPAPI Windows) :
				</p>
				<ul class="api-chips">
					{#each apiProviders as p}
						<li
							class="api-chip"
							title={p.defaultModel
								? `Modèle par défaut : ${p.defaultModel}`
								: 'Endpoint personnalisé'}
						>
							{p.label}
						</li>
					{/each}
				</ul>
				<p class="api-note">
					Liste générée depuis le fichier de configuration du driver — toujours à jour.
				</p>
			</div>
		</div>

		<!-- Step 2 — model catalog -->
		<div class="ai-step" use:reveal>
			<h3><span class="step-badge">2</span> Choisissez votre modèle parmi {totals.models}</h3>
			<p class="step-lead">
				Un catalogue curé de <strong>{totals.models} modèles open-weights</strong> issus de
				<strong>{totals.providers} fournisseurs</strong>
				({totals.families} familles), du {range.min} qui répond en 50 ms au {range.max} ultra-contextuel.
				Le menu affiche la RAM et l’espace disque requis avant tout téléchargement — et accepte n’importe
				quel identifiant HuggingFace ou tag Ollama en plus.
			</p>
			<div class="provider-grid">
				{#each catalog as p, i}
					<article class="provider" use:reveal={{ delay: (i % 6) * 50 }}>
						<div class="provider-name">{p.name}</div>
						<div class="provider-family" title={p.families}>{p.families}</div>
						<div class="provider-meta">
							<span class="provider-count">{p.modelCount} modèle{p.modelCount > 1 ? 's' : ''}</span>
							{#if p.range}
								<span class="provider-range">{p.range}</span>
							{/if}
						</div>
					</article>
				{/each}
			</div>
			<div class="browser-embed">
				<p class="step-lead">
					Et voici la <strong>vraie fenêtre</strong> du navigateur de modèles, alimentée ici avec ce
					même catalogue — triez, cherchez, comparez :
				</p>
				<DriverFrame
					id="model_browser"
					width={geo.model_browser?.width ?? 900}
					height={geo.model_browser?.height ?? 580}
					displayHeight={520}
				/>
			</div>
			<p class="api-note">
				Catalogue généré depuis <code>models.json</code> — le même fichier que lit le driver.
			</p>
		</div>

		<!-- Step 3 — prompt profiles -->
		<div class="ai-step" use:reveal>
			<h3><span class="step-badge">3</span> Choisissez (ou écrivez) votre profil de prompt</h3>
			<div class="profile-grid">
				{#each profiles as p}
					<article class="ep-card profile-card">
						<header class="profile-head">
							<span class="profile-label">{p.label}</span>
							{#if p.batch}<span class="profile-batch">batch</span>{/if}
						</header>
						<p>{profileNotes[p.id] ?? ''}</p>
					</article>
				{/each}
			</div>
			<p class="step-foot">
				L’éditeur de prompts intégré accepte vos propres instructions avec les variables
				<code>{'{context}'}</code>, <code>{'{min_words}'}</code>, <code>{'{max_words}'}</code> —
				imposez un ton, une langue, un métier. <em>« Termine mes phrases comme Hemingway »</em> est un
				profil valide.
			</p>
		</div>
	</div>
</section>

<style>
	.ai {
		position: relative;
	}

	.ai-glow {
		background: radial-gradient(
			ellipse at center,
			rgba(236, 64, 122, 0.1) 0%,
			rgba(236, 64, 122, 0) 65%
		);
		height: 500px;
		left: 50%;
		pointer-events: none;
		position: absolute;
		top: 0;
		transform: translateX(-50%);
		width: min(900px, 100vw);
		z-index: -1;
	}

	/* ─── Demo window + tabs ────────────────────────────────── */

	.ai-demo {
		margin: 0 auto clamp(40px, 6vw, 64px);
		max-width: 780px;
	}

	.mode-tabs {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: 999px;
		display: flex;
		gap: 2px;
		margin: 0 auto 18px;
		padding: 4px;
		width: fit-content;
	}

	.mode-tabs button {
		background: transparent;
		border: 0;
		border-radius: 999px;
		color: var(--ink-faint);
		cursor: pointer;
		font: inherit;
		font-size: 0.85rem;
		font-weight: 600;
		padding: 7px 16px;
		transition:
			background-color 0.25s var(--ease),
			color 0.25s var(--ease);
	}

	.mode-tabs button:hover {
		color: var(--ink-soft);
	}

	.mode-tabs button.active {
		background: rgba(236, 64, 122, 0.16);
		color: #fff;
	}

	.ai-body {
		padding: 24px 26px 26px;
	}

	.ai-context {
		color: var(--ink);
		font-family: 'SF Mono', 'Cascadia Code', Menlo, Consolas, monospace;
		font-size: 1rem;
		line-height: 1.6;
		margin: 0 0 18px;
		text-align: left;
	}

	.typo {
		text-decoration: underline wavy rgba(229, 57, 53, 0.75) 1.5px;
		text-underline-offset: 3px;
	}

	.ai-punch {
		color: var(--ink-soft);
		font-size: 0.9rem;
		margin: 14px 0 0;
		text-align: center;
	}

	/* ─── Faithful driver tooltip (mirrors tooltip_llm colors) ── */

	.hs-tooltip {
		background: #101010;
		border: 1px solid rgba(255, 255, 255, 0.16);
		border-radius: 10px;
		box-shadow: 0 16px 50px -12px rgba(0, 0, 0, 0.8);
		font-family: 'SF Mono', 'Cascadia Code', Menlo, Consolas, monospace;
		font-size: 0.82rem;
		line-height: 1.55;
		overflow: hidden;
		padding: 10px 0 0;
	}

	.tt-line {
		display: block;
		padding: 4px 14px;
	}

	.tt-line--selected {
		background: rgba(250, 225, 56, 0.07);
	}

	.tt-spark {
		color: #fae138;
		margin-right: 6px;
	}

	.tt-eq {
		color: #7f7f7f;
	}

	.tt-corr {
		color: #41e566;
		font-weight: 700;
	}

	.tt-nw {
		color: #ff9d1c;
		font-weight: 700;
	}

	.tt-shortcut {
		background: rgba(255, 255, 255, 0.08);
		border-radius: 5px;
		color: rgba(255, 255, 255, 0.65);
		float: right;
		font-size: 0.72rem;
		margin-left: 10px;
		padding: 1px 7px;
	}

	.tt-dim {
		opacity: 0.45;
	}

	.tt-hint {
		border-top: 1px solid rgba(255, 255, 255, 0.08);
		color: rgba(255, 255, 255, 0.45);
		font-size: 0.72rem;
		margin-top: 8px;
		padding: 7px 14px;
		text-align: center;
	}

	.tt-info {
		background: rgba(255, 255, 255, 0.04);
		color: rgba(255, 255, 255, 0.38);
		font-size: 0.7rem;
		padding: 6px 14px;
		text-align: right;
	}

	.ai-legend {
		color: var(--ink-faint);
		font-size: 0.82rem;
		line-height: 1.6;
		margin: 16px auto 0;
		max-width: 640px;
		text-align: center;
	}

	.lg-gray {
		color: #9a9a9a;
		font-weight: 600;
	}
	.lg-green {
		color: #41e566;
		font-weight: 600;
	}
	.lg-orange {
		color: #ff9d1c;
		font-weight: 600;
	}
	.lg-yellow {
		color: #fae138;
		font-weight: 600;
	}

	/* ─── Steps ─────────────────────────────────────────────── */

	.ai-step {
		margin-bottom: clamp(36px, 5vw, 56px);
	}

	/* Block layout, not flex: a flex h3 splits its text nodes into gapped
	 * flex items, which broke the line around the inline model count */
	.ai-step h3 {
		font-size: 1.25rem;
		font-weight: 700;
		margin: 0 auto 20px;
		max-width: 700px;
		text-align: center;
		text-wrap: balance;
	}

	.step-badge {
		align-items: center;
		background: rgba(236, 64, 122, 0.15);
		border: 1px solid rgba(236, 64, 122, 0.4);
		border-radius: 50%;
		color: #ff8ab5;
		display: inline-flex;
		font-size: 0.85rem;
		font-weight: 800;
		height: 30px;
		justify-content: center;
		margin-right: 10px;
		vertical-align: -0.4em;
		width: 30px;
	}

	.step-lead {
		color: var(--ink-soft);
		font-size: 0.95rem;
		line-height: 1.65;
		margin: 0 auto 22px;
		max-width: 700px;
		text-align: center;
	}

	.step-foot {
		color: var(--ink-soft);
		font-size: 0.9rem;
		line-height: 1.6;
		margin: 18px auto 0;
		max-width: 640px;
		text-align: center;
	}

	/* ─── Backends ──────────────────────────────────────────── */

	.backend-grid {
		display: grid;
		gap: 16px;
		grid-template-columns: repeat(2, 1fr);
		margin: 0 auto;
		max-width: 780px;
	}

	.backend-card {
		--accent: var(--family-ia);
	}

	.backend-card header {
		align-items: center;
		display: flex;
		gap: 12px;
		margin-bottom: 12px;
	}

	.backend-icon {
		font-size: 1.6rem;
	}

	.backend-card h4 {
		font-size: 1.05rem;
		margin: 0;
	}

	.backend-aud {
		color: var(--ink-faint);
		font-size: 0.78rem;
		margin: 1px 0 0;
	}

	.backend-port {
		background: rgba(255, 255, 255, 0.06);
		border: 1px solid var(--border);
		border-radius: 999px;
		color: var(--ink-faint);
		font-family: 'SF Mono', 'Cascadia Code', Menlo, Consolas, monospace;
		font-size: 0.7rem;
		margin-left: auto;
		padding: 3px 9px;
		white-space: nowrap;
	}

	/* ─── API providers ─────────────────────────────────────── */

	.api-band {
		margin-top: 22px;
		text-align: center;
	}

	.api-lead {
		color: var(--ink-soft);
		font-size: 0.92rem;
		margin: 0 auto 14px;
		max-width: 640px;
		text-align: center;
	}

	.api-chips {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
		justify-content: center;
		list-style: none;
	}

	.api-chip {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: 999px;
		color: var(--ink-soft);
		cursor: default;
		font-size: 0.83rem;
		font-weight: 600;
		padding: 6px 14px;
		transition:
			border-color 0.25s var(--ease),
			color 0.25s var(--ease);
	}

	.api-chip:hover {
		border-color: rgba(236, 64, 122, 0.45);
		color: var(--ink);
	}

	.api-note {
		color: var(--ink-faint);
		font-size: 0.78rem;
		margin: 12px 0 0;
		text-align: center;
	}

	.browser-embed {
		margin-top: 22px;
	}

	/* ─── Model catalog ─────────────────────────────────────── */

	/* Flexbox, not a 3-col grid: the nowrap family line gives each cell a
	 * large min-content width, and 1fr grid tracks refuse to shrink below
	 * it — the third column ended up clipped in the margin. flex-basis +
	 * min-width:0 lets cells shrink and the ellipsis do its job. */
	.provider-grid {
		display: flex;
		flex-wrap: wrap;
		gap: 10px;
	}

	.provider {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--radius-sm);
		flex: 1 1 280px;
		max-width: 100%;
		min-width: 0;
		padding: 13px 15px;
		transition: border-color 0.25s var(--ease);
	}

	.provider:hover {
		border-color: var(--border-strong);
	}

	.provider-name {
		font-size: 0.92rem;
		font-weight: 700;
	}

	.provider-family {
		color: var(--ink-faint);
		font-size: 0.76rem;
		margin-top: 2px;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.provider-meta {
		display: flex;
		gap: 10px;
		margin-top: 8px;
	}

	.provider-count {
		color: var(--accent-blue);
		font-size: 0.78rem;
		font-weight: 700;
	}

	.provider-range {
		color: var(--ink-faint);
		font-size: 0.78rem;
	}

	/* ─── Profiles ──────────────────────────────────────────── */

	.profile-grid {
		display: grid;
		gap: 12px;
		grid-template-columns: repeat(2, 1fr);
	}

	.profile-card {
		--accent: var(--family-ia);
	}

	.profile-head {
		align-items: center;
		display: flex;
		gap: 10px;
		margin-bottom: 8px;
	}

	.profile-label {
		font-family: 'SF Mono', 'Cascadia Code', Menlo, Consolas, monospace;
		font-size: 0.85rem;
		font-weight: 700;
	}

	.profile-batch {
		background: rgba(236, 64, 122, 0.15);
		border: 1px solid rgba(236, 64, 122, 0.4);
		border-radius: 999px;
		color: #ff8ab5;
		font-size: 0.66rem;
		font-weight: 700;
		letter-spacing: 0.06em;
		padding: 2px 8px;
		text-transform: uppercase;
	}

	@media (max-width: 880px) {
		.backend-grid,
		.profile-grid {
			grid-template-columns: 1fr;
		}

		.provider-grid {
			grid-template-columns: repeat(2, 1fr);
		}
	}

	@media (max-width: 520px) {
		.provider-grid {
			grid-template-columns: 1fr;
		}

		.tt-shortcut {
			display: none;
		}
	}
</style>
