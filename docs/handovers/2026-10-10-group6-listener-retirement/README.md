<!-- docs/handovers/2026-10-10-group6-listener-retirement/README.md -->

# Expired listener event retirement correction

The original managed serve control intermittently refused `retire(5)` after
startup expiry. ACTIVE and LISTENER_BOUND are separate guardian frames: the
second frame can still be queued when cancellation drains it. Calling startup
progress from that parser turned an expired admission clock into permanent
protocol debt even after genuine EOF, guardian exit and RETIRED receipts.

The matching event is consumed once. Only the original unexpired startup clock
can grant listener readiness. Wrong nonces, duplicate events, inactive owners,
retirement-started states and existing debt remain refused; settlement joins
and deadlines are unchanged. No retry, clock renewal or API admission is added.

Original34 suspended tests pass. Candidate39 suspended and45 serve tests pass.
The five added parser methods on the predecessor produce one failure record
and four error records, including subtests; those records are not method counts.
The new deterministic real-child serve case fails on the predecessor at the
physical retirement assertion, before any new-field assertion. All four
single-defect mutations are rejected. All78 original test bodies are unchanged.

These Linux portable controls use harmless real POSIX children. They do not
qualify Darwin executable identity, Mach-O retention or the native listener.
Selected repository gates and exact-source macOS CI are pending. TODO62 and
the original package, installation, network and device requirements stay open.

Source-only independent reviews precede actual receiving. Receipts are retained
in `/workspace/scratch/group6-listener-retirement-portable-20261010/`, including
the nine command records and physical session54586 completion with status0.
The frozen packet and reviews are retained under the matching suspended-listener
retirement audit and independent-review directories. No release was produced.
