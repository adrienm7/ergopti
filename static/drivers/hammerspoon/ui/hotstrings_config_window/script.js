// ui/hotstrings_config_window/script.js

/**
 * ==============================================================================
 * MODULE: Hotstrings Config Window UI Script
 * DESCRIPTION:
 * Renders the categories / sections tree from the data pushed by Lua, and
 * sends every user mutation back through the `hotstrings_config_bridge`
 * usercontent channel. The page never keeps a divergent local copy of the
 * truth — Lua pushes a fresh state after each action, and we re-render.
 * ==============================================================================
 */

let state = { categories: [], presets: [] };

// Resolve a translation key via the loaded locale strings (set by i18n.js).
function _t(key) {
	return (window._i18n_strings && window._i18n_strings[key]) || key;
}

// Apply data-i18n-key / data-i18n-title-key inside a freshly cloned template
// fragment (i18n.js cannot reach inside <template> nodes before cloning).
function applyTemplateI18n(node) {
	node.querySelectorAll("[data-i18n-key]").forEach(function (el) {
		el.textContent = _t(el.getAttribute("data-i18n-key"));
	});
	node.querySelectorAll("[data-i18n-title-key]").forEach(function (el) {
		el.title = _t(el.getAttribute("data-i18n-title-key"));
	});
}


// ============================================================
// 1/ Bridge primitives
// ============================================================

function send(payload) {
	if (
		window.webkit &&
		window.webkit.messageHandlers &&
		window.webkit.messageHandlers.hotstrings_config_bridge
	) {
		window.webkit.messageHandlers.hotstrings_config_bridge.postMessage(payload);
	}
}

function setData(next) {
	if (!next || typeof next !== "object") return;
	state = next;
	render();
}

function closeWindow() {
	send({ action: "close" });
}

function resetAll() {
	send({ action: "reset_all" });
}

function setAllGrey() {
	send({ action: "set_all_grey" });
}

// ============================================================
// 2/ Rendering
// ============================================================

function render() {
	const main = document.getElementById("content");
	main.innerHTML = "";

	const tplCat = document.getElementById("tpl-category").content;
	const tplSec = document.getElementById("tpl-section").content;

	for (const cat of state.categories) {
		const node = document.importNode(tplCat, true);
		applyTemplateI18n(node);
		const card = node.querySelector(".cat");

		card.querySelector(".cat-title").textContent = cat.title;

		const toggle = card.querySelector("[data-role=toggle]");
		const sectionsBox = card.querySelector(".sections");
		toggle.addEventListener("click", () => {
			const open = sectionsBox.hasAttribute("hidden");
			if (open) {
				sectionsBox.removeAttribute("hidden");
				toggle.classList.add("open");
			} else {
				sectionsBox.setAttribute("hidden", "");
				toggle.classList.remove("open");
			}
		});

		// File-level (category) controls
		bindDelay(card.querySelector(".field-delay"), cat, null);
		bindColor(card.querySelector(".field-color"), cat, null);

		// Sections
		for (const sec of cat.sections) {
			const secNode = document.importNode(tplSec, true);
			applyTemplateI18n(secNode);
			secNode.querySelector(".sec-title").textContent =
				sec.title || sec.name;
			bindDelay(secNode.querySelector(".field-delay"), cat, sec);
			bindColor(secNode.querySelector(".field-color"), cat, sec);
			sectionsBox.appendChild(secNode);
		}

		main.appendChild(node);
	}
}

// ============================================================
// 3/ Field bindings
// ============================================================

function bindDelay(field, cat, sec) {
	const ms = sec ? sec.delay_ms : cat.delay_ms;
	const overridden = sec ? sec.delay_overridden : cat.delay_overridden;
	const input = field.querySelector("input");
	const reset = field.querySelector(".reset");

	input.value = ms;
	field.classList.toggle("overridden", !!overridden);

	input.addEventListener("change", () => {
		const v = parseInt(input.value, 10);
		if (Number.isFinite(v) && v >= 0) {
			send({
				action: "set_delay",
				category: cat.name,
				section: sec ? sec.name : "",
				ms: v,
			});
		}
	});

	reset.addEventListener("click", () => {
		send({
			action: "clear_delay",
			category: cat.name,
			section: sec ? sec.name : "",
		});
	});
}

function bindColor(field, cat, sec) {
	const color = sec ? sec.color : cat.color;
	const overridden = sec ? sec.color_overridden : cat.color_overridden;
	const select = field.querySelector("select");
	const swatch = field.querySelector(".swatch");
	const reset = field.querySelector(".reset");

	// Build the dropdown: presets + a current-value entry when the active
	// hex is not part of the preset list, so the user always sees the
	// current selection clearly.
	select.innerHTML = "";
	const opts = state.presets.slice();
	const lower = (color || "").toLowerCase();
	const known = opts.find((p) => (p.hex || "").toLowerCase() === lower);
	if (color && !known) {
		opts.unshift({ label: color, hex: color });
	}
	for (const p of opts) {
		const o = document.createElement("option");
		o.value = p.hex;
		o.textContent = p.label;
		if ((p.hex || "").toLowerCase() === lower) o.selected = true;
		select.appendChild(o);
	}
	swatch.style.background = color || "transparent";
	field.classList.toggle("overridden", !!overridden);

	select.addEventListener("change", () => {
		const hex = select.value;
		if (hex) {
			send({
				action: "set_color",
				category: cat.name,
				section: sec ? sec.name : "",
				hex,
			});
		}
	});

	reset.addEventListener("click", () => {
		send({
			action: "clear_color",
			category: cat.name,
			section: sec ? sec.name : "",
		});
	});
}
