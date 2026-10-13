// static/ergopti_plus/windows/native/nav_event_owner/replay_route_core.h
/**
 * @file replay_route_core.h
 * @brief Portable event-time route snapshots for a supplied Windows KLE subset.
 *
 * This core owns routing metadata, not a hook, keyboard injection or a FIFO.
 * The native navigation owner retains capture order and SendInput acknowledgements.
 * The native owner attaches these immutable snapshots to its capture FIFO.
 * An AHK adapter supplies a bounded KLE registration subset; transformed replay
 * stays disabled until its handler and observer cohorts are completely owned.
 */

#ifndef ERGOPTI_REPLAY_ROUTE_CORE_H
#define ERGOPTI_REPLAY_ROUTE_CORE_H

#include <stddef.h>
#include <stdint.h>

/* Bounded representative registrations; this is not a complete KLE table. */
#define ERGOPTI_REPLAY_MAX_ROUTES 128u
#define ERGOPTI_REPLAY_MAX_HELD_KEYS 64u
#define ERGOPTI_REPLAY_STATE_INIT {0}

/** Rejection never changes state; unsupported and absent recipes stay explicit. */
enum ErgoptiReplay_Status {
	ERGOPTI_REPLAY_OK = 0,
	ERGOPTI_REPLAY_UNREGISTERED = 1,
	ERGOPTI_REPLAY_UNSUPPORTED = 2,
	ERGOPTI_REPLAY_INVALID_ARGUMENT = -1,
	ERGOPTI_REPLAY_NOT_INITIALIZED = -2,
	ERGOPTI_REPLAY_ALREADY_INITIALIZED = -3,
	ERGOPTI_REPLAY_OWNER_MISMATCH = -4,
	ERGOPTI_REPLAY_INVALID_REGISTRATION = -5,
	ERGOPTI_REPLAY_STALE_REGISTRATION = -6,
	ERGOPTI_REPLAY_INVALID_EVENT = -7,
	ERGOPTI_REPLAY_STALE_EVENT = -8,
	ERGOPTI_REPLAY_CAPACITY = -9,
	ERGOPTI_REPLAY_ORPHAN_EDGE = -10
};

enum ErgoptiReplay_Origin {
	ERGOPTI_REPLAY_PHYSICAL = 1,
	ERGOPTI_REPLAY_OWNED_REPLAY = 2,
	ERGOPTI_REPLAY_EXTERNAL_INJECTION = 3,
	ERGOPTI_REPLAY_LOWER_INTEGRITY = 4
};

enum ErgoptiReplay_Axis {
	ERGOPTI_REPLAY_VK = 1,
	ERGOPTI_REPLAY_SCAN = 2
};

enum ErgoptiReplay_Kind {
	ERGOPTI_REPLAY_CHARACTER = 1,
	ERGOPTI_REPLAY_DIGIT = 2,
	ERGOPTI_REPLAY_DEAD_KEY = 3,
	ERGOPTI_REPLAY_MODIFIER = 4,
	ERGOPTI_REPLAY_PREFIX = 5
};

enum ErgoptiReplay_ModifierLR {
	ERGOPTI_REPLAY_LCONTROL = 0x01,
	ERGOPTI_REPLAY_RCONTROL = 0x02,
	ERGOPTI_REPLAY_LALT = 0x04,
	ERGOPTI_REPLAY_RALT = 0x08,
	ERGOPTI_REPLAY_LSHIFT = 0x10,
	ERGOPTI_REPLAY_RSHIFT = 0x20,
	ERGOPTI_REPLAY_LWIN = 0x40,
	ERGOPTI_REPLAY_RWIN = 0x80
};

enum ErgoptiReplay_Modifier {
	ERGOPTI_REPLAY_CONTROL = 1,
	ERGOPTI_REPLAY_ALT = 2,
	ERGOPTI_REPLAY_SHIFT = 4,
	ERGOPTI_REPLAY_WIN = 8
};

/**
 * One authoritative mapping supplied by the KLE registration adapter.
 *
 * A scan-code family owns its input before a VK family, including its absent
 * modifier/prefix combinations. Character/digit/dead-key routes require an
 * exact generic modifier, prefix and supplied composition-state identity. Modifier/prefix mappings match their
 * input at every chord and retain their transform until the exact source up.
 * Dead-key transitions are supplied finite states, never derived character
 * composition. recipe_id retains the caller-owned KLE model/step recipe. The
 * AHK Keylayout_Step owner resolves complex next-state/output from that model.
 * Targets describe native edges, never guessed characters or composed glyphs.
 */
