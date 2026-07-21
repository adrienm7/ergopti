<!-- src/routes/ergopti-plus/DriverFrame.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Embedded Driver Window
DESCRIPTION:
One real driver webview embedded where the page talks about it: the same
HTML/JS/CSS bundle the drivers open natively, served as-is from static/ and
framed in the OS chrome selected by the page toggle. The page plays the
native host's role — same-origin iframes let it call the exact injection
entry points the drivers use (injectModels, initData).

FEATURES & RATIONALE:
1. Dispatched, Not Gathered: each window lives inside the section that
   explains it (editor with the hotstrings, catalog with the AI…), instead
   of a separate gallery the visitor has to connect back mentally.
2. Host Emulation: injection goes through the drivers' own contracts, so
   the demo can never diverge from the real UI.
==============================================================================
-->

<script>
	import { base } from '$app/paths';
	import WindowChrome from './WindowChrome.svelte';
	import { reveal } from './reveal.js';
	import { ui } from './state.svelte.js';

	/** Default max height of the embedded window area. */
	const DEFAULT_DISPLAY_HEIGHT = 600;

	/**
	 * @type {{
	 *   id: string,
	 *   width: number,
	 *   height: number,
	 *   displayHeight?: number,
	 *   oninfochange?: ((fields: Record<string, string>) => void) | null
	 * }}
	 */
	let { id, width, height, displayHeight = DEFAULT_DISPLAY_HEIGHT, oninfochange = null } = $props();

	let frameHeight = $derived(Math.min(displayHeight, height));

	// The two dashboards support a bridge-less bootstrap: a "#prefetch=<url>"
	// hash makes them load a data blob instead of waiting for a native host.
	// The site ships synthetic demo blobs under /demo/ (see
	// tools/dev/gen-demo-metrics.cjs) so the dashboards render populated.
	let frameSrc = $derived(
		id.startsWith('metrics_')
			? `${base}/ergopti_plus/_shared/ui/${id}/index.html#prefetch=${base}/demo/${id}_prefetch.json`
			: `${base}/ergopti_plus/_shared/ui/${id}/index.html`
	);

	// One shared fetch of the French locale strings for every embedded frame.
	// Injected through the driver's own i18n_apply() BEFORE initData, so the
	// windows never render their English _t() fallbacks. When the site gains
	// its 21 locales, this is the exact hook that will follow the visitor's
	// language.
	/** @type {Promise<Record<string, string>> | null} */
	let frStringsPromise = null;

	/**
	 * Fetch (once) the driver's French locale strings.
	 * @returns {Promise<Record<string, string>>}
	 */
	function frStrings() {
		frStringsPromise ??= fetch(`${base}/ergopti_plus/_shared/data/locales/fr.json`)
			.then((r) => r.json())
			.catch(() => ({}));
		return frStringsPromise;
	}

	/**
	 * Parse a "30.53B" / "350M" parameter string into billions.
	 * @param {unknown} raw
	 * @returns {number}
	 */
	function parseParams(raw) {
		if (typeof raw !== 'string' || raw === '') return 0;
		const m = raw.match(/([\d.]+)\s*([BMK]?)/i);
		if (!m) return 0;
		const value = parseFloat(m[1]);
		const unit = (m[2] || 'B').toUpperCase();
		if (unit === 'B') return value;
		if (unit === 'M') return value / 1000;
		return value;
	}

	/**
	 * Feed the model browser with the real catalog, exactly like the native
	 * hosts do: flatten models.json into injectModels() rows.
	 * @param {Window} win
	 */
	async function injectModelBrowser(win) {
		win.i18n_apply?.(await frStrings());
		const res = await fetch(`${base}/ergopti_plus/_shared/modules/llm/models.json`);
		const catalog = await res.json();
		const models = [];
		for (const provider of catalog) {
			for (const family of provider.families ?? []) {
				for (const m of family.models ?? []) {
					const total = parseParams(m.parameters?.total);
					const activeB = parseParams(m.parameters?.active);
					models.push({
						name: m.name,
						family: family.label,
						provider: provider.label,
						params_b: total,
						active_b: activeB,
						is_moe: activeB > 0 && activeB < total,
						ram_gb:
							m.hardware_requirements?.ollama?.ram_gb ?? m.hardware_requirements?.mlx?.ram_gb ?? 0,
						speed_tok_s: m.capabilities?.speed_tok_s ?? 0,
						type: m.type || 'chat',
						installed: false,
						url: m.urls?.hf || ''
					});
				}
			}
		}
		const defaultModel = models.find((m) => /qwen/i.test(m.name)) ?? models[0];
		if (defaultModel) defaultModel.installed = true;
		win.injectModels?.({ backend: 'ollama', active: defaultModel?.name ?? '', models });
	}

	/**
	 * Feed the hotstring editor with a small demo dataset through its real
	 * initData() contract.
	 * @param {Window} win
	 */
	async function injectHotstringEditor(win) {
		win.i18n_apply?.(await frStrings());
		const entry = (trigger, output) => ({
			trigger,
			output,
			is_word: false,
			auto_expand: false,
			is_case_sensitive: false,
			final_result: false
		});
		win.initData?.({
			trigger_char: '★',
			star: '★',
			compact_view: false,
			auto_close: false,
			open_mode: 'menu',
			sections: [
				{
					name: 'signatures',
					description: 'Signatures',
					_exp: true,
					entries: [
						entry('sig★', 'Cordialement,\nAdrien'),
						entry('np★', 'Adrien Moyaux'),
						entry('em★', 'adrien@exemple.fr')
					]
				},
				{
					name: 'travail',
					description: 'Travail',
					_exp: true,
					entries: [
						entry('adr★', '15 rue Lafayette, 75009 Paris'),
						entry('iban★', 'FR76 1234 5678 9012 3456 789'),
						entry('tel★', '+33 6 12 34 56 78')
					]
				}
			]
		});
	}

	/**
	 * Feed the personal-info editor with demo fields + the real French locale
	 * strings so its chrome labels render.
	 * @param {Window} win
	 */
	async function injectPersonalInfo(win) {
		const strings = await frStrings();
		win.initData?.({
			strings,
			fields: [
				{ key: 'first_name', label: 'Prénom', value: 'Adrien' },
				{ key: 'last_name', label: 'Nom', value: 'Moyaux' },
				{ key: 'email', label: 'E-mail', value: 'adrien@exemple.fr' },
				{ key: 'phone', label: 'Téléphone', value: '+33 6 12 34 56 78' },
				{ key: 'address', label: 'Adresse', value: '15 rue Lafayette, 75009 Paris' },
				{ key: 'iban', label: 'IBAN', value: 'FR76 1234 5678 9012 3456 789' }
			]
		});

		// Live wire: report every edit up to the page so the hotstring
		// examples rebuild themselves in real time — the whole point of
		// dynamic hotstrings, demonstrated with the real window.
		if (oninfochange) {
			const rows = win.document.getElementById('rows');
			rows?.addEventListener('input', () => {
				const values = {};
				rows.querySelectorAll('input').forEach((inp) => {
					values[inp.getAttribute('name')] = inp.value;
				});
				oninfochange(values);
			});
		}
	}

	/**
	 * Play the native host: once the iframe loads, inject the data through
	 * the same entry point the driver uses for this window.
	 * @param {Event} ev
	 */
	function onFrameLoad(ev) {
		const win = ev.currentTarget?.contentWindow;
		if (!win) return;
		try {
			if (id === 'model_browser') injectModelBrowser(win);
			else if (id === 'hotstring_editor') injectHotstringEditor(win);
			else if (id === 'personal_info_editor') injectPersonalInfo(win);
			// changelog and the dashboards need nothing — they self-bootstrap.
		} catch (e) {
			console.error('Injection dans la fenêtre du driver impossible :', e);
		}
	}
</script>

<!-- The shell hugs the window's native width so the iframe fills it edge to
     edge — no leftover gutter, narrow windows stay naturally centered -->
<div class="frame-shell ep-window os-{ui.osStyle}" style="max-width: {width}px;" use:reveal>
	<WindowChrome title="/ergopti_plus/_shared/ui/{id}/ · {width}×{height}" live={true} />
	<div class="frame-wrap" style="height: {frameHeight}px;">
		<iframe src={frameSrc} title={id} loading="lazy" onload={onFrameLoad}></iframe>
	</div>
</div>

<style>
	.frame-shell {
		margin: 0 auto;
		width: 100%;
	}

	.frame-wrap {
		background: #101018;
		overflow: hidden;
		position: relative;
	}

	.frame-wrap iframe {
		border: 0;
		display: block;
		height: 100%;
		width: 100%;
	}

	@media (max-width: 720px) {
		.frame-wrap {
			max-height: 460px;
		}
	}
</style>
