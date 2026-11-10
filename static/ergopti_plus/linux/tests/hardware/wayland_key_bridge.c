/* tests/hardware/wayland_key_bridge.c
 *
 * A Wayland keyboard for the container proofs. It stands where the kernel
 * and libinput stand on a real desktop: it reads the key frames the daemon's
 * virtual keyboard wrote (evdev code, value) on stdin and hands them to the
 * compositor as a seat keyboard does, with the real XKB keymap and the
 * modifier state libxkbcommon derives from those codes. One keyboard lives
 * for the whole run: a keyboard created per keystroke (wtype) loses its first
 * key and its modifiers on sway headless.
 *
 * Input lines: "K <code> <value>" sends one key (value 0 release, 1 press,
 * 2 repeat, ignored as the compositor repeats itself); "S" waits for the
 * compositor to process everything sent and prints "S" on stdout.
 * The keymap comes from XKB_DEFAULT_LAYOUT (default "us").
 * Exit 0 at end of input, 2 when no compositor or protocol is available.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include "virtual-keyboard-unstable-v1-client-protocol.h"

static struct wl_seat *seat;
static struct zwp_virtual_keyboard_manager_v1 *manager;

static void on_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface,
                      uint32_t version) {
    (void)data;
    (void)version;
    if (strcmp(interface, wl_seat_interface.name) == 0 && seat == NULL) {
        seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
    } else if (strcmp(interface, zwp_virtual_keyboard_manager_v1_interface.name) == 0) {
        manager = wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
    }
}

static void on_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {on_global, on_global_remove};

static uint32_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

int main(void) {
    struct wl_display *display = wl_display_connect(NULL);
    if (display == NULL) {
        fprintf(stderr, "ENVIRONMENT: no Wayland compositor\n");
        return 2;
    }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);
    if (seat == NULL || manager == NULL) {
        fprintf(stderr, "ENVIRONMENT: the compositor offers no seat or no virtual keyboard\n");
        return 2;
    }
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    const char *layout = getenv("XKB_DEFAULT_LAYOUT");
    struct xkb_rule_names names = {NULL, NULL, layout && *layout ? layout : "us", NULL, NULL};
    struct xkb_keymap *keymap = context ? xkb_keymap_new_from_names(context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS)
                                        : NULL;
    if (keymap == NULL) {
        fprintf(stderr, "ENVIRONMENT: no XKB keymap for layout %s\n", names.layout);
        return 2;
    }
    struct xkb_state *state = xkb_state_new(keymap);
    char *text = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
    size_t size = strlen(text) + 1;
    int fd = memfd_create("ergopti-keymap", MFD_CLOEXEC);
    if (fd < 0 || write(fd, text, size) != (ssize_t)size) {
        fprintf(stderr, "ENVIRONMENT: the keymap could not be shared\n");
        return 2;
    }
    struct zwp_virtual_keyboard_v1 *keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(manager, seat);
    zwp_virtual_keyboard_v1_keymap(keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t)size);
    wl_display_roundtrip(display);

    char line[64];
    while (fgets(line, sizeof line, stdin) != NULL) {
        unsigned int code = 0;
        int value = 0;
        if (line[0] == 'S') {
            wl_display_roundtrip(display);
            printf("S\n");
            fflush(stdout);
            continue;
        }
        if (sscanf(line, "K %u %d", &code, &value) != 2) {
            fprintf(stderr, "FAIL unreadable bridge line: %s", line);
            return 1;
        }
        if (value == 2) continue;
        xkb_state_update_key(state, code + 8, value ? XKB_KEY_DOWN : XKB_KEY_UP);
        zwp_virtual_keyboard_v1_key(keyboard, now_ms(), code,
                                    value ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED);
        zwp_virtual_keyboard_v1_modifiers(keyboard, xkb_state_serialize_mods(state, XKB_STATE_MODS_DEPRESSED),
                                          xkb_state_serialize_mods(state, XKB_STATE_MODS_LATCHED),
                                          xkb_state_serialize_mods(state, XKB_STATE_MODS_LOCKED),
                                          xkb_state_serialize_layout(state, XKB_STATE_LAYOUT_EFFECTIVE));
        wl_display_flush(display);
    }
    wl_display_roundtrip(display);
    zwp_virtual_keyboard_v1_destroy(keyboard);
    wl_display_roundtrip(display);
    wl_display_disconnect(display);
    return 0;
}
