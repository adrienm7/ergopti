// tools/diagnostics/native_appleevent_probe_protocol.h
// Shared private nonce event; never an application lifecycle command.

#ifndef ERGOPTI_NATIVE_APPLEEVENT_PROBE_PROTOCOL_H
#define ERGOPTI_NATIVE_APPLEEVENT_PROBE_PROTOCOL_H

// Numeric FourCC constants avoid implementation-defined multicharacter literals.
#define ERGOPTI_PROBE_EVENT_CLASS ((AEEventClass)0x45675062u) /* EgPb */
#define ERGOPTI_PROBE_EVENT_ID ((AEEventID)0x6e6f6e63u) /* nonc */
#define ERGOPTI_PROBE_NONCE_PARAMETER ((AEKeyword)0x45674e63u) /* EgNc */

#endif