typedef struct ErgoptiReplay_Route {
	uint64_t recipe_id;
	uint32_t route_id;
	uint32_t required_prefixes;
	uint32_t prefix_bit;
	uint32_t required_dead_key_id;
	uint32_t next_dead_key_id;
	uint16_t code;
	uint16_t target_vk;
	uint16_t target_scan;
	uint8_t axis;
	uint8_t kind;
	uint8_t required_modifiers;
	uint8_t effective_modifiers_lr;
} ErgoptiReplay_Route;

/** Exact source provenance separates physical and replay holds of the same key. */
typedef struct ErgoptiReplay_Event {
	uint64_t timestamp;
	uint64_t source_id;
	uint16_t vk;
	uint16_t scan;
	uint8_t origin;
	uint8_t key_up;
	uint8_t repeat;
} ErgoptiReplay_Event;

/** Pending dead-key metadata survives queueing without predicting OS glyphs. */
typedef struct ErgoptiReplay_Composition {
	uint64_t generation;
	uint64_t layout_id;
	uint32_t dead_key_id;
} ErgoptiReplay_Composition;

/** Immutable event-time metadata copied into the existing native capture FIFO. */
typedef struct ErgoptiReplay_Snapshot {
	uint64_t owner;
	uint64_t observed_generation;
	uint64_t observed_layout_id;
	uint64_t route_generation;
	uint64_t route_layout_id;
	uint32_t prefixes_before;
	uint32_t prefixes_after;
	int32_t status;
	uint8_t modifiers_lr_before;
	uint8_t modifiers_lr_after;
	ErgoptiReplay_Composition composition_before;
	ErgoptiReplay_Composition composition_after;
	ErgoptiReplay_Event event;
	ErgoptiReplay_Route route;
} ErgoptiReplay_Snapshot;

/** A replay recipe contains one key edge, with the original edge kind retained. */
typedef struct ErgoptiReplay_NativeKeyEdge {
	uint16_t vk;
	uint16_t scan;
	uint8_t key_up;
	uint8_t repeat;
} ErgoptiReplay_NativeKeyEdge;

/** Internal hold storage is public only to permit allocation without a runtime. */
typedef struct ErgoptiReplay_Hold {
	uint64_t source_id;
	uint64_t generation;
	uint64_t layout_id;
	int32_t status;
	uint16_t vk;
	uint16_t scan;
	uint8_t origin;
	uint8_t active;
	ErgoptiReplay_Route route;
} ErgoptiReplay_Hold;

/**
 * Single-owner state. The calling adapter must serialize its hook callbacks.
 * Initialize a fresh object with ERGOPTI_REPLAY_STATE_INIT; copying live state
 * does not transfer initialization or lifecycle ownership.
 */
typedef struct ErgoptiReplay_State {
	uint64_t owner;
	uint64_t generation;
	uint64_t layout_id;
	uint64_t last_timestamp;
	uint32_t route_count;
	uint8_t initialized;
	uint8_t has_timestamp;
	ErgoptiReplay_Composition composition;
	ErgoptiReplay_Route routes[ERGOPTI_REPLAY_MAX_ROUTES];
	ErgoptiReplay_Hold holds[ERGOPTI_REPLAY_MAX_HELD_KEYS];
} ErgoptiReplay_State;

