#include "CShims.h"
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <string.h>

// Exported by CoreGraphics but only declared in ColorSync headers.
extern CFUUIDRef CGDisplayCreateUUIDFromDisplayID(uint32_t displayID);

typedef int (*f_cid)(void);
typedef CFArrayRef (*f_copyspaces)(int);
typedef uint64_t (*f_getcur)(int, CFStringRef);
typedef CFStringRef (*f_activedisp)(int);
typedef CFArrayRef (*f_spaces_for_windows)(int, int, CFArrayRef);
typedef int (*f_is_ordered_in)(int, uint32_t, uint8_t *);

static struct {
    int tried;
    void *handle;
    int conn;
    f_copyspaces copy_spaces;
    f_getcur get_current;
    f_activedisp active_display;
    f_spaces_for_windows spaces_for_windows;
    f_is_ordered_in is_ordered_in;
} S;

static bool load_sl(void) {
    if (S.tried) return S.handle != NULL;
    S.tried = 1;
    void *h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
    if (!h) return false;
    f_cid cid = (f_cid)dlsym(h, "SLSMainConnectionID");
    S.copy_spaces    = (f_copyspaces)dlsym(h, "SLSCopyManagedDisplaySpaces");
    S.get_current    = (f_getcur)dlsym(h, "SLSManagedDisplayGetCurrentSpace");
    S.active_display = (f_activedisp)dlsym(h, "SLSCopyActiveMenuBarDisplayIdentifier");
    S.spaces_for_windows = (f_spaces_for_windows)dlsym(h, "SLSCopySpacesForWindows");
    S.is_ordered_in = (f_is_ordered_in)dlsym(h, "SLSWindowIsOrderedIn");
    if (!cid || !S.copy_spaces || !S.get_current) { dlclose(h); return false; }
    S.conn = cid();
    S.handle = h;
    return true;
}

bool is_spaces_available(void) { return load_sl(); }

/// UUID string of the display under the mouse cursor, or NULL.
static CFStringRef copy_display_uuid_under_cursor(void) {
    CGEventRef e = CGEventCreate(NULL);
    if (!e) return NULL;
    CGPoint p = CGEventGetLocation(e);
    CFRelease(e);
    CGDirectDisplayID did = 0;
    uint32_t n = 0;
    if (CGGetDisplaysWithPoint(p, 1, &did, &n) != kCGErrorSuccess || n == 0) return NULL;
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(did);
    if (!uuid) return NULL;
    CFStringRef s = CFUUIDCreateString(NULL, uuid);
    CFRelease(uuid);
    return s;
}

/// Entry of SLSCopyManagedDisplaySpaces() for the display under the cursor, falling back to the
/// active menu-bar display and then to the first entry.
static CFDictionaryRef find_display(CFArrayRef displays) {
    CFIndex n = CFArrayGetCount(displays);
    if (n == 0) return NULL;
    if (n == 1) return CFArrayGetValueAtIndex(displays, 0);

    CFDictionaryRef found = NULL;
    CFStringRef wanted = copy_display_uuid_under_cursor();
    if (!wanted && S.active_display) wanted = S.active_display(S.conn);
    if (wanted) {
        for (CFIndex i = 0; i < n; i++) {
            CFDictionaryRef d = CFArrayGetValueAtIndex(displays, i);
            CFStringRef ident = CFDictionaryGetValue(d, CFSTR("Display Identifier"));
            if (ident && CFStringCompare(ident, wanted, kCFCompareCaseInsensitive) == kCFCompareEqualTo) { found = d; break; }
        }
        CFRelease(wanted);
    }
    return found ? found : CFArrayGetValueAtIndex(displays, 0);
}

