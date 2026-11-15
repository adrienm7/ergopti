/* tests/hardware/desktop/foreign_toplevel_probe.c
 *
 * A private wlr-foreign-toplevel-management client standing in for lswt 2.x,
 * which Ubuntu 24.04 does not package. `-j` prints the listing in lswt 2.x's
 * JSON shape (toplevels with title, app-id, activated; supported-data), built
 * from the compositor's own protocol events, so the activated flag is the
 * compositor's answer and only the JSON writer is ours. `activate <app-id>`
 * asks the compositor to focus that toplevel. Never a production component.
 *
 * The interfaces are declared by hand from the protocol's published message
 * order (version 3), so no protocol XML or generated code is needed.
 */
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

#define MAX_TOPLEVELS 64
#define STATE_ACTIVATED 2

static const struct wl_interface handle_interface;

/* Request and event tables in protocol order: the opcode is the index. */
static const struct wl_interface *no_types[] = { NULL, NULL, NULL, NULL, NULL };
static const struct wl_interface *new_handle_types[] = { &handle_interface };
static const struct wl_message manager_requests[] = { { "stop", "", no_types } };
static const struct wl_message manager_events[] = {
	{ "toplevel", "n", new_handle_types }, { "finished", "", no_types } };
static const struct wl_interface manager_interface = {
	"zwlr_foreign_toplevel_manager_v1", 3, 1, manager_requests, 2, manager_events };
static const struct wl_message handle_requests[] = {
	{ "set_maximized", "", no_types }, { "unset_maximized", "", no_types },
	{ "set_minimized", "", no_types }, { "unset_minimized", "", no_types },
	{ "activate", "o", no_types }, { "close", "", no_types },
	{ "set_rectangle", "oiiii", no_types }, { "destroy", "", no_types },
	{ "set_fullscreen", "2?o", no_types }, { "unset_fullscreen", "2", no_types } };
static const struct wl_message handle_events[] = {
	{ "title", "s", no_types }, { "app_id", "s", no_types },
	{ "output_enter", "o", no_types }, { "output_leave", "o", no_types },
	{ "state", "a", no_types }, { "done", "", no_types },
	{ "closed", "", no_types }, { "parent", "3?o", no_types } };
static const struct wl_interface handle_interface = {
	"zwlr_foreign_toplevel_handle_v1", 3, 10, handle_requests, 8, handle_events };

struct toplevel {
	struct wl_proxy *handle;
	char *title;
	char *app_id;
	int activated;
	int closed;
};

static struct wl_proxy *manager;
static struct wl_seat *seat;
static struct toplevel toplevels[MAX_TOPLEVELS];
static int toplevel_count;

static void replace_text(char **slot, const char *value) {
	free(*slot);
	*slot = strdup(value ? value : "");
}

static void on_title(void *data, struct wl_proxy *proxy, const char *title) {
	(void)proxy;
	replace_text(&((struct toplevel *)data)->title, title);
}

static void on_app_id(void *data, struct wl_proxy *proxy, const char *app_id) {
	(void)proxy;
	replace_text(&((struct toplevel *)data)->app_id, app_id);
}

static void on_output(void *data, struct wl_proxy *proxy, struct wl_proxy *output) {
	(void)data; (void)proxy; (void)output;
}

static void on_state(void *data, struct wl_proxy *proxy, struct wl_array *states) {
	struct toplevel *toplevel = data;
	uint32_t *state;
	(void)proxy;
	toplevel->activated = 0;
	wl_array_for_each(state, states) {
		if (*state == STATE_ACTIVATED) toplevel->activated = 1;
	}
}

static void on_done(void *data, struct wl_proxy *proxy) { (void)data; (void)proxy; }

static void on_closed(void *data, struct wl_proxy *proxy) {
	(void)proxy;
	((struct toplevel *)data)->closed = 1;
}

static void on_parent(void *data, struct wl_proxy *proxy, struct wl_proxy *parent) {
	(void)data; (void)proxy; (void)parent;
}

static const struct {
	void (*title)(void *, struct wl_proxy *, const char *);
	void (*app_id)(void *, struct wl_proxy *, const char *);
	void (*output_enter)(void *, struct wl_proxy *, struct wl_proxy *);
	void (*output_leave)(void *, struct wl_proxy *, struct wl_proxy *);
	void (*state)(void *, struct wl_proxy *, struct wl_array *);
	void (*done)(void *, struct wl_proxy *);
	void (*closed)(void *, struct wl_proxy *);
	void (*parent)(void *, struct wl_proxy *, struct wl_proxy *);
} handle_listener = { on_title, on_app_id, on_output, on_output, on_state, on_done, on_closed, on_parent };

