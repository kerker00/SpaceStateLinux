#pragma once

#include <stdbool.h>

/// A tray icon published as org.kde.StatusNotifierItem with a com.canonical.dbusmenu menu.
/// It reports ItemIsMenu, so hosts open the menu on a primary click.
/// Runs on the default GLib main context; callbacks are called there.
typedef struct SnItem SnItem;

typedef void (*SnActivateCallback)(void *user_data);
typedef void (*SnMenuCallback)(int item_id, void *user_data);

/// One menu entry. An empty label makes a separator. Ids must be positive and unique.
typedef struct {
    int id;
    const char *label;
    bool enabled;
} SnMenuItem;

/// Publishes the item and registers it with the StatusNotifierWatcher whenever one appears.
/// `activate` (may be NULL) is only called by hosts that ignore ItemIsMenu.
SnItem *sn_item_new(const char *id, const char *title, const char *icon_name,
                    SnActivateCallback activate, SnMenuCallback menu_clicked, void *user_data);

/// An additional directory to look up icon names in, for icons not installed in a theme.
void sn_item_set_icon_theme_path(SnItem *item, const char *path);

/// Changes the icon (a themed icon name) and the tooltip text. Names ending in
/// "-symbolic" are tinted to the panel's foreground colour by most hosts.
void sn_item_set_icon(SnItem *item, const char *icon_name, const char *tooltip);

/// Replaces the menu.
void sn_item_set_menu(SnItem *item, const SnMenuItem *items, int count);

/// Whether a StatusNotifierWatcher (a tray host) currently exists.
bool sn_item_has_watcher(const SnItem *item);

void sn_item_free(SnItem *item);
