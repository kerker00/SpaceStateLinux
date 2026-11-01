#include "status_notifier.h"

#include <gio/gio.h>
#include <unistd.h>

#define ITEM_PATH "/StatusNotifierItem"
#define MENU_PATH "/MenuBar"
#define WATCHER_NAME "org.kde.StatusNotifierWatcher"
#define WATCHER_PATH "/StatusNotifierWatcher"

static const char item_xml[] =
    "<node>"
    " <interface name='org.kde.StatusNotifierItem'>"
    "  <property name='Category' type='s' access='read'/>"
    "  <property name='Id' type='s' access='read'/>"
    "  <property name='Title' type='s' access='read'/>"
    "  <property name='Status' type='s' access='read'/>"
    "  <property name='WindowId' type='i' access='read'/>"
    "  <property name='IconName' type='s' access='read'/>"
    "  <property name='IconThemePath' type='s' access='read'/>"
    "  <property name='IconPixmap' type='a(iiay)' access='read'/>"
    "  <property name='OverlayIconName' type='s' access='read'/>"
    "  <property name='AttentionIconName' type='s' access='read'/>"
    "  <property name='ToolTip' type='(sa(iiay)ss)' access='read'/>"
    "  <property name='ItemIsMenu' type='b' access='read'/>"
    "  <property name='Menu' type='o' access='read'/>"
    "  <method name='ContextMenu'><arg name='x' type='i' direction='in'/><arg name='y' type='i' direction='in'/></method>"
    "  <method name='Activate'><arg name='x' type='i' direction='in'/><arg name='y' type='i' direction='in'/></method>"
    "  <method name='SecondaryActivate'><arg name='x' type='i' direction='in'/><arg name='y' type='i' direction='in'/></method>"
    "  <method name='Scroll'><arg name='delta' type='i' direction='in'/><arg name='orientation' type='s' direction='in'/></method>"
    "  <signal name='NewTitle'/>"
    "  <signal name='NewIcon'/>"
    "  <signal name='NewToolTip'/>"
    "  <signal name='NewStatus'><arg name='status' type='s'/></signal>"
    " </interface>"
    "</node>";

static const char menu_xml[] =
    "<node>"
    " <interface name='com.canonical.dbusmenu'>"
    "  <property name='Version' type='u' access='read'/>"
    "  <property name='TextDirection' type='s' access='read'/>"
    "  <property name='Status' type='s' access='read'/>"
    "  <property name='IconThemePath' type='as' access='read'/>"
    "  <method name='GetLayout'>"
    "   <arg name='parentId' type='i' direction='in'/><arg name='recursionDepth' type='i' direction='in'/>"
    "   <arg name='propertyNames' type='as' direction='in'/>"
    "   <arg name='revision' type='u' direction='out'/><arg name='layout' type='(ia{sv}av)' direction='out'/>"
    "  </method>"
    "  <method name='GetGroupProperties'>"
    "   <arg name='ids' type='ai' direction='in'/><arg name='propertyNames' type='as' direction='in'/>"
    "   <arg name='properties' type='a(ia{sv})' direction='out'/>"
    "  </method>"
    "  <method name='GetProperty'>"
    "   <arg name='id' type='i' direction='in'/><arg name='name' type='s' direction='in'/>"
    "   <arg name='value' type='v' direction='out'/>"
    "  </method>"
    "  <method name='Event'>"
    "   <arg name='id' type='i' direction='in'/><arg name='eventId' type='s' direction='in'/>"
    "   <arg name='data' type='v' direction='in'/><arg name='timestamp' type='u' direction='in'/>"
    "  </method>"
    "  <method name='EventGroup'>"
    "   <arg name='events' type='a(isvu)' direction='in'/><arg name='idErrors' type='ai' direction='out'/>"
    "  </method>"
    "  <method name='AboutToShow'>"
    "   <arg name='id' type='i' direction='in'/><arg name='needUpdate' type='b' direction='out'/>"
    "  </method>"
    "  <method name='AboutToShowGroup'>"
    "   <arg name='ids' type='ai' direction='in'/>"
    "   <arg name='updatesNeeded' type='ai' direction='out'/><arg name='idErrors' type='ai' direction='out'/>"
    "  </method>"
    "  <signal name='ItemsPropertiesUpdated'>"
    "   <arg name='updatedProps' type='a(ia{sv})'/><arg name='removedProps' type='a(ias)'/>"
    "  </signal>"
    "  <signal name='LayoutUpdated'><arg name='revision' type='u'/><arg name='parent' type='i'/></signal>"
    " </interface>"
    "</node>";

