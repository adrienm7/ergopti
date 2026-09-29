// _shared/ui/update_channels.js

/**
 * ==============================================================================
 * MODULE: Update Channel Registry
 * DESCRIPTION:
 * Canonical interpreter of the shared update-channel registry
 * (_shared/modules/updater/channels.json): which channel a release tag belongs
 * to, how a persisted value maps to a channel, which releases a channel's
 * Versions view lists, whether an update check offers a candidate, which
 * release is a channel's latest, and which other channels published a newer
 * release than the installed build.
 *
 * FEATURES & RATIONALE:
 * 1. Data, not dialect: a channel's tag rule is structured data (a core and an
 *    optional prerelease label with a counter), interpreted by hand-written
 *    code in each runtime. No regular expression has to survive translation
 *    between JavaScript, PCRE and Lua patterns.
 * 2. One vector table: _shared/modules/updater/channel_vectors.json is replayed
 *    by this file, the Lua port (_shared/lua/updater/channels.lua) and the AHK
 *    port (windows/modules/updater/channels.ahk).
 * 3. Fail fast: a malformed registry throws at creation instead of degrading to
 *    a default channel.
 * 4. Page ready: a plain script (no module syntax), so the Versions page loads
 *    it with the generated registry data (_generated/update_channel_registry.js).
 * ==============================================================================
 */

