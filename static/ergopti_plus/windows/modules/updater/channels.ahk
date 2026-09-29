; modules/updater/channels.ahk

; ==============================================================================
; MODULE: Updater / Update Channel Registry
; DESCRIPTION:
; Interprets the shared update-channel registry (_shared/modules/updater/channels.json,
; generated as UpdateChannelRegistryData() in _generated/update_channels.ahk):
; which channel a release tag belongs to, how a persisted value maps to a
; channel, which releases a channel's Versions view lists, whether an update
; check offers a candidate, which release is a channel's latest, and which
; other channels published a newer release than the installed build.
;
; FEATURES & RATIONALE:
; 1. Port of the canonical JavaScript matcher (_shared/ui/update_channels.js).
;    The tag rule is structured data interpreted here, never a regular
;    expression copied from another dialect. tests/unit/test_updater_channel_registry.ahk
;    replays the shared _shared/modules/updater/channel_vectors.json.
; 2. Identity is exact: channel ids, aliases and prerelease labels compare with
;    the case-sensitive == and !== operators and Map keys.
; 3. Fail fast: malformed generated data throws on first use instead of
;    degrading to a default channel.
; ==============================================================================



; =====================================
; ===== 1.1) Registry =================
; =====================================

global _UpdateChannelsRegistry := 0

; Returns the validated registry, built once from the generated data.
_UpdateChannels_Registry() {
	global _UpdateChannelsRegistry
	if IsObject(_UpdateChannelsRegistry)
		return _UpdateChannelsRegistry
	Data := UpdateChannelRegistryData()
	if !(Data is Map) || Data.Get("schema_version", 0) != 1
		throw ValueError("Update channel registry: unsupported schema version")
	Channels := Data.Get("channels", 0)
	if !(Channels is Array) || Channels.Length == 0
		throw ValueError("Update channel registry: no channel is declared")
	ById := Map()
	Aliases := Map()
	Order := []
	for Index, Channel in Channels {
		Id := Channel.Get("id", "")
		if !(Id is String) || !RegExMatch(Id, "^[a-z][a-z0-9_]*\z")
			throw ValueError("Update channel registry: channel #" . Index . " has an invalid id")
		if ById.Has(Id)
			throw ValueError("Update channel registry: channel id " . Id . " is declared twice")
		Channel["rank"] := Index
		ById[Id] := Channel
		Order.Push(Channel)
	}
	for _, Channel in Order {
		for _, Alias in Channel["aliases"] {
			if ById.Has(Alias) || Aliases.Has(Alias)
				throw ValueError("Update channel registry: alias " . Alias . " is declared twice")
			Aliases[Alias] := Channel["id"]
		}
	}
	Unreleased := Data.Get("unreleased_build_channel", "")
	if !ById.Has(Unreleased)
		throw ValueError("Update channel registry: unreleased_build_channel names no channel")
	_UpdateChannelsRegistry := { Order: Order, ById: ById, Aliases: Aliases, Unreleased: Unreleased }
	return _UpdateChannelsRegistry
}

; Returns the channel ids in stability order (a fresh Array).
UpdateChannels_Ids() {
	Ids := []
	for _, Channel in _UpdateChannels_Registry().Order
		Ids.Push(Channel["id"])
	return Ids
}

; Reports whether a value is exactly the id of a declared channel.
UpdateChannels_IsKnown(Id) {
	return Id is String && _UpdateChannels_Registry().ById.Has(Id)
}

; Returns the channel a build whose version belongs to no channel follows.
UpdateChannels_UnreleasedBuildChannel() {
	return _UpdateChannels_Registry().Unreleased
}

; Returns one channel field (label_key, menu_label_key, github_prerelease,
; sparkle_feed, rank). Throws for an unknown channel: callers resolve first.
UpdateChannels_Field(Id, Field) {
	if !UpdateChannels_IsKnown(Id)
		throw ValueError("Unknown update channel: " . (Id is String ? Id : Type(Id)))
	return _UpdateChannels_Registry().ById[Id][Field]
}

; Maps a persisted value or an alias to a channel id (exact match), or "".
UpdateChannels_Resolve(Value) {
	if !(Value is String)
		return ""
	Registry := _UpdateChannels_Registry()
	if Registry.ById.Has(Value)
		return Value
	return Registry.Aliases.Get(Value, "")
}



; =====================================
; ===== 1.2) Tag rules ================
; =====================================

; Parses a release tag into its X.Y.Z core and prerelease identifiers, or 0.
; Build metadata ("+...") is refused; only ASCII blanks are trimmed, as in the
; JavaScript and Lua ports.
_UpdateChannels_ParseTag(Tag) {
	if !(Tag is String)
		return 0
	Text := Trim(Tag, " `t`r`n")
	First := SubStr(Text, 1, 1)
	if (First == "v" or First == "V")
		Text := SubStr(Text, 2)
	if InStr(Text, "+")
		return 0
	Dash := InStr(Text, "-")
	Core := Dash ? SubStr(Text, 1, Dash - 1) : Text
	if !RegExMatch(Core, "^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z")
		return 0
	if !Dash
		return { Core: Core, Pre: 0 }
	Parts := StrSplit(SubStr(Text, Dash + 1), ".")
	if (Parts.Length == 0)
		return 0
	for _, Part in Parts {
		if (Part == "")
			return 0
	}
	return { Core: Core, Pre: Parts }
}

