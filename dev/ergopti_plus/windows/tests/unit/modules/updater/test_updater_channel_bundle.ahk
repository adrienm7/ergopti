; tests/unit/modules/updater/test_updater_channel_bundle.ahk

; ==============================================================================
; MODULE: Updater Channel-Bundle Receipts
; DESCRIPTION:
; Exact, bounded local receipts of the channel bundle: issuer shape, late
; acknowledgements, copied identities, successors and released history.
; ==============================================================================

#Requires AutoHotkey v2.0





_UpdaterTest_ChannelBundleOwnProperties(Bundle) {
	Names := Map()
	for Name, _ in Bundle.OwnProps()
		Names[Name] := true
	AssertEqual(5, Names.Count,
		"the updater must preserve the issuer's exact five own properties")
	for Name in ["kind", "id", "tokens", "authorized", "shutdown_claimed"]
		Assert(Names.Has(Name), "the issuer must retain its intrinsic " . Name . " property")
}

_UpdaterTest_ChannelBundleReceiptPreservesIssuerShape() {
	Bundle := _UpdaterTest_AcquireChannelConfigBundle()
	try {
		Receipt := _Updater_ChannelConfigBundleReceipt(Bundle, "register")
		AssertEqual(true, Receipt, "an exact live issuer bundle must register locally")
		_UpdaterTest_ChannelBundleOwnProperties(Bundle)
		Owner := {}
		AssertEqual(true, _Updater_RetainChannelConfigBundle(Bundle, Owner),
			"the exact live bundle must transfer to the updater retention owner")
		Assert(Owner.ConfigBundle == Bundle,
			"retention must lend the original issuer object without wrapping it")
		AssertEqual(true, _Updater_ChannelConfigBundleRetained(Bundle),
			"the receipt must track local retention outside the issuer")
		_UpdaterTest_ChannelBundleOwnProperties(Bundle)
		AssertEqual(true, _Updater_ReleaseChannelConfigBundle(Bundle),
			"the local release must receive the native acknowledgment")
		_UpdaterTest_ChannelBundleOwnProperties(Bundle)
	} finally _ConfigWriteTerminalRelease(Bundle)
}
Test("Updater channel bundle: retention preserves the exact five-field issuer", _UpdaterTest_ChannelBundleReceiptPreservesIssuerShape)

_UpdaterTest_ChannelBundleReceiptAcknowledgesOnlyActualRelease() {
	global ConfigurationFile
	Bundle := _UpdaterTest_AcquireChannelConfigBundle()
	try {
		AssertEqual(true, _Updater_ReleaseChannelConfigBundle(Bundle),
			"the first updater release must acknowledge the exact native release")
		AssertEqual(false, _ConfigWriteTerminalRelease(Bundle),
			"the already released native issuer must remain single-use")
		AssertEqual(true, _Updater_ReleaseChannelConfigBundle(Bundle),
			"an exact late callback may acknowledge its prior successful updater release")
		AssertEqual(false, _Updater_ChannelConfigBundleRetained(Bundle),
			"a local release receipt must not retain native ownership")
		AssertEqual(false, _Updater_RetainChannelConfigBundle(Bundle, {}),
			"local release acknowledgment must not resurrect retired authority")
		AssertEqual(false, _ConfigWriteLeaseSelectOwner(Bundle, ConfigurationFile),
			"local acknowledgment must never substitute for native selection")
	} finally _ConfigWriteTerminalRelease(Bundle)
}
Test("Updater channel bundle: late release acknowledgment never mints native authority", _UpdaterTest_ChannelBundleReceiptAcknowledgesOnlyActualRelease)

_UpdaterTest_ChannelBundleReceiptRejectsCopiedIdentity() {
	global ConfigurationFile
	Bundle := _UpdaterTest_AcquireChannelConfigBundle()
	try {
		AssertEqual(true, _Updater_ChannelConfigBundleReceipt(Bundle, "register"),
			"the genuine current bundle must register")
		Copied := Bundle.Clone()
		AssertEqual(false, _Updater_ChannelConfigBundleReceipt(Copied, "register"),
			"copied fields and shared tokens must not register another identity")
		AssertEqual(false, _Updater_RetainChannelConfigBundle(Copied, {}),
			"copied identity must not acquire local retention")
		AssertEqual(false, _Updater_ReleaseChannelConfigBundle(Copied),
			"copied identity must not call the native release for the genuine bundle")
		Assert(IsObject(_ConfigWriteLeaseSelectOwner(Bundle, ConfigurationFile)),
			"refusing a copied object must leave the genuine native owner live")
	} finally _Updater_ReleaseChannelConfigBundle(Bundle)
}
Test("Updater channel bundle: copied identity cannot affect its genuine owner", _UpdaterTest_ChannelBundleReceiptRejectsCopiedIdentity)