(function (global) {
	'use strict';

	var SCHEMA_VERSION = 1;
	var CHANNEL_ID = /^[a-z][a-z0-9_]*$/;
	var PRERELEASE_LABEL = /^[a-z][a-z0-9]*$/;
	var CORE = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;
	var COUNTER = /^[1-9][0-9]*$/;
	var LOCALE_KEY = /^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$/;
	var SPARKLE_FEED = /^appcast-[a-z0-9_-]+\.xml$/;
	// A publish time exactly as GitHub writes it (UTC, whole seconds), so text
	// order is time order in every runtime without a date parser.
	var PUBLISHED_AT = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/;
	// ASCII blanks only: the Lua and AHK ports trim the same set, so a tag padded
	// with a Unicode space cannot match in one runtime and not in another.
	var EDGE_BLANKS = /^[ \t\r\n]+|[ \t\r\n]+$/g;
	var CORE_SEMVER = 'semver';

	// =========================================
	// =========================================
	// ======= 1/ Tag Parsing ==================
	// =========================================
	// =========================================

	/**
	 * Parses a release tag into its X.Y.Z core and prerelease identifiers.
	 * Build metadata ("+...") is refused: the workflow never publishes it.
	 * @param {*} tag - Release tag, with or without its leading "v".
	 * @return {{core: string, prerelease: string[]|null}|null}
	 */
	function _parseTag(tag) {
		if (typeof tag !== 'string') return null;
		var text = tag.replace(EDGE_BLANKS, '');
		var first = text.charAt(0);
		if (first === 'v' || first === 'V') text = text.slice(1);
		if (text.indexOf('+') !== -1) return null;
		var dash = text.indexOf('-');
		var core = dash === -1 ? text : text.slice(0, dash);
		if (!CORE.test(core)) return null;
		if (dash === -1) return { core: core, prerelease: null };
		var parts = text.slice(dash + 1).split('.');
		for (var i = 0; i < parts.length; i += 1) {
			if (parts[i] === '') return null;
		}
		return { core: core, prerelease: parts };
	}

	/**
	 * Applies one channel's structured tag rule to a parsed tag.
	 * @param {{core: string, prerelease: ?{label: string, counter: boolean}}} rule
	 * @param {?{core: string, prerelease: string[]|null}} parsed
	 * @return {boolean}
	 */
	function _matchesRule(rule, parsed) {
		if (!parsed) return false;
		if (rule.core !== CORE_SEMVER && rule.core !== parsed.core) return false;
		if (rule.prerelease === null) return parsed.prerelease === null;
		var parts = parsed.prerelease;
		if (parts === null || parts[0] !== rule.prerelease.label) return false;
		if (rule.prerelease.counter) return parts.length === 2 && COUNTER.test(parts[1]);
		return parts.length === 1;
	}

	/**
	 * Reports whether one tag could satisfy both rules, so two channels can
	 * never claim the same release.
	 * @return {boolean}
	 */
	function _rulesOverlap(a, b) {
		var coresOverlap = a.core === CORE_SEMVER || b.core === CORE_SEMVER || a.core === b.core;
		if (!coresOverlap) return false;
		if (a.prerelease === null || b.prerelease === null) return a.prerelease === b.prerelease;
		return (
			a.prerelease.label === b.prerelease.label && a.prerelease.counter === b.prerelease.counter
		);
	}

	// =========================================
	// =========================================
	// ======= 2/ Registry Validation ==========
	// =========================================
	// =========================================

	function _fail(message) {
		throw new Error('Invalid update channel registry: ' + message);
	}

	function _hasOwn(object, key) {
		return Object.prototype.hasOwnProperty.call(object, key);
	}

	/**
	 * Validates one tag rule and returns a detached copy.
	 * @return {{core: string, prerelease: ?{label: string, counter: boolean}}}
	 */
	function _validateRule(id, tag) {
		if (!tag || typeof tag !== 'object') _fail('channel ' + id + ' has no tag rule');
		if (tag.core !== CORE_SEMVER && !(typeof tag.core === 'string' && CORE.test(tag.core))) {
			_fail('channel ' + id + ' has an invalid tag core');
		}
		// false, not null: the shared Lua JSON decoder turns a null into a sentinel.
		if (tag.prerelease === false) return { core: tag.core, prerelease: null };
		var pre = tag.prerelease;
		if (
			!pre ||
			typeof pre !== 'object' ||
			typeof pre.label !== 'string' ||
			!PRERELEASE_LABEL.test(pre.label)
		) {
			_fail('channel ' + id + ' has an invalid prerelease label');
		}
		if (typeof pre.counter !== 'boolean')
			_fail('channel ' + id + ' has no prerelease counter flag');
		return { core: tag.core, prerelease: { label: pre.label, counter: pre.counter } };
	}

	/**
	 * Validates the decoded channels.json and builds the lookup tables.
	 * @param {Object} registry - Decoded channels.json.
	 * @return {{order: Object[], byId: Object, aliases: Object, unreleased: string}}
	 */
	function _validate(registry) {
		if (!registry || typeof registry !== 'object') _fail('not an object');
		if (registry.schema_version !== SCHEMA_VERSION) _fail('unsupported schema_version');
		if (!Array.isArray(registry.channels) || registry.channels.length === 0) _fail('no channels');
		var order = [];
		var byId = {};
		var aliases = {};
		registry.channels.forEach(function (entry, index) {
			if (!entry || typeof entry !== 'object')
				_fail('channel #' + (index + 1) + ' is not an object');
			var id = entry.id;
			if (typeof id !== 'string' || !CHANNEL_ID.test(id))
				_fail('channel #' + (index + 1) + ' has an invalid id');
			if (_hasOwn(byId, id) || _hasOwn(aliases, id))
				_fail('channel id ' + id + ' is declared twice');
			['label_key', 'menu_label_key'].forEach(function (field) {
				if (typeof entry[field] !== 'string' || !LOCALE_KEY.test(entry[field])) {
					_fail('channel ' + id + ' has an invalid ' + field);
				}
			});
			if (typeof entry.github_prerelease !== 'boolean')
				_fail('channel ' + id + ' has no github_prerelease flag');
			if (typeof entry.sparkle_feed !== 'string' || !SPARKLE_FEED.test(entry.sparkle_feed)) {
				_fail('channel ' + id + ' has an invalid sparkle_feed');
			}
			if (!Array.isArray(entry.aliases)) _fail('channel ' + id + ' has no aliases list');
			var rule = _validateRule(id, entry.tag);
			order.forEach(function (previous) {
				if (_rulesOverlap(previous.rule, rule))
					_fail('channels ' + previous.id + ' and ' + id + ' claim the same tags');
			});
			var record = {
				id: id,
				rank: index + 1,
				labelKey: entry.label_key,
				menuLabelKey: entry.menu_label_key,
				aliases: entry.aliases.slice(),
				githubPrerelease: entry.github_prerelease,
				sparkleFeed: entry.sparkle_feed,
				rule: rule
			};
			order.push(record);
			byId[id] = record;
		});
		order.forEach(function (record) {
			record.aliases.forEach(function (alias) {
				if (typeof alias !== 'string' || !CHANNEL_ID.test(alias))
					_fail('channel ' + record.id + ' has an invalid alias');
				if (_hasOwn(byId, alias) || _hasOwn(aliases, alias))
					_fail('alias ' + alias + ' is declared twice');
				aliases[alias] = record.id;
			});
		});
		var unreleased = registry.unreleased_build_channel;
		if (typeof unreleased !== 'string' || !_hasOwn(byId, unreleased)) {
			_fail('unreleased_build_channel names no channel');
		}
		return { order: order, byId: byId, aliases: aliases, unreleased: unreleased };
	}

	// =========================================
	// =========================================
	// ======= 3/ Public Interpreter ===========
	// =========================================
	// =========================================

	/**
	 * Creates the interpreter of one registry.
	 * @param {Object} registry - Decoded channels.json.
	 * @return {Object} Frozen channel API.
	 */
	function createUpdateChannels(registry) {
		var tables = _validate(registry);
		var byId = tables.byId;

		function known(id) {
			return typeof id === 'string' && _hasOwn(byId, id);
		}

		/** Public view of one channel, or null. */
		function channel(id) {
			if (!known(id)) return null;
			var record = byId[id];
			return Object.freeze({
				id: record.id,
				rank: record.rank,
				labelKey: record.labelKey,
				menuLabelKey: record.menuLabelKey,
				aliases: Object.freeze(record.aliases.slice()),
				githubPrerelease: record.githubPrerelease,
				sparkleFeed: record.sparkleFeed
			});
		}

		/** Maps a persisted value or an alias to a channel id (exact match). */
		function resolve(value) {
			if (typeof value !== 'string') return null;
			if (_hasOwn(byId, value)) return value;
			return _hasOwn(tables.aliases, value) ? tables.aliases[value] : null;
		}

		/** Reports whether a release tag belongs to one channel. */
		function matches(id, tag) {
			return known(id) && _matchesRule(byId[id].rule, _parseTag(tag));
		}

		/** Returns the channel that owns a release tag, or null. */
		function channelForTag(tag) {
			var parsed = _parseTag(tag);
			for (var i = 0; i < tables.order.length; i += 1) {
				if (_matchesRule(tables.order[i].rule, parsed)) return tables.order[i].id;
			}
			return null;
		}

		/**
		 * Reports whether a channel's Versions view lists a release: the view
		 * shows its own releases and those of every more stable channel.
		 */
		function visibleIn(viewId, tag) {
			if (!known(viewId)) return false;
			var owner = channelForTag(tag);
			return owner !== null && byId[owner].rank <= byId[viewId].rank;
		}

		/**
		 * Decides whether an update check offers a candidate. A deliberate switch
		 * to another channel offers that channel's latest release even when
		 * semver orders it below the installed build; within one channel only a
		 * strictly newer release is offered.
		 * @param {Function} compare - Shared semver comparison (version.js).
		 */
		function shouldOffer(latest, current, selected, installed, compare) {
			if (!known(selected) || !matches(selected, latest)) return false;
			if (selected !== installed) return known(installed);
			return compare(latest, current) > 0;
		}

		/**
		 * Returns the index of a channel's latest tag in a list (semver order,
		 * first occurrence on a tie), or -1. GitHub lists by publish date, so a
		 * later stable must not hide a higher prerelease and vice versa.
		 * @param {Function} compare - Shared semver comparison (version.js).
		 */
		function pickLatest(tags, id, compare) {
			if (!known(id) || !Array.isArray(tags)) return -1;
			var best = -1;
			for (var i = 0; i < tags.length; i += 1) {
				if (!matches(id, tags[i])) continue;
				if (best === -1 || compare(tags[i], tags[best]) > 0) best = i;
			}
			return best;
		}

		/**
		 * Lists, in registry order, every channel other than the checked one
		 * whose latest release was published strictly after the installed build.
		 * The installed build's time is that of the first listed release of the
		 * same version; a build that is not listed (older than the list, or a
		 * source checkout), or listed without a valid time, predates the list.
		 * @param {{tag: string, published_at: string}[]} releases - The release list.
		 * @param {string} selected - The checked channel.
		 * @param {string} installed - The installed build's version.
		 * @param {Function} compare - Shared semver comparison (version.js).
		 * @return {{channel: string, tag: string}[]}
		 */
		function newerElsewhere(releases, selected, installed, compare) {
			if (!known(selected) || !Array.isArray(releases)) return [];
			var tags = releases.map(function (release) {
				return release && typeof release.tag === 'string' ? release.tag : '';
			});
			var installedAt = null;
			if (channelForTag(installed) !== null) {
				for (var i = 0; i < releases.length; i += 1) {
					if (channelForTag(tags[i]) === null || compare(tags[i], installed) !== 0) continue;
					var own = releases[i].published_at;
					installedAt = typeof own === 'string' && PUBLISHED_AT.test(own) ? own : null;
					break;
				}
			}
			var found = [];
			tables.order.forEach(function (record) {
				if (record.id === selected) return;
				var index = pickLatest(tags, record.id, compare);
				if (index === -1) return;
				var at = releases[index].published_at;
				if (typeof at !== 'string' || !PUBLISHED_AT.test(at)) return;
				if (installedAt !== null && at <= installedAt) return;
				found.push({ channel: record.id, tag: tags[index] });
			});
			return found;
		}

		return Object.freeze({
			ids: Object.freeze(
				tables.order.map(function (record) {
					return record.id;
				})
			),
			unreleasedBuildChannel: tables.unreleased,
			channel: channel,
			rank: function (id) {
				return known(id) ? byId[id].rank : 0;
			},
			resolve: resolve,
			matches: matches,
			channelForTag: channelForTag,
			visibleIn: visibleIn,
			shouldOffer: shouldOffer,
			pickLatest: pickLatest,
			newerElsewhere: newerElsewhere
		});
	}

	global.createUpdateChannels = createUpdateChannels;
})(window);