typedef struct {
    int id;
    char *label;
    bool enabled;
} MenuEntry;

struct SnItem {
    GDBusConnection *connection;
    GDBusNodeInfo *item_info;
    GDBusNodeInfo *menu_info;
    guint item_registration;
    guint menu_registration;
    guint name_owner;
    guint watcher_watch;
    bool has_watcher;
    char *bus_name;
    char *id;
    char *title;
    char *icon_name;
    char *tooltip;
    char *icon_theme_path;
    MenuEntry *menu;
    int menu_count;
    guint revision;
    SnActivateCallback activate;
    SnMenuCallback menu_clicked;
    void *user_data;
};

static void emit(SnItem *item, const char *path, const char *interface, const char *signal, GVariant *args) {
    g_dbus_connection_emit_signal(item->connection, NULL, path, interface, signal, args, NULL);
}

/* ---- StatusNotifierItem ---- */

static GVariant *item_get_property(GDBusConnection *connection, const char *sender, const char *path,
                                   const char *interface, const char *name, GError **error, gpointer data) {
    SnItem *item = data;
    if (g_str_equal(name, "Category")) return g_variant_new_string("Communications");
    if (g_str_equal(name, "Id")) return g_variant_new_string(item->id);
    if (g_str_equal(name, "Title")) return g_variant_new_string(item->title);
    if (g_str_equal(name, "Status")) return g_variant_new_string("Active");
    if (g_str_equal(name, "WindowId")) return g_variant_new_int32(0);
    if (g_str_equal(name, "IconName")) return g_variant_new_string(item->icon_name);
    if (g_str_equal(name, "IconThemePath")) return g_variant_new_string(item->icon_theme_path);
    if (g_str_equal(name, "IconPixmap")) return g_variant_new_array(G_VARIANT_TYPE("(iiay)"), NULL, 0);
    if (g_str_equal(name, "OverlayIconName")) return g_variant_new_string("");
    if (g_str_equal(name, "AttentionIconName")) return g_variant_new_string("");
    if (g_str_equal(name, "ToolTip")) {
        return g_variant_new("(s@a(iiay)ss)", item->icon_name,
                             g_variant_new_array(G_VARIANT_TYPE("(iiay)"), NULL, 0), item->title, item->tooltip);
    }
    /* Hosts then open the menu on a primary click, as tray icons usually do. */
    if (g_str_equal(name, "ItemIsMenu")) return g_variant_new_boolean(TRUE);
    if (g_str_equal(name, "Menu")) return g_variant_new_object_path(MENU_PATH);
    g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY, "Unknown property %s", name);
    return NULL;
}

static void item_method_call(GDBusConnection *connection, const char *sender, const char *path,
                             const char *interface, const char *method, GVariant *parameters,
                             GDBusMethodInvocation *invocation, gpointer data) {
    SnItem *item = data;
    if (g_str_equal(method, "Activate") || g_str_equal(method, "SecondaryActivate")) {
        if (item->activate) item->activate(item->user_data);
    }
    /* ContextMenu and Scroll: hosts show the dbusmenu themselves; nothing to do. */
    g_dbus_method_invocation_return_value(invocation, NULL);
}

static const GDBusInterfaceVTable item_vtable = {item_method_call, item_get_property, NULL, {0}};

/* ---- com.canonical.dbusmenu ---- */

static GVariant *entry_properties(const MenuEntry *entry) {
    GVariantBuilder props;
    g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
    if (entry->label[0] == '\0') {
        g_variant_builder_add(&props, "{sv}", "type", g_variant_new_string("separator"));
    } else {
        g_variant_builder_add(&props, "{sv}", "label", g_variant_new_string(entry->label));
        g_variant_builder_add(&props, "{sv}", "enabled", g_variant_new_boolean(entry->enabled));
    }
    g_variant_builder_add(&props, "{sv}", "visible", g_variant_new_boolean(TRUE));
    return g_variant_builder_end(&props);
}

static GVariant *root_properties(void) {
    GVariantBuilder props;
    g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&props, "{sv}", "children-display", g_variant_new_string("submenu"));
    return g_variant_builder_end(&props);
}

static GVariant *layout(SnItem *item) {
    GVariantBuilder children;
    g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
    for (int i = 0; i < item->menu_count; i++) {
        GVariant *child = g_variant_new("(i@a{sv}@av)", item->menu[i].id, entry_properties(&item->menu[i]),
                                        g_variant_new_array(G_VARIANT_TYPE_VARIANT, NULL, 0));
        g_variant_builder_add(&children, "v", child);
    }
    return g_variant_new("(i@a{sv}av)", 0, root_properties(), &children);
}