_UpdaterTest_ChannelBundleReceiptExpiresBeforeSuccessor() {
	global ConfigurationFile
	Predecessor := _UpdaterTest_AcquireChannelConfigBundle()
	Successor := 0
	try {
		AssertEqual(true, _Updater_ReleaseChannelConfigBundle(Predecessor),
			"the predecessor must be genuinely released before successor admission")
		Successor := _UpdaterTest_AcquireChannelConfigBundle()
		AssertEqual(true, _Updater_ChannelConfigBundleReceipt(Successor, "register"),
			"a genuinely current successor must replace the bounded receipt")
		AssertEqual(false, _Updater_ReleaseChannelConfigBundle(Predecessor),
			"expired late acknowledgment is a refusal after successor registration")
		AssertEqual(false, _Updater_RetainChannelConfigBundle(Predecessor, {}),
			"an expired predecessor must not acquire the successor's retention")
		AssertEqual(false, _Updater_ChannelConfigBundleReceipt(Predecessor),
			"the bounded sidecar must no longer retain the predecessor graph")
		Assert(IsObject(_ConfigWriteLeaseSelectOwner(Successor, ConfigurationFile)),
			"the late predecessor callback must leave successor native ownership intact")
		AssertEqual(false, _Updater_ChannelConfigBundleRetained(Successor),
			"refused predecessor activity must not retain the successor locally")
	} finally {
		if Successor is Object
			_ConfigWriteTerminalRelease(Successor)
		_ConfigWriteTerminalRelease(Predecessor)
	}
}
Test("Updater channel bundle: expired late callback cannot touch a successor", _UpdaterTest_ChannelBundleReceiptExpiresBeforeSuccessor)

_UpdaterTest_ChannelBundleReceiptKeepsFailedReleaseDebt() {
	global ConfigurationFile
	Bundle := _UpdaterTest_AcquireChannelConfigBundle()
	State := _ConfigWriteLeaseState()
	MembershipWithdrawn := false
	PreviousCritical := Critical("On")
	try {
		AssertEqual(true, _Updater_RetainChannelConfigBundle(Bundle, {}),
			"the original exact bundle must begin retained")
		; Temporarily withdraw only the public reference. The closed issuer's
		; private issued receipt cannot be retired by this withdrawal.
		State.terminal := false
		MembershipWithdrawn := true
		AssertEqual(false, _Updater_ReleaseChannelConfigBundle(Bundle),
			"missing public membership must not be labeled a successful release")
		AssertEqual(true, _Updater_ChannelConfigBundleRetained(Bundle),
			"failed release must keep the original local retention debt")
		State.terminal := Bundle
		MembershipWithdrawn := false
		AssertEqual(true, _Updater_ReleaseChannelConfigBundle(Bundle),
			"restoring original native membership must allow genuine release retry")
		AssertEqual(true, _Updater_ReleaseChannelConfigBundle(Bundle),
			"only the acknowledged retry may publish local released state")
	} finally {
		if MembershipWithdrawn && !(State.terminal is Object)
			State.terminal := Bundle
		_ConfigWriteTerminalRelease(Bundle)
		Critical(PreviousCritical)
	}
}
Test("Updater channel bundle: failed native release retains debt for exact retry", _UpdaterTest_ChannelBundleReceiptKeepsFailedReleaseDebt)

_UpdaterTest_ChannelBundleReceiptDoesNotInventExternalAcknowledgment() {
	Bundle := _UpdaterTest_AcquireChannelConfigBundle()
	Successor := 0
	try {
		AssertEqual(true, _Updater_ChannelConfigBundleReceipt(Bundle, "register"),
			"the borrowed bundle must register before its external owner finishes")
		AssertEqual(true, _ConfigWriteTerminalRelease(Bundle),
			"the delegated native owner must finish through its actual release")
		AssertEqual(false, _Updater_ReleaseChannelConfigBundle(Bundle),
			"an external release must not invent a successful updater acknowledgment")
		Successor := _UpdaterTest_AcquireChannelConfigBundle()
		AssertEqual(true, _Updater_ChannelConfigBundleReceipt(Successor, "register"),
			"genuine new admission must not deadlock on a completed delegated owner")
		AssertEqual(false, _Updater_ChannelConfigBundleReceipt(Bundle),
			"successor admission must retire the old local graph without forging its release")
	} finally {
		if Successor is Object
			_ConfigWriteTerminalRelease(Successor)
		_ConfigWriteTerminalRelease(Bundle)
	}
}
Test("Updater channel bundle: genuine successor admission replaces an externally finished owner", _UpdaterTest_ChannelBundleReceiptDoesNotInventExternalAcknowledgment)

