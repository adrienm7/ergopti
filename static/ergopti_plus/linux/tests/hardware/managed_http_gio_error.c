/* tests/hardware/managed_http_gio_error.c */
/* Owned native GIO extension fixture. No transport or production override. */
#include <gio/gio.h>
#include <gmodule.h>

typedef struct _ErgoptiNativeErrorResolver { GObject parent_instance; } ErgoptiNativeErrorResolver;
typedef struct _ErgoptiNativeErrorResolverClass { GObjectClass parent_class; } ErgoptiNativeErrorResolverClass;
static void resolver_iface_init(GProxyResolverInterface *iface);
G_DEFINE_DYNAMIC_TYPE_EXTENDED(ErgoptiNativeErrorResolver, ergopti_native_error_resolver,
    G_TYPE_OBJECT, 0, G_IMPLEMENT_INTERFACE_DYNAMIC(G_TYPE_PROXY_RESOLVER, resolver_iface_init))

static gboolean is_supported(GProxyResolver *resolver) {
    (void)resolver;
    return TRUE;
}
static gchar **lookup(GProxyResolver *resolver, const gchar *uri,
                      GCancellable *cancellable, GError **error) {
    (void)resolver; (void)uri; (void)cancellable;
    /* Native private text must never escape the producer's typed refusal. */
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, "private-native-error-vector");
    return NULL;
}
static void lookup_async(GProxyResolver *resolver, const gchar *uri,
                         GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data) {
    GTask *task = g_task_new(resolver, cancellable, callback, user_data);
    (void)uri;
    g_task_return_new_error(task, G_IO_ERROR, G_IO_ERROR_FAILED, "%s", "private-native-error-vector");
    g_object_unref(task);
}
static gchar **lookup_finish(GProxyResolver *resolver, GAsyncResult *result, GError **error) {
    g_return_val_if_fail(g_task_is_valid(result, resolver), NULL);
    return g_task_propagate_pointer(G_TASK(result), error);
}
static void resolver_iface_init(GProxyResolverInterface *iface) {
    iface->is_supported = is_supported;
    iface->lookup = lookup;
    iface->lookup_async = lookup_async;
    iface->lookup_finish = lookup_finish;
}
static void ergopti_native_error_resolver_init(ErgoptiNativeErrorResolver *self) { (void)self; }
static void ergopti_native_error_resolver_class_init(ErgoptiNativeErrorResolverClass *klass) { (void)klass; }
static void ergopti_native_error_resolver_class_finalize(ErgoptiNativeErrorResolverClass *klass) { (void)klass; }

G_MODULE_EXPORT void g_io_module_load(GIOModule *module) {
    ergopti_native_error_resolver_register_type(G_TYPE_MODULE(module));
    g_io_extension_point_implement(G_PROXY_RESOLVER_EXTENSION_POINT_NAME,
        ergopti_native_error_resolver_get_type(), "ergopti-native-error", 1000);
}
G_MODULE_EXPORT void g_io_module_unload(GIOModule *module) { (void)module; }
G_MODULE_EXPORT gchar **g_io_module_query(void) {
    gchar **points = g_new0(gchar *, 2);
    points[0] = g_strdup(G_PROXY_RESOLVER_EXTENSION_POINT_NAME);
    return points;
}
