; static/ergopti_plus/windows/_generated/registry.ahk

; ==========================================
; AUTO-GENERATED — do not edit manually
; Source: static/ergopti_plus/_shared/core/domain/Registry.spec.js
; Run: npm run codegen:registry
; ==========================================

; ==============================================================================
; MODULE: Registry
; DESCRIPTION:
; AHK v2 implementation of the Registry domain contract. Stores all known
; trigger->replacement mappings, indexes them by tail character for O(1)
; candidate lookup, and supports atomic group enable/disable toggling.
;
; FEATURES & RATIONALE:
; 1. Tail-char bucketing: mappings indexed by last UTF-16 code unit so the
;    hot path only scans candidates whose tail matches the last typed char.
; 2. Group lifecycle: disabling a group removes entries from the live index
;    without deleting them; re-enabling atomically restores them.
; 3. Longest-first ordering: Sort() ensures the first hit is always the
;    longest possible trigger. Ties broken by group_order then seq.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; Default group name assigned when the caller omits opts.group.
global REGISTRY_DEFAULT_GROUP := "default"

; Initial capacity hint for per-tail-char bucket arrays (no hard limit).
global REGISTRY_BUCKET_INIT_CAPACITY := 8



; =================================
; =================================
; ======= 2/ Registry Class =======
; =================================
; =================================

class Registry {

