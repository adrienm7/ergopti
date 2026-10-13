// Fixed native maintenance framing; these bytes express requests, not authority.
#ifndef ERGOPTI_OWNED_RUNTIME_MAINTENANCE_WIRE_H
#define ERGOPTI_OWNED_RUNTIME_MAINTENANCE_WIRE_H

#include <stdint.h>

/* The original Core receiver owns the actual endpoint and its console-user
 * socket permissions. Every accepted stream is separately authenticated from
 * its kernel audit token, live signed image and native process incarnation. */
#define ERGOPTI_OWNED_MAINTENANCE_SOCKET "/Library/Application Support/ErgoptiPlus/.runtime-maintenance.sock"
#define ERGOPTI_OWNED_MAINTENANCE_WIRE_SIZE 64

/* Exactly 64 bytes, with no native struct layout or host-endian integers:
 * [0..7] magic "EGRMNT01" for original operations 1..7, or "EGRMNT02"
 * for the scheduling-only original-issuer intent query (operation 8);
 * [8] operation; [9] reply status (zero in a request);
 * [10..15] reserved zero;
 * [16..23] original Core cohort, unsigned big-endian;
 * [24..39] original capture incarnation as 16 UUID bytes;
 * [40..47] original preparation, unsigned big-endian;
 * [48..63] original private issuer nonce, never exposed by a Lua API.
 * Acquisition requests carry zero in every correlation field. A register
 * request may have cohort zero while Core derives the actual matching original
 * constructor; its reply supplies that exact cohort. Final parent settlement
 * and recut must retain the entire original correlated tuple. No trailing
 * bytes within a frame, unknown operation/status or nonzero reserved byte is
 * accepted. Follow-up frames remain serialized on that same retained stream;
 * all replies repeat the exact request operation and version. Version 2 admits
 * only operation 8, statuses 0..3 and a complete original correlation tuple.
 * An observed intent requests scheduling of the genuine final stop; it does
 * not grant retirement permission or acknowledge any resource settlement.
 * The original version still rejects operation 8. */
enum ergopti_owned_maintenance_wire_operation {
  ERGOPTI_MAINTENANCE_ISSUER_REGISTER = 1,
  ERGOPTI_MAINTENANCE_ISSUER_SETTLED = 2,
  ERGOPTI_MAINTENANCE_ACQUIRE = 3,
  ERGOPTI_MAINTENANCE_REQUEST_RETIREMENT = 4,
  ERGOPTI_MAINTENANCE_OBSERVE_TERMINAL = 5,
  ERGOPTI_MAINTENANCE_RECUT_TERMINAL = 6,
  ERGOPTI_MAINTENANCE_ACQUIRE_CONFIRMED_UPDATE = 7,
  ERGOPTI_MAINTENANCE_OBSERVE_RETIREMENT_INTENT = 8
};

enum ergopti_owned_maintenance_wire_status {
  ERGOPTI_MAINTENANCE_WIRE_REQUEST = 0,
  ERGOPTI_MAINTENANCE_WIRE_REFUSED = 1,
  ERGOPTI_MAINTENANCE_WIRE_PENDING = 2,
  ERGOPTI_MAINTENANCE_WIRE_OBSERVED = 3,
  ERGOPTI_MAINTENANCE_WIRE_CLOSE_REFUSED = 4
};

#endif
