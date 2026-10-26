#ifndef CSHIMS_H
#define CSHIMS_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- Spaces (SkyLight, read-only) ----

enum { IS_MAX_SPACES = 64 };

typedef struct {
    uint32_t index;     // zero-based index of the current space on the display under the cursor
    uint32_t count;     // spaces on that display (desktops and full-screen apps), in Dock order
    char display[128];  // display UUID
    int32_t types[IS_MAX_SPACES];  // per space: 0 = desktop, 4 = full-screen app, other = system
    int32_t pids[IS_MAX_SPACES];   // per space: owning app of a full-screen space, 0 otherwise
} ISSpaceInfo;

bool is_spaces_available(void);
/// Fills `out` for the display under the mouse cursor. Returns false on failure.
bool is_spaces_info(ISSpaceInfo *out);

/// Indexes (into the cursor display's space list) of the spaces holding normal windows of app
/// `pid`, most recently used window first, without duplicates. Returns how many were written.
/// When `out_windows` is not NULL it receives, for each of those spaces, the id of the app's
/// most recently used window there.
int32_t is_spaces_app_window_indexes(int32_t pid, int32_t *out_indexes, uint32_t *out_windows, int32_t max);

/// Makes `window` of app `pid` the key window of the frontmost app through the WindowServer, the
/// way a click on it would, without waiting for the app itself. Works for a window on a Space that
/// is not visible yet: when Quicker lands there, that window is already on top.
bool is_focus_window(int32_t pid, uint32_t window);

// ---- Dock swipe (synthetic gesture + interception of the native one) ----

/// Called from the event tap (main run loop) when a native horizontal Dock swipe starts.
/// direction: +1 = towards the next space (right), -1 = towards the previous one (left).
typedef void (*ISSwipeHandler)(int direction);

/// Asks the Dock to switch one space instantly by posting a synthetic swipe with a tiny
/// progress and a huge fling velocity. Needs Accessibility permission.
bool is_ds_post_switch(int direction);

/// Installs the session event tap that swallows native horizontal Dock swipes and hands them to
/// the handler instead. Needs Accessibility permission; returns false if it cannot be created.
bool is_ds_tap_install(void);
bool is_ds_tap_installed(void);
/// When false, native swipes pass through untouched (normal animated switching).
void is_ds_set_intercept(bool enabled);
void is_ds_set_swipe_handler(ISSwipeHandler handler);

/// Marker stored in kCGEventSourceUserData of the mouse events Quicker replays, so its own
/// event tap lets them through.
#define IS_REPLAY_MARKER 0x49535250

/// Called from the event tap for every left mouse-down (`down` = true) and mouse-up, in global
/// top-left screen coordinates. Return true to swallow the event. Replayed events are not reported.
typedef bool (*ISMouseHandler)(bool down, double x, double y, uint64_t flags);
void is_ds_set_mouse_handler(ISMouseHandler handler);

/// Called from the event tap for every key-down. Return true to swallow the key (its key-up is
/// swallowed too). `flags` are CGEventFlags; `is_repeat` is set for auto-repeat key-downs.
typedef bool (*ISKeyHandler)(int32_t keycode, uint64_t flags, bool is_repeat);
void is_ds_set_key_handler(ISKeyHandler handler);

#ifdef __cplusplus
}
#endif
#endif