/* Pin the x64 registration/snapshot ABI before an AHK adapter marshals it. */
#if UINTPTR_MAX == UINT64_MAX
_Static_assert(sizeof(ErgoptiReplay_Route) == 40, "Replay route x64 ABI changed.");
_Static_assert(offsetof(ErgoptiReplay_Route, recipe_id) == 0, "Replay recipe offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Route, route_id) == 8, "Replay route ID offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Route, required_prefixes) == 12, "Replay prefix selector offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Route, prefix_bit) == 16, "Replay prefix transform offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Route, required_dead_key_id) == 20, "Replay composition selector offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Route, next_dead_key_id) == 24, "Replay composition transition offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Route, code) == 28, "Replay input code offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Route, target_vk) == 30, "Replay output VK offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Route, target_scan) == 32, "Replay output scan offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Route, axis) == 34, "Replay input axis offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Route, kind) == 35, "Replay route kind offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Route, required_modifiers) == 36, "Replay modifier selector offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Route, effective_modifiers_lr) == 37, "Replay modifier transform offset changed.");
_Static_assert(sizeof(ErgoptiReplay_Event) == 24, "Replay event x64 ABI changed.");
_Static_assert(offsetof(ErgoptiReplay_Event, timestamp) == 0, "Replay timestamp offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Event, source_id) == 8, "Replay source offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Event, vk) == 16, "Replay event VK offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Event, scan) == 18, "Replay event scan offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Event, origin) == 20, "Replay origin offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Event, key_up) == 21, "Replay event edge offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Event, repeat) == 22, "Replay repeat offset changed.");
_Static_assert(sizeof(ErgoptiReplay_Composition) == 24, "Replay composition x64 ABI changed.");
_Static_assert(sizeof(ErgoptiReplay_Snapshot) == 168, "Replay snapshot x64 ABI changed.");
_Static_assert(offsetof(ErgoptiReplay_Snapshot, owner) == 0, "Replay snapshot owner offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Snapshot, observed_generation) == 8, "Replay observed generation offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Snapshot, observed_layout_id) == 16, "Replay observed layout offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Snapshot, route_generation) == 24, "Replay captured generation offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Snapshot, route_layout_id) == 32, "Replay captured layout offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Snapshot, prefixes_before) == 40, "Replay prefix-before offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Snapshot, prefixes_after) == 44, "Replay prefix-after offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Snapshot, status) == 48, "Replay status offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Snapshot, modifiers_lr_before) == 52, "Replay modifiers-before offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Snapshot, modifiers_lr_after) == 53, "Replay modifiers-after offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Snapshot, composition_before) == 56, "Replay composition-before offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Snapshot, composition_after) == 80, "Replay composition-after offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Snapshot, event) == 104, "Replay captured event offset changed.");
_Static_assert(offsetof(ErgoptiReplay_Snapshot, route) == 128, "Replay captured route offset changed.");
#endif

/** Initializes once with a nonzero owner; duplicate initialization is rejected. */
int32_t ErgoptiReplay_Initialize(ErgoptiReplay_State *state, uint64_t owner);

/**
 * Atomically publishes a fully validated authoritative registration set.
 * Generation must increase; layout identity must be nonzero. Zero routes
 * explicitly withdraw registrations. Existing holds retain their old recipe.
 */
int32_t ErgoptiReplay_Register(
	ErgoptiReplay_State *state, uint64_t owner, uint64_t generation,
	uint64_t layout_id, const ErgoptiReplay_Route *routes, uint32_t count);

/**
 * Advances event-time state and copies a replayable snapshot.
 * Only physical and owned replay origins are supported. Unknown keys remain
 * explicitly unregistered, with exact up/repeat identity retained. A dead-key
 * sequence cannot cross layout identities without a separate native adapter.
 * Repeats retain the held recipe. A changed composition requiring another
 * recipe returns UNSUPPORTED until the captured KLE model adapter resolves it.
 * Native modifier/prefix keys must be explicitly registered by that adapter.
 * The event may overlap the snapshot output; it is copied before output clearing.
 * A snapshot output overlapping any state bytes, or whose address span wraps,
 * returns INVALID_ARGUMENT before any write, including a refusal status write.
 */
int32_t ErgoptiReplay_Step(
	ErgoptiReplay_State *state, uint64_t owner,
	const ErgoptiReplay_Event *event, ErgoptiReplay_Snapshot *snapshot);

/**
 * Copies the captured native recipe without consulting the current route table.
 * Unsupported/unregistered snapshots never authorize a guessed output edge.
 * This prepares output only; the native FIFO remains responsible for delivery
 * and acknowledgements, and no OS output is emitted here.
 * An edge output overlapping any state or supplied snapshot bytes, or whose
 * address span wraps, returns INVALID_ARGUMENT without writing either buffer.
 * Other refusals retain the ordinary zeroed output behavior.
 */
int32_t ErgoptiReplay_PrepareNativeEdge(
	const ErgoptiReplay_State *state, uint64_t owner,
	const ErgoptiReplay_Snapshot *snapshot, ErgoptiReplay_NativeKeyEdge *edge);

#endif