static const MenuEntry *find_entry(SnItem *item, int id) {
    for (int i = 0; i < item->menu_count; i++) {
        if (item->menu[i].id == id) return &item->menu[i];
    }
    return NULL;
}

static GVariant *properties_for(SnItem *item, int id) {
    if (id == 0) return root_properties();
    const MenuEntry *entry = find_entry(item, id);
    return entry ? entry_properties(entry) : NULL;
}

static void menu_event(SnItem *item, int id, const char *event) {
    if (g_str_equal(event, "clicked") && item->menu_clicked && find_entry(item, id)) {
        item->menu_clicked(id, item->user_data);
    }
}

static void menu_method_call(GDBusConnection *connection, const char *sender, const char *path,
                             const char *interface, const char *method, GVariant *parameters,
                             GDBusMethodInvocation *invocation, gpointer data) {
    SnItem *item = data;
    if (g_str_equal(method, "GetLayout")) {
        /* The menu is flat, so every request gets the whole tree from the root. */
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(u@(ia{sv}av))", item->revision, layout(item)));
    } else if (g_str_equal(method, "GetGroupProperties")) {
        GVariantIter *ids;
        g_variant_get(parameters, "(aias)", &ids, NULL);
        GVariantBuilder result;
        g_variant_builder_init(&result, G_VARIANT_TYPE("a(ia{sv})"));
        gint32 id;
        while (g_variant_iter_next(ids, "i", &id)) {
            GVariant *props = properties_for(item, id);
            if (props) g_variant_builder_add(&result, "(i@a{sv})", id, props);
        }
        g_variant_iter_free(ids);
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(@a(ia{sv}))", g_variant_builder_end(&result)));
    } else if (g_str_equal(method, "GetProperty")) {
        gint32 id;
        const char *name;
        g_variant_get(parameters, "(i&s)", &id, &name);
        GVariant *props = properties_for(item, id);
        GVariant *value = props ? g_variant_lookup_value(props, name, NULL) : NULL;
        if (props) g_variant_unref(g_variant_ref_sink(props));
        if (value) {
            g_dbus_method_invocation_return_value(invocation, g_variant_new("(v)", value));
            g_variant_unref(value);
        } else {
            g_dbus_method_invocation_return_dbus_error(invocation, "com.canonical.dbusmenu.Error", "No such property");
        }
    } else if (g_str_equal(method, "Event")) {
        gint32 id;
        const char *event;
        g_variant_get(parameters, "(i&svu)", &id, &event, NULL, NULL);
        menu_event(item, id, event);
        g_dbus_method_invocation_return_value(invocation, NULL);
    } else if (g_str_equal(method, "EventGroup")) {
        GVariantIter *events;
        g_variant_get(parameters, "(a(isvu))", &events);
        gint32 id;
        const char *event;
        GVariant *payload;
        while (g_variant_iter_next(events, "(i&svu)", &id, &event, &payload, NULL)) {
            menu_event(item, id, event);
            g_variant_unref(payload);
        }
        g_variant_iter_free(events);
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(@ai)", g_variant_new_array(G_VARIANT_TYPE_INT32, NULL, 0)));
    } else if (g_str_equal(method, "AboutToShow")) {
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(b)", FALSE));
    } else if (g_str_equal(method, "AboutToShowGroup")) {
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(@ai@ai)",
            g_variant_new_array(G_VARIANT_TYPE_INT32, NULL, 0), g_variant_new_array(G_VARIANT_TYPE_INT32, NULL, 0)));
    } else {
        g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownMethod", method);
    }
}

static GVariant *menu_get_property(GDBusConnection *connection, const char *sender, const char *path,
                                   const char *interface, const char *name, GError **error, gpointer data) {
    if (g_str_equal(name, "Version")) return g_variant_new_uint32(3);
    if (g_str_equal(name, "TextDirection")) return g_variant_new_string("ltr");
    if (g_str_equal(name, "Status")) return g_variant_new_string("normal");
    if (g_str_equal(name, "IconThemePath")) return g_variant_new_strv(NULL, 0);
    g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY, "Unknown property %s", name);
    return NULL;
}

static const GDBusInterfaceVTable menu_vtable = {menu_method_call, menu_get_property, NULL, {0}};

/* ---- Watcher registration ---- */

static void register_with_watcher(SnItem *item) {
    g_dbus_connection_call(item->connection, WATCHER_NAME, WATCHER_PATH, WATCHER_NAME, "RegisterStatusNotifierItem",
                           g_variant_new("(s)", item->bus_name), NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL, NULL);
}