bool is_spaces_info(ISSpaceInfo *out) {
    if (!out || !load_sl()) return false;
    memset(out, 0, sizeof(*out));
    CFArrayRef displays = S.copy_spaces(S.conn);
    if (!displays) return false;
    bool ok = false;

    CFDictionaryRef display = find_display(displays);
    CFStringRef ident = display ? CFDictionaryGetValue(display, CFSTR("Display Identifier")) : NULL;
    CFArrayRef spaces = display ? CFDictionaryGetValue(display, CFSTR("Spaces")) : NULL;
    if (ident && spaces && CFGetTypeID(spaces) == CFArrayGetTypeID()) {
        CFStringGetCString(ident, out->display, sizeof(out->display), kCFStringEncodingUTF8);
        uint64_t cur = S.get_current(S.conn, ident);
        CFIndex n = CFArrayGetCount(spaces);
        if (n > IS_MAX_SPACES) n = IS_MAX_SPACES;
        bool found = false;
        for (CFIndex i = 0; i < n; i++) {
            CFDictionaryRef s = CFArrayGetValueAtIndex(spaces, i);
            CFNumberRef idn = CFDictionaryGetValue(s, CFSTR("id64"));
            CFNumberRef tn = CFDictionaryGetValue(s, CFSTR("type"));
            CFNumberRef pn = CFDictionaryGetValue(s, CFSTR("pid"));
            uint64_t id = 0;
            int32_t type = 0, pid = 0;
            if (idn) CFNumberGetValue(idn, kCFNumberSInt64Type, &id);
            if (tn) CFNumberGetValue(tn, kCFNumberSInt32Type, &type);
            if (pn) CFNumberGetValue(pn, kCFNumberSInt32Type, &pid);
            out->types[i] = type;
            out->pids[i] = pid;
            if (id == cur && !found) { out->index = (uint32_t)i; found = true; }
        }
        out->count = (uint32_t)n;
        ok = found && n > 0;
    }
    CFRelease(displays);
    return ok;
}

int32_t is_spaces_app_window_indexes(int32_t pid, int32_t *out_indexes, uint32_t *out_windows, int32_t max) {
    if (!out_indexes || max <= 0 || pid <= 0 || !load_sl() || !S.spaces_for_windows) return 0;

    // Space ids of the display under the cursor, in Dock order.
    uint64_t ids[IS_MAX_SPACES];
    CFIndex nspaces = 0;
    CFArrayRef displays = S.copy_spaces(S.conn);
    if (!displays) return 0;
    CFDictionaryRef display = find_display(displays);
    CFArrayRef spaces = display ? CFDictionaryGetValue(display, CFSTR("Spaces")) : NULL;
    if (spaces && CFGetTypeID(spaces) == CFArrayGetTypeID()) {
        nspaces = CFArrayGetCount(spaces);
        if (nspaces > IS_MAX_SPACES) nspaces = IS_MAX_SPACES;
        for (CFIndex i = 0; i < nspaces; i++) {
            CFNumberRef idn = CFDictionaryGetValue(CFArrayGetValueAtIndex(spaces, i), CFSTR("id64"));
            ids[i] = 0;
            if (idn) CFNumberGetValue(idn, kCFNumberSInt64Type, &ids[i]);
        }
    }
    CFRelease(displays);
    if (nspaces == 0) return 0;

    // All windows, front to back, including those on other spaces.
    CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!windows) return 0;
    int32_t written = 0;
    CFIndex count = CFArrayGetCount(windows);
    for (CFIndex i = 0; i < count && written < max; i++) {
        CFDictionaryRef w = CFArrayGetValueAtIndex(windows, i);
        int32_t owner = 0, layer = -1, wid = 0;
        CFNumberRef on = CFDictionaryGetValue(w, CFSTR("kCGWindowOwnerPID"));
        CFNumberRef ln = CFDictionaryGetValue(w, CFSTR("kCGWindowLayer"));
        CFNumberRef wn = CFDictionaryGetValue(w, CFSTR("kCGWindowNumber"));
        if (!on || !ln || !wn) continue;
        CFNumberGetValue(on, kCFNumberSInt32Type, &owner);
        CFNumberGetValue(ln, kCFNumberSInt32Type, &layer);
        CFNumberGetValue(wn, kCFNumberSInt32Type, &wid);
        if (owner != pid || layer != 0) continue;

        // Skip helper and placeholder windows that are not real documents.
        CGRect bounds = CGRectZero;
        CFDictionaryRef bd = CFDictionaryGetValue(w, CFSTR("kCGWindowBounds"));
        if (!bd || !CGRectMakeWithDictionaryRepresentation(bd, &bounds)) continue;
        if (bounds.size.width < 50 || bounds.size.height < 50) continue;
        double alpha = 1;
        CFNumberRef an = CFDictionaryGetValue(w, CFSTR("kCGWindowAlpha"));
        if (an) CFNumberGetValue(an, kCFNumberDoubleType, &alpha);
        if (alpha <= 0) continue;

        // A closed, hidden or minimized window keeps its Space but is ordered out. Counting it
        // would make an app look present on a Space where nothing of it is shown.
        if (S.is_ordered_in) {
            uint8_t ordered_in = 1;
            if (S.is_ordered_in(S.conn, (uint32_t)wid, &ordered_in) == 0 && !ordered_in) continue;
        }

        CFArrayRef one = CFArrayCreate(NULL, (const void **)&wn, 1, &kCFTypeArrayCallBacks);
        CFArrayRef ws = S.spaces_for_windows(S.conn, 0x7, one);
        CFRelease(one);
        if (!ws) continue;
        for (CFIndex j = 0; j < CFArrayGetCount(ws) && written < max; j++) {
            uint64_t sid = 0;
            CFNumberGetValue(CFArrayGetValueAtIndex(ws, j), kCFNumberSInt64Type, &sid);
            for (CFIndex k = 0; k < nspaces; k++) {
                if (ids[k] != sid) continue;
                bool seen = false;
                for (int32_t m = 0; m < written; m++) if (out_indexes[m] == (int32_t)k) { seen = true; break; }
                if (!seen) {
                    if (out_windows) out_windows[written] = (uint32_t)wid;
                    out_indexes[written++] = (int32_t)k;
                }
                break;
            }
        }
        CFRelease(ws);
    }
    CFRelease(windows);
    return written;
}