static void on_toplevel(void *data, struct wl_proxy *proxy, struct wl_proxy *handle) {
	struct toplevel *toplevel;
	(void)data; (void)proxy;
	if (toplevel_count == MAX_TOPLEVELS) {
		fprintf(stderr, "foreign_toplevel_probe: more than %d toplevels\n", MAX_TOPLEVELS);
		exit(3);
	}
	toplevel = &toplevels[toplevel_count++];
	memset(toplevel, 0, sizeof(*toplevel));
	toplevel->handle = handle;
	toplevel->title = strdup("");
	toplevel->app_id = strdup("");
	wl_proxy_add_listener(handle, (void (**)(void))&handle_listener, toplevel);
}

static void on_finished(void *data, struct wl_proxy *proxy) { (void)data; (void)proxy; }

static const struct {
	void (*toplevel)(void *, struct wl_proxy *, struct wl_proxy *);
	void (*finished)(void *, struct wl_proxy *);
} manager_listener = { on_toplevel, on_finished };

static void on_global(void *data, struct wl_registry *registry, uint32_t name,
		const char *interface, uint32_t version) {
	(void)data;
	if (strcmp(interface, manager_interface.name) == 0) {
		manager = wl_registry_bind(registry, name, &manager_interface, version < 3 ? version : 3);
		wl_proxy_add_listener(manager, (void (**)(void))&manager_listener, NULL);
	} else if (strcmp(interface, "wl_seat") == 0 && seat == NULL) {
		seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
	}
}

static void on_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
	(void)data; (void)registry; (void)name;
}

static const struct wl_registry_listener registry_listener = { on_global, on_global_remove };

static void print_json_string(const char *text) {
	const unsigned char *cursor = (const unsigned char *)text;
	putchar('"');
	for (; *cursor; cursor++) {
		if (*cursor == '"' || *cursor == '\\') printf("\\%c", *cursor);
		else if (*cursor < 0x20) printf("\\u%04x", *cursor);
		else putchar(*cursor);
	}
	putchar('"');
}

static void print_listing(void) {
	int index, first = 1;
	printf("{\"supported-data\":{\"title\":true,\"app-id\":true,\"identifier\":false,"
		"\"activated\":true},\"toplevels\":[");
	for (index = 0; index < toplevel_count; index++) {
		if (toplevels[index].closed) continue;
		if (!first) putchar(',');
		first = 0;
		printf("{\"title\":");
		print_json_string(toplevels[index].title);
		printf(",\"app-id\":");
		print_json_string(toplevels[index].app_id);
		printf(",\"activated\":%s}", toplevels[index].activated ? "true" : "false");
	}
	printf("]}\n");
}

int main(int argc, char **argv) {
	struct wl_display *display;
	struct wl_registry *registry;
	int index;
	if (argc < 2 || (strcmp(argv[1], "-j") != 0 && !(strcmp(argv[1], "activate") == 0 && argc == 3))) {
		fprintf(stderr, "usage: foreign_toplevel_probe -j | activate <app-id>\n");
		return 2;
	}
	display = wl_display_connect(NULL);
	if (display == NULL) {
		fprintf(stderr, "foreign_toplevel_probe: no Wayland display\n");
		return 1;
	}
	registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &registry_listener, NULL);
	wl_display_roundtrip(display);
	if (manager == NULL) {
		fprintf(stderr, "foreign_toplevel_probe: the compositor has no %s\n", manager_interface.name);
		return 1;
	}
	/* One round trip announces the handles, the next delivers their state. */
	wl_display_roundtrip(display);
	wl_display_roundtrip(display);
	if (strcmp(argv[1], "-j") == 0) {
		print_listing();
		wl_display_disconnect(display);
		return 0;
	}
	for (index = 0; index < toplevel_count; index++) {
		if (!toplevels[index].closed && strcmp(toplevels[index].app_id, argv[2]) == 0) {
			if (seat == NULL) {
				fprintf(stderr, "foreign_toplevel_probe: the compositor has no seat\n");
				return 1;
			}
			wl_proxy_marshal(toplevels[index].handle, 4, seat);
			wl_display_roundtrip(display);
			wl_display_disconnect(display);
			return 0;
		}
	}
	fprintf(stderr, "foreign_toplevel_probe: no toplevel with app-id %s\n", argv[2]);
	return 1;
}