static void watcher_appeared(GDBusConnection *connection, const char *name, const char *owner, gpointer data) {
    SnItem *item = data;
    item->has_watcher = true;
    register_with_watcher(item);
}

static void watcher_vanished(GDBusConnection *connection, const char *name, gpointer data) {
    ((SnItem *)data)->has_watcher = false;
}

SnItem *sn_item_new(const char *id, const char *title, const char *icon_name,
                    SnActivateCallback activate, SnMenuCallback menu_clicked, void *user_data) {
    GError *error = NULL;
    GDBusConnection *connection = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (!connection) {
        g_warning("StatusNotifierItem: no session bus: %s", error->message);
        g_error_free(error);
        return NULL;
    }
    SnItem *item = g_new0(SnItem, 1);
    item->connection = connection;
    item->id = g_strdup(id);
    item->title = g_strdup(title);
    item->icon_name = g_strdup(icon_name);
    item->tooltip = g_strdup("");
    item->icon_theme_path = g_strdup("");
    item->revision = 1;
    item->activate = activate;
    item->menu_clicked = menu_clicked;
    item->user_data = user_data;
    item->item_info = g_dbus_node_info_new_for_xml(item_xml, NULL);
    item->menu_info = g_dbus_node_info_new_for_xml(menu_xml, NULL);
    item->item_registration = g_dbus_connection_register_object(connection, ITEM_PATH, item->item_info->interfaces[0],
                                                                &item_vtable, item, NULL, NULL);
    item->menu_registration = g_dbus_connection_register_object(connection, MENU_PATH, item->menu_info->interfaces[0],
                                                                &menu_vtable, item, NULL, NULL);
    item->bus_name = g_strdup_printf("org.kde.StatusNotifierItem-%d-1", (int)getpid());
    item->name_owner = g_bus_own_name_on_connection(connection, item->bus_name, G_BUS_NAME_OWNER_FLAGS_NONE,
                                                    NULL, NULL, NULL, NULL);
    item->watcher_watch = g_bus_watch_name_on_connection(connection, WATCHER_NAME, G_BUS_NAME_WATCHER_FLAGS_NONE,
                                                         watcher_appeared, watcher_vanished, item, NULL);
    return item;
}

void sn_item_set_icon(SnItem *item, const char *icon_name, const char *tooltip) {
    if (!item) return;
    g_free(item->icon_name);
    item->icon_name = g_strdup(icon_name);
    g_free(item->tooltip);
    item->tooltip = g_strdup(tooltip ? tooltip : "");
    emit(item, ITEM_PATH, "org.kde.StatusNotifierItem", "NewIcon", NULL);
    emit(item, ITEM_PATH, "org.kde.StatusNotifierItem", "NewToolTip", NULL);
}

static void free_menu(SnItem *item) {
    for (int i = 0; i < item->menu_count; i++) g_free(item->menu[i].label);
    g_free(item->menu);
    item->menu = NULL;
    item->menu_count = 0;
}

void sn_item_set_menu(SnItem *item, const SnMenuItem *items, int count) {
    if (!item) return;
    free_menu(item);
    item->menu = g_new0(MenuEntry, count);
    for (int i = 0; i < count; i++) {
        item->menu[i] = (MenuEntry){items[i].id, g_strdup(items[i].label ? items[i].label : ""), items[i].enabled};
    }
    item->menu_count = count;
    item->revision++;
    emit(item, MENU_PATH, "com.canonical.dbusmenu", "LayoutUpdated", g_variant_new("(ui)", item->revision, 0));
}

void sn_item_set_icon_theme_path(SnItem *item, const char *path) {
    if (!item) return;
    g_free(item->icon_theme_path);
    item->icon_theme_path = g_strdup(path ? path : "");
    emit(item, ITEM_PATH, "org.kde.StatusNotifierItem", "NewIcon", NULL);
}

bool sn_item_has_watcher(const SnItem *item) {
    return item && item->has_watcher;
}

void sn_item_free(SnItem *item) {
    if (!item) return;
    g_bus_unwatch_name(item->watcher_watch);
    g_bus_unown_name(item->name_owner);
    g_dbus_connection_unregister_object(item->connection, item->menu_registration);
    g_dbus_connection_unregister_object(item->connection, item->item_registration);
    g_dbus_node_info_unref(item->menu_info);
    g_dbus_node_info_unref(item->item_info);
    g_object_unref(item->connection);
    free_menu(item);
    g_free(item->bus_name);
    g_free(item->id);
    g_free(item->title);
    g_free(item->icon_name);
    g_free(item->tooltip);
    g_free(item->icon_theme_path);
    g_free(item);
}