_UpdaterTest_ChannelBundleReceiptHasFiniteHistory() {
	Previous := 0
	Loop 128 {
		Bundle := _UpdaterTest_AcquireChannelConfigBundle()
		try {
			Receipt := _Updater_ChannelConfigBundleReceipt(Bundle, "register")
			AssertEqual(true, Receipt,
				"each exact acquisition must become the only current local receipt")
			if Previous is Object {
				AssertEqual(false, _Updater_ChannelConfigBundleReceipt(Previous),
					"the previous released graph must not accumulate in receipt history")
				AssertEqual(false, _Updater_ReleaseChannelConfigBundle(Previous),
					"expired acknowledgment must remain refused during repeated channel changes")
			}
			AssertEqual(true, _Updater_ReleaseChannelConfigBundle(Bundle),
				"each current release must receive its own native acknowledgment")
			Previous := Bundle
		} finally _ConfigWriteTerminalRelease(Bundle)
	}
	Body := _DriverFuncBodyOrEmpty("_Updater_ChannelConfigBundleReceipt")
	Assert(Body != "", "the receipt implementation must be a real source subject")
	Assert(InStr(Body, "static Receipt := 0") > 0
		&& InStr(Body, "Receipt := { Bundle: Bundle, Retained: false, Released: false }") > 0,
		"the sidecar must retain a single replaceable exact-object graph")
	Assert(InStr(Body, "Map(") == 0 && InStr(Body, ".Push(") == 0,
		"the sidecar must not accumulate a process-lifetime receipt collection")
}
Test("Updater channel bundle: released history is bounded to one exact graph", _UpdaterTest_ChannelBundleReceiptHasFiniteHistory)


_UpdaterTest_ChannelBundleReceiptRefusesForeignOperationCase() {
	global ConfigurationFile
	Bundle := _UpdaterTest_AcquireChannelConfigBundle()
	try {
		AssertEqual(true, _Updater_ChannelConfigBundleReceipt(Bundle, "register"),
			"the original exact owner must register before operation-refusal checks")
		for Operation in ["INSPECT", "Inspect", "REGISTER", "Register", "RETAIN",
			"Retain", "RELEASE", "Release", "RETAINED", "Retained", "unknown", "", 0] {
			AssertEqual(false, _Updater_ChannelConfigBundleReceipt(Bundle, Operation),
				"only the exact lower-case internal operation vocabulary may be admitted")
			Assert(IsObject(_ConfigWriteLeaseSelectOwner(Bundle, ConfigurationFile)),
				"a refused operation must not fall through to native release")
			AssertEqual(false, _Updater_ChannelConfigBundleRetained(Bundle),
				"a refused operation must not change the exact owner's retention")
		}
	} finally _Updater_ReleaseChannelConfigBundle(Bundle)
}
Test("Updater channel bundle: foreign operation case cannot fall through to release", _UpdaterTest_ChannelBundleReceiptRefusesForeignOperationCase)

; A later future-schema edit remains refused before the preference writer. The
; fixture creates valid admission first rather than borrowing a missing source.
_UpdaterTest_CurrentFixtureRetainsFutureSchemaRefusal() {
	global ConfigurationFile, UPDATER_REQUEST_ORIGIN_MANUAL
	SavedPath := ConfigurationFile
	Writes := 0
	Body() {
		Assert(ConfigSchemaCanPrepareWrite(ConfigurationFile))
		Source := FSReadUtf8Exact(ConfigurationFile)
		Future := RegExReplace(Source, "m)^_meta\.schema_version = [0-9]+$", "_meta.schema_version = 999", &Changed, 1)
		AssertEqual(1, Changed)
		Assert(FSWriteDurable(ConfigurationFile, Future))
		Writer(Args*) {
			Writes += 1
			return true
		}
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		AssertEqual(false, Updater_SetCheckInterval(120, Request, false, (*) => 0, Writer, (*) => true))
		AssertEqual(0, Writes, "the real future-schema fence precedes the injected writer")
		AssertTrue(FSUtf8ExactMatches(ConfigurationFile, Future))
	}
	_UpdaterTest_WithCurrentConfiguration(Body)
	AssertEqual(SavedPath, ConfigurationFile, "the selected configuration is restored after the guard control")
}
Test("Updater current-source fixture: future schema remains refused before preference effects", _UpdaterTest_CurrentFixtureRetainsFutureSchemaRefusal)
