; tests/unit/test_runner_shard.ahk

; ==============================================================================
; MODULE: Test runner sharding
; DESCRIPTION:
; CI splits the canonical suite across runners with run_all.ahk --shard=K/N.
; The shards must partition the selected tests: every test runs in exactly
; one shard, in its original relative order, and invalid bounds are refused.
; ==============================================================================

#Requires AutoHotkey v2.0

_RSH_Partition() {
	Tests := []
	loop 23
		Tests.Push({name: "case " . A_Index})
	AssertTrue(_SelectShard(Tests, 0, 0) == Tests, "no shard keeps the exact selection")
	Seen := Map()
	Total := 0
	loop 6 {
		Shard := _SelectShard(Tests, A_Index, 6)
		Total += Shard.Length
		Previous := 0
		for Entry in Shard {
			AssertFalse(Seen.Has(Entry.name), "a test runs in a single shard")
			Seen[Entry.name] := A_Index
			Position := Integer(SubStr(Entry.name, 6))
			AssertTrue(Position > Previous, "a shard keeps the original relative order")
			Previous := Position
		}
	}
	AssertEqual(Tests.Length, Total, "the shards together run every selected test")
	AssertEqual(Tests.Length, Seen.Count)
	AssertEqual(4, _SelectShard(Tests, 1, 6).Length)
	AssertEqual(3, _SelectShard(Tests, 6, 6).Length)
}
Test("runner shard: the shards partition the selection in order (runner-shard)", _RSH_Partition)

_RSH_InvalidBounds() {
	Tests := [{name: "only"}]
	AssertThrows(() => _SelectShard(Tests, 0, 3))
	AssertThrows(() => _SelectShard(Tests, 4, 3))
	AssertThrows(() => _SelectShard(Tests, "1", 3))
}
Test("runner shard: invalid shard bounds are refused (runner-shard)", _RSH_InvalidBounds)
