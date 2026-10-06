<!-- docs/handovers/2026-10-04-parallel-containers/group3-config-surface-recovery/README.md -->

# Bounded recovery-transport recognition

The reviewed [validator-only patch](validator-only.patch) recognizes the actual
Group 2 secondary writer only when its imports, constructor, exact destination,
source, row offset, callback and forward/inverse helper transport establish the
existing declared configuration owner. [Metadata](metadata.json) pins sources
and pre/postimages. Existing direct-writer and Group 3 program-parameter
recognition remain; there is no broad secondary-writer exemption.

Bounded source controls passed 81 cases, including 24 consumer and 21 helper
mutations. The original validator rejected the new recovery chain. Current
sources and the actual-snippet future composite each retained the three declared
baseline exceptions. Every mutation asserted that source bytes changed.
The published helper was independently hash-verified; the consumer fixture
combines actual published snippets and does not claim verification of the
complete consumer file. Independently review the integrating owner's actual
source and run the full JS gate. This source gate does not qualify native
publication, packaging or installation.