// ---- Focusing another app's window ----
//
// Same calls yabai (MIT) uses to focus a window: make the owning process frontmost with that
// window, then post the two event records a click on the window would generate to make it key.

typedef struct { uint32_t high, low; } is_psn;
typedef int (*f_set_front)(is_psn *, uint32_t, uint32_t);
typedef int (*f_post_record)(is_psn *, uint8_t *);
typedef int (*f_psn_for_pid)(pid_t, is_psn *);

bool is_focus_window(int32_t pid, uint32_t window) {
    static f_set_front set_front;
    static f_post_record post_record;
    static f_psn_for_pid psn_for_pid;
    static int tried;
    if (!tried) {
        tried = 1;
        if (load_sl()) {
            set_front = (f_set_front)dlsym(S.handle, "_SLPSSetFrontProcessWithOptions");
            post_record = (f_post_record)dlsym(S.handle, "SLPSPostEventRecordTo");
        }
        psn_for_pid = (f_psn_for_pid)dlsym(RTLD_DEFAULT, "GetProcessForPID");
    }
    if (!set_front || !post_record || !psn_for_pid || pid <= 0 || window == 0) return false;

    is_psn psn = {0, 0};
    if (psn_for_pid(pid, &psn) != 0) return false;
    const uint32_t kUserGenerated = 0x200;
    if (set_front(&psn, window, kUserGenerated) != 0) return false;

    for (uint8_t kind = 1; kind <= 2; kind++) {
        uint8_t record[0xf8] = {0};
        record[0x04] = 0xf8;
        record[0x08] = kind;
        record[0x3a] = 0x10;
        memset(record + 0x20, 0xff, 0x10);
        memcpy(record + 0x3c, &window, sizeof(window));
        post_record(&psn, record);
    }
    return true;
}