	; ===============================
	; ===== 2.1) Instance State =====
	; ===============================

	; _mappings_by_tail_char : Map<string, Array<Mapping>>
	; Live index — only contains mappings whose group is enabled.
	_mappings_by_tail_char := Map()

	; _all_mappings : Array<Mapping>
	; Master store — every mapping regardless of group state.
	_all_mappings := []

	; _disabled_groups : Map<string, true>
	; Names of currently disabled groups for O(1) membership test.
	_disabled_groups := Map()

	; _group_order_map : Map<string, number>
	; Tracks the load-order rank of each group (insertion order).
	_group_order_map := Map()

	; _seq : integer
	; Monotonically increasing insertion counter for stable tiebreaking.
	_seq := 0



	; ====================
	; ===== 2.2) Add =====
	; ====================

	; Registers a trigger->replacement mapping.
	; Duplicate triggers within the same group are logged and skipped.
	;
	; Param trigger     - UTF-16 trigger string.
	; Param repl        - Raw replacement (may contain tokens).
	; Param opts        - Optional Map with keys: is_word, auto, has_magic,
	;                     final_result, group, color, group_order.
	; Returns Mapping   - The created Mapping object, or false on duplicate.
	Add(trigger, repl, opts := Map()) {
		; Resolve options with safe defaults
		local group       := opts.Has("group")        ? opts["group"]        : REGISTRY_DEFAULT_GROUP
		local is_word     := opts.Has("is_word")      ? opts["is_word"]      : false
		local auto        := opts.Has("auto")         ? opts["auto"]         : false
		local has_magic   := opts.Has("has_magic")    ? opts["has_magic"]    : false
		local final_res   := opts.Has("final_result") ? opts["final_result"] : false
		local color       := opts.Has("color")        ? opts["color"]        : ""

		; Assign group_order — first time a group name is seen it gets the next rank
		if (!this._group_order_map.Has(group)) {
			this._group_order_map[group] := this._group_order_map.Count
		}
		local group_order := this._group_order_map[group]

		; Guard: detect duplicate trigger within the same group
		for existing in this._all_mappings {
			if (existing.trigger = trigger && existing.group = group) {
				LoggerWarn("registry", "Add: duplicate trigger '{1}' in group '{2}' — skipped.", trigger, group)
				return false
			}
		}

		; Compute derived fields
		local tlen             := StrLen(trigger)
		; AHK strings are UTF-16; byte length = char count * 2
		local trigger_bytes    := tlen * 2
		; Tail char = last UTF-16 code unit (SubStr with negative offset)
		local tail_char        := SubStr(trigger, -1)
		; Magic-key fields — star_base is trigger without trailing magic char
		local star_base        := has_magic ? SubStr(trigger, 1, tlen - 1) : trigger
		local star_base_len    := StrLen(star_base)
		local star_base_bytes  := star_base_len * 2
		local star_base_tail   := star_base_len > 0 ? SubStr(star_base, -1) : ""
		; plain_repl = repl with tokens resolved to literal text (precomputed)
		; For now plain_repl mirrors repl; a token resolver can inject here later
		local plain_repl       := repl

		this._seq += 1

		local mapping := Map(
			"trigger",         trigger,
			"repl",            repl,
			"plain_repl",      plain_repl,
			"is_word",         is_word,
			"auto",            auto,
			"seq",             this._seq,
			"tlen",            tlen,
			"trigger_bytes",   trigger_bytes,
			"tail_char",       tail_char,
			"has_magic",       has_magic,
			"star_base",       star_base,
			"star_base_bytes", star_base_bytes,
			"star_base_tail",  star_base_tail,
			"group",           group,
			"group_order",     group_order,
			"final_result",    final_res,
			"color",           color
		)

		; Persist in master store
		this._all_mappings.Push(mapping)

		; Add to live index only when the group is active
		if (!this._disabled_groups.Has(group)) {
			this._IndexMapping(mapping)
		}

		return mapping
	}



	; ================================
	; ===== 2.3) MappingsForTail =====
	; ================================

	; Returns all active mappings whose tail char equals tailChar.
	; Result is sorted: longest trigger first, then group_order, then seq.
	;
	; Param tailChar - A single UTF-16 code unit (the last typed character).
	; Returns Array  - Sorted array of Mapping objects.
	MappingsForTail(tailChar) {
		if (!this._mappings_by_tail_char.Has(tailChar)) {
			return []
		}
		return this._mappings_by_tail_char[tailChar]
	}



	; ===========================================
	; ===== 2.4) EnableGroup / DisableGroup =====
	; ===========================================

	; Restores all mappings in `name` to the live index.
	; No-op when the group is already enabled.
	;
	; Param name - Group name string.
	EnableGroup(name) {
		if (!this._disabled_groups.Has(name)) {
			return ; Already enabled
		}
		this._disabled_groups.Delete(name)
		; Re-index every mapping that belongs to this group
		for m in this._all_mappings {
			if (m["group"] = name) {
				this._IndexMapping(m)
			}
		}
	}

	; Removes all mappings in `name` from the live index.
	; No-op when the group is already disabled.
	;
	; Param name - Group name string.
	DisableGroup(name) {
		if (this._disabled_groups.Has(name)) {
			return ; Already disabled
		}
		this._disabled_groups[name] := true
		; Rebuild all buckets that contain at least one mapping from this group
		this._RebuildIndex()
	}



	; =============================
	; ===== 2.5) Clear / Size =====
	; =============================

	; Removes all mappings and resets the registry to the empty state.
	Clear() {
		this._mappings_by_tail_char := Map()
		this._all_mappings          := []
		this._disabled_groups       := Map()
		this._group_order_map       := Map()
		this._seq                   := 0
	}

	; Returns the total number of active mappings across all enabled groups.
	; Returns integer.
	Size() {
		local total := 0
		for _, bucket in this._mappings_by_tail_char {
			total += bucket.Length
		}
		return total
	}



	; ================================
	; ===== 2.6) Private Helpers =====
	; ================================

	; Inserts a single mapping into the live tail-char index and re-sorts its bucket.
	;
	; Param mapping - A Mapping Map object.
	_IndexMapping(mapping) {
		local tc := mapping["tail_char"]
		if (!this._mappings_by_tail_char.Has(tc)) {
			this._mappings_by_tail_char[tc] := []
		}
		this._mappings_by_tail_char[tc].Push(mapping)
		this._SortBucket(tc)
	}

	; Rebuilds the entire live index from _all_mappings, respecting disabled groups.
	; Called after DisableGroup to flush entries in O(n) rather than per-bucket.
	_RebuildIndex() {
		this._mappings_by_tail_char := Map()
		for m in this._all_mappings {
			if (!this._disabled_groups.Has(m["group"])) {
				this._IndexMapping(m)
			}
		}
	}

	; Sorts a single bucket in-place: longest trigger first, then group_order, then seq.
	; Uses a simple insertion sort — buckets are small (< 20 entries typical).
	;
	; Param tc - Tail char key.
	_SortBucket(tc) {
		local arr := this._mappings_by_tail_char[tc]
		local n   := arr.Length
		if (n <= 1) {
			return
		}
		; Insertion sort — stable and avoids closure overhead of array sort callbacks
		local i := 2
		while (i <= n) {
			local key := arr[i]
			local j   := i - 1
			while (j >= 1 && this._ComesBefore(key, arr[j])) {
				arr[j + 1] := arr[j]
				j -= 1
			}
			arr[j + 1] := key
			i += 1
		}
	}

	; Returns true if mapping `a` should sort before mapping `b`.
	; Order: longest tlen descending, group_order ascending, seq ascending.
	;
	; Param a - Mapping Map object.
	; Param b - Mapping Map object.
	; Returns boolean.
	_ComesBefore(a, b) {
		if (a["tlen"] != b["tlen"]) {
			return a["tlen"] > b["tlen"] ; Longest first
		}
		if (a["group_order"] != b["group_order"]) {
			return a["group_order"] < b["group_order"] ; Earlier group first
		}
		return a["seq"] < b["seq"] ; Earlier insertion first
	}

}