; Applies one channel's structured tag rule to a parsed tag.
_UpdateChannels_MatchesRule(Channel, Parsed) {
	if !IsObject(Parsed)
		return false
	Core := Channel["tag_core"]
	if (Core !== "semver" and Core !== Parsed.Core)
		return false
	Rule := Channel["tag_prerelease"]
	if !IsObject(Rule)
		return !IsObject(Parsed.Pre)
	Parts := Parsed.Pre
	if !IsObject(Parts) || Parts[1] !== Rule["label"]
		return false
	if Rule["counter"]
		return (Parts.Length == 2 && RegExMatch(Parts[2], "^[1-9][0-9]*\z")) ? true : false
	return Parts.Length == 1
}

; Reports whether a release tag belongs to one channel.
UpdateChannels_Matches(Id, Tag) {
	if !UpdateChannels_IsKnown(Id)
		return false
	return _UpdateChannels_MatchesRule(_UpdateChannels_Registry().ById[Id],
		_UpdateChannels_ParseTag(Tag))
}

; Returns the channel that owns a release tag, or "".
UpdateChannels_ForTag(Tag) {
	Parsed := _UpdateChannels_ParseTag(Tag)
	for _, Channel in _UpdateChannels_Registry().Order {
		if _UpdateChannels_MatchesRule(Channel, Parsed)
			return Channel["id"]
	}
	return ""
}

; Reports whether a channel's Versions view lists a release: its own releases
; and those of every more stable channel.
UpdateChannels_VisibleIn(ViewId, Tag) {
	if !UpdateChannels_IsKnown(ViewId)
		return false
	Owner := UpdateChannels_ForTag(Tag)
	if (Owner == "")
		return false
	ById := _UpdateChannels_Registry().ById
	return ById[Owner]["rank"] <= ById[ViewId]["rank"]
}

; Decides whether an update check offers a candidate. A deliberate switch to
; another channel is an artifact-family migration: it offers that channel's
; latest release even when semver orders the CI dev family below the installed
; stable version. Within one channel only a strictly newer release is offered.
UpdateChannels_ShouldOffer(Latest, Current, Selected, Installed) {
	if !UpdateChannels_Matches(Selected, Latest)
		return false
	if (Selected !== Installed)
		return UpdateChannels_IsKnown(Installed)
	return _Updater_CompareVersions(Latest, Current) > 0
}

; Returns the position (1-based) of a channel's latest tag in an Array, by
; semver order with the first occurrence kept on a tie, or 0.
UpdateChannels_PickLatest(Tags, Id) {
	if !(Tags is Array) || !UpdateChannels_IsKnown(Id)
		return 0
	Best := 0
	for Index, Tag in Tags {
		if !UpdateChannels_Matches(Id, Tag)
			continue
		if (Best == 0 or _Updater_CompareVersions(Tag, Tags[Best]) > 0)
			Best := Index
	}
	return Best
}

; Reports whether a publish time is exactly as GitHub writes it (UTC, whole
; seconds), so text order is time order without a date parser.
_UpdateChannels_IsPublishTime(Value) {
	return (Value is String) && RegExMatch(Value, "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z") ? true : false
}

; Lists, in registry order, every channel other than the checked one whose
; latest release was published strictly after the installed build, as an Array
; of Map("channel", Id, "tag", Tag). Releases is the release list in its order,
; an Array of Map("tag", Tag, "published_at", Time). The installed build's time
; is that of the first listed release of the same version; a build that is not
; listed (older than the list, or a source checkout), or listed without a valid
; time, predates the list.
UpdateChannels_NewerElsewhere(Releases, Selected, Installed) {
	Found := []
	if !(Releases is Array) || !UpdateChannels_IsKnown(Selected)
		return Found
	Tags := []
	for _, Release in Releases {
		Tag := (Release is Map) ? Release.Get("tag", "") : ""
		Tags.Push(Tag is String ? Tag : "")
	}
	InstalledAt := ""
	if (UpdateChannels_ForTag(Installed) != "") {
		for Index, Tag in Tags {
			if (UpdateChannels_ForTag(Tag) == "" or _Updater_CompareVersions(Tag, Installed) != 0)
				continue
			Own := Releases[Index].Get("published_at", "")
			InstalledAt := _UpdateChannels_IsPublishTime(Own) ? Own : ""
			break
		}
	}
	for _, Channel in _UpdateChannels_Registry().Order {
		Id := Channel["id"]
		if (Id == Selected)
			continue
		Index := UpdateChannels_PickLatest(Tags, Id)
		if !Index
			continue
		At := Releases[Index].Get("published_at", "")
		if !_UpdateChannels_IsPublishTime(At)
			continue
		if (InstalledAt != "" and StrCompare(At, InstalledAt, true) <= 0)
			continue
		Found.Push(Map("channel", Id, "tag", Tags[Index]))
	}
	return Found
}
