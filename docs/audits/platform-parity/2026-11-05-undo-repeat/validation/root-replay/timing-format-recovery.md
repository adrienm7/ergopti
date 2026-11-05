# Timing formatting-log custody

The first root comparison found that `timing-followup/shared/handoff.json` named a missing `format.txt`. The original worker scratch file was present and verified as 170 bytes with SHA-256 `f7082eb69f9e9f63a0066097903f54a9b1c5d93c2463e71c586093ac141829c9`, exactly matching the unchanged worker claim.

The verified bytes were retained as `timing-shared-submitted-format.txt` here and then restored, without formatting, to the claimed relative path `timing-followup/shared/format.txt`. The custody comparison retains its initial missing state and records the restoration. All fourteen inspected timing handoff artifact hashes now match. This formatting log is artifact provenance, not a driver execution or native receiving receipt.
