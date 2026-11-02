// Instant space switching by driving the Dock with a synthetic trackpad swipe.
//
// The synthetic-gesture technique (event fields, the macOS 27 IOHID payload and the interception
// of native swipes) is adapted from InstantSpaceSwitcher by jurplel:
// https://github.com/jurplel/InstantSpaceSwitcher
//
// MIT License
//
// Copyright (c) 2026 jurplel
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#include "CShims.h"
#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

// ---- Undocumented CGEvent fields and constants ----

static const CGEventField kFieldEventType       = (CGEventField)55;
static const CGEventField kFieldGestureHIDType  = (CGEventField)110;
static const CGEventField kFieldSwipeMask       = (CGEventField)115;
static const CGEventField kFieldSwipeMotion     = (CGEventField)123;
static const CGEventField kFieldSwipeProgress   = (CGEventField)124;
static const CGEventField kFieldSwipePositionX  = (CGEventField)125;
static const CGEventField kFieldSwipePositionY  = (CGEventField)126;
static const CGEventField kFieldSwipeVelocityX  = (CGEventField)129;
static const CGEventField kFieldSwipeVelocityY  = (CGEventField)130;
static const CGEventField kFieldGesturePhase    = (CGEventField)132;
static const CGEventField kFieldGesturePhaseAlt = (CGEventField)134;
static const CGEventField kFieldZoomDeltaY      = (CGEventField)138;
static const CGEventField kFieldTimestampAlt    = (CGEventField)169;

enum { kEventGesture = 29, kEventDockControl = 30 };
enum { kHIDDockSwipe = 23, kHIDVelocity = 9, kHIDFluidTouchGesture = 23 };
enum { kPhaseBegan = 1, kPhaseChanged = 2, kPhaseEnded = 4, kPhaseCancelled = 8 };
enum { kMotionHorizontal = 1 };
static const uint16_t kGestureFlavorDockPrimary = 3;

// Near-zero progress (smallest non-zero 16.16 value) leaves nothing to animate; the fling
// velocity on the ended phase is what commits the switch.
static const double kTinyProgress = 0.000016;
static const double kFlingVelocityModern = 9999.0;   // payload is 16.16 fixed point (max ~32767)
static const double kFlingVelocityLegacy = 2000.0;

/// Stored in kCGEventSourceUserData of the swipe events Quicker posts.
static const int64_t kSwipeMarker = 0x49535357;
/// Our own swipes come back through the tap within milliseconds of being posted.
static const CFTimeInterval kOwnEventWindow = 1.0;
/// A tracked native swipe that has gone silent this long is over, even without an ended event.
static const CFTimeInterval kTrackingTimeout = 2.0;
static const double kSecondStepAt = 0.45;    // swipe progress that moves a second Space
static const double kNextStepEvery = 0.15;   // further progress for each Space after that
static const double kSpeedWindow = 0.06;     // seconds of the swipe the finger speed is measured over
// Measured: unhurried swipes move the fingers at about 0.7-0.9 screen widths per second, quick
// edge-to-edge flicks at about 4-5.
static const double kSlowSpeed = 1.5;        // screen widths per second: no speed-up up to here
static const double kFastSpeed = 3.0;        // from here, travel counts kMaxBoost times
static const double kMaxBoost = 3.0;

// ---- OS / preference helpers ----

static bool requires_augmentation(void) {
    static int cached = -1;
    if (cached != -1) return cached;
    char version[32] = {0};
    size_t size = sizeof(version);
    int major = 0;
    if (sysctlbyname("kern.osproductversion", version, &size, NULL, 0) == 0) sscanf(version, "%d", &major);
    cached = major >= 27 ? 1 : 0;
    return cached;
}

static int natural_scrolling = -1;

static void natural_scrolling_changed(CFNotificationCenterRef c, void *o, CFNotificationName n, const void *obj, CFDictionaryRef info) {
    (void)c; (void)o; (void)n; (void)obj; (void)info;
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
    natural_scrolling = -1;
}

/// Sign of the posted progress/velocity for a move towards `direction`. On macOS 27 "right" is
/// negative, and the Dock reads the sign through the natural scrolling preference.
static double post_sign(int direction) {
    if (natural_scrolling < 0) {
        Boolean valid = false;
        Boolean natural = CFPreferencesGetAppBooleanValue(CFSTR("com.apple.swipescrolldirection"), kCFPreferencesAnyApplication, &valid);
        natural_scrolling = (!valid || natural) ? 1 : 0;
    }
    if (!requires_augmentation()) return direction > 0 ? 1.0 : -1.0;
    double sign = direction > 0 ? -1.0 : 1.0;
    return natural_scrolling ? sign : -sign;
}

// ---- macOS 27 IOHID payload ----

#pragma pack(push, 1)
typedef struct { uint32_t size, type, options; uint8_t depth, reserved[3]; } HIDEventBase;
typedef struct {
    HIDEventBase base;
    int32_t position_x, position_y, position_z;
    uint32_t swipe_mask;
    uint16_t gesture_motion, gesture_flavor;
    int32_t swipe_progress;
} HIDFluidTouchGesture;
typedef struct { HIDEventBase base; int32_t velocity_x, velocity_y, velocity_z; } HIDVelocity;
typedef struct { uint64_t timestamp, sender_id; uint32_t options, attribute_length, event_count; } HIDQueueHeader;
#pragma pack(pop)

_Static_assert(sizeof(HIDEventBase) == 16, "IOHID base layout");
_Static_assert(sizeof(HIDFluidTouchGesture) == 40, "IOHID fluid gesture layout");
_Static_assert(sizeof(HIDVelocity) == 28, "IOHID velocity layout");
_Static_assert(sizeof(HIDQueueHeader) == 28, "IOHID queue header layout");

static int32_t fixed1616(double v) {
    int32_t f = (int32_t)(v * 65536.0);
    if (f == 0 && v != 0.0) return v > 0.0 ? 1 : -1;
    return f;
}

/// Returns a retained copy of `event` with the raw IOHID payload macOS 27 needs appended.
static CGEventRef augment(CGEventRef event) {
    int64_t phase  = CGEventGetIntegerValueField(event, kFieldGesturePhase);
    int64_t motion = CGEventGetIntegerValueField(event, kFieldSwipeMotion);
    int64_t mask   = CGEventGetIntegerValueField(event, kFieldSwipeMask);
    double progress = CGEventGetDoubleValueField(event, kFieldSwipeProgress);
    double px = CGEventGetDoubleValueField(event, kFieldSwipePositionX);
    double py = CGEventGetDoubleValueField(event, kFieldSwipePositionY);
    double vx = CGEventGetDoubleValueField(event, kFieldSwipeVelocityX);
    double vy = CGEventGetDoubleValueField(event, kFieldSwipeVelocityY);

    bool with_velocity = vx != 0.0 || vy != 0.0 || phase == kPhaseEnded;
    size_t payload_len = sizeof(HIDQueueHeader) + sizeof(HIDFluidTouchGesture) + (with_velocity ? sizeof(HIDVelocity) : 0);
    uint8_t *payload = calloc(1, payload_len);
    if (!payload) return NULL;

    HIDQueueHeader *header = (HIDQueueHeader *)payload;
    uint64_t ts = CGEventGetTimestamp(event);
    header->timestamp = ts ? ts : mach_absolute_time();
    header->event_count = with_velocity ? 2 : 1;

    HIDFluidTouchGesture *fluid = (HIDFluidTouchGesture *)(payload + sizeof(HIDQueueHeader));
    fluid->base.size = sizeof(HIDFluidTouchGesture);
    fluid->base.type = kHIDFluidTouchGesture;
    fluid->base.options = (uint32_t)((phase & 0xFF) << 24);
    fluid->position_x = fixed1616(px);
    fluid->position_y = fixed1616(py);
    fluid->swipe_mask = (uint32_t)mask;
    fluid->gesture_motion = (uint16_t)motion;
    fluid->gesture_flavor = kGestureFlavorDockPrimary;
    fluid->swipe_progress = fixed1616(progress);

    if (with_velocity) {
        HIDVelocity *vel = (HIDVelocity *)(payload + sizeof(HIDQueueHeader) + sizeof(HIDFluidTouchGesture));
        vel->base.size = sizeof(HIDVelocity);
        vel->base.type = kHIDVelocity;
        vel->base.depth = 1;
        vel->velocity_x = fixed1616(vx);
        vel->velocity_y = fixed1616(vy);
    }

    CGEventRef result = NULL;
    CFDataRef data = CGEventCreateData(kCFAllocatorDefault, event);
    if (data) {
        const uint8_t *bytes = CFDataGetBytePtr(data);
        CFIndex len = CFDataGetLength(data);
        // Serialized event format version 2: 00 00 00 02
        if (len >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 2) {
            size_t total = (size_t)len + 4 + payload_len;
            uint8_t *buf = malloc(total);
            if (buf) {
                memcpy(buf, bytes, (size_t)len);
                buf[len]     = (uint8_t)((payload_len >> 8) & 0xFF);  // size, big-endian
                buf[len + 1] = (uint8_t)(payload_len & 0xFF);
                buf[len + 2] = (uint8_t)((4205 >> 8) & 0xFF);         // field id 4205, big-endian
                buf[len + 3] = (uint8_t)(4205 & 0xFF);
                memcpy(buf + len + 4, payload, payload_len);
                CFDataRef new_data = CFDataCreate(kCFAllocatorDefault, buf, (CFIndex)total);
                free(buf);
                if (new_data) {
                    result = CGEventCreateFromData(kCFAllocatorDefault, new_data);
                    CFRelease(new_data);
                }
            }
        }
        CFRelease(data);
    }
    free(payload);
    return result;
}

// ---- Posting ----

static CFMachPortRef g_tap = NULL;
static CFRunLoopSourceRef g_tap_source = NULL;
static bool g_intercept = true;
static ISSwipeHandler g_handler = NULL;
static ISKeyHandler g_key_handler = NULL;
static ISMouseHandler g_mouse_handler = NULL;
static ISFlagsHandler g_flags_handler = NULL;
static CGEventRef g_held_flags[8];      // modifier changes held back by the flags handler, in order
static unsigned g_held_flags_count = 0;
static uint8_t g_swallowed_keys[128];  // key-downs we swallowed, so their key-ups are swallowed too
static bool g_tracking = false;
static bool g_fired = false;
static int g_direction = 0;   // of the switch the tracked swipe made, +1 or -1
static int g_steps = 0;       // Spaces the tracked swipe has moved so far
static double g_counted = 0;  // progress already turned into Spaces past the second one
static double g_credit = 0;   // speed-weighted travel not yet worth a whole Space
/// Recent (time, progress) samples of the tracked swipe, to measure the finger speed.
enum { kSpeedSamples = 16 };
static struct { double t, p; } g_samples[kSpeedSamples];
static int g_sample_count = 0;
static CFAbsoluteTime g_tracking_at = 0;   // last event of the tracked native swipe
static unsigned g_companions_pending = 0;  // our companion gesture events not seen back yet
static CFAbsoluteTime g_last_post = 0;

static bool post_phase(int phase, int direction) {
    const double sign = post_sign(direction);
    CGEventRef ev = CGEventCreate(NULL);
    if (!ev) return false;
    CGEventSetIntegerValueField(ev, kCGEventSourceUserData, kSwipeMarker);
    CGEventSetIntegerValueField(ev, kFieldEventType, kEventDockControl);
    CGEventSetIntegerValueField(ev, kFieldGestureHIDType, kHIDDockSwipe);
    CGEventSetIntegerValueField(ev, kFieldGesturePhase, phase);
    CGEventSetIntegerValueField(ev, kFieldSwipeMotion, kMotionHorizontal);
    CGEventSetDoubleValueField(ev, kFieldSwipeProgress, sign * kTinyProgress);

    if (!requires_augmentation()) {
        CGEventSetDoubleValueField(ev, kFieldSwipeVelocityX, sign * kFlingVelocityLegacy);
        CGEventSetDoubleValueField(ev, kFieldSwipeVelocityY, sign * kFlingVelocityLegacy);
        CGEventPost(kCGSessionEventTap, ev);
        CFRelease(ev);
        return true;
    }

    // Fields a real trackpad swipe carries on macOS 27.
    CGEventSetIntegerValueField(ev, kFieldGesturePhaseAlt, phase);
    CGEventSetDoubleValueField(ev, kFieldZoomDeltaY, 3.0);
    CGEventSetDoubleValueField(ev, kFieldTimestampAlt, (double)mach_absolute_time());
    CGEventSetDoubleValueField(ev, kFieldSwipePositionX, 0.1);
    if (phase == kPhaseEnded) CGEventSetDoubleValueField(ev, kFieldSwipeVelocityX, sign * kFlingVelocityModern);

    CGEventRef augmented = augment(ev);
    CFRelease(ev);
    if (!augmented) return false;

    // The Dock ignores a DockControl event without a companion gesture event.
    CGEventRef companion = CGEventCreate(NULL);
    if (!companion) { CFRelease(augmented); return false; }
    CGEventSetIntegerValueField(companion, kCGEventSourceUserData, kSwipeMarker);
    CGEventSetIntegerValueField(companion, kFieldEventType, kEventGesture);

    if (g_tap) g_companions_pending += 1;
    CGEventPost(kCGSessionEventTap, augmented);
    CGEventPost(kCGSessionEventTap, companion);
    CFRelease(augmented);
    CFRelease(companion);
    return true;
}

bool is_ds_post_switch(int direction) {
    g_last_post = CFAbsoluteTimeGetCurrent();
    // All three phases are needed; with only two, Mission Control breaks.
    return post_phase(kPhaseBegan, direction)
        && post_phase(kPhaseChanged, direction)
        && post_phase(kPhaseEnded, direction);
}

// ---- Interception of the native swipe ----

static void fire(double value) {
    g_fired = true;
    g_direction = value > 0.0 ? 1 : -1;
    g_steps = 1;
    g_counted = 0;
    g_credit = 0;
    g_sample_count = 0;
    if (g_handler) g_handler(g_direction, false);
}

/// Finger speed in screen widths per second over the last ~60 ms of the swipe.
static double swipe_speed(double t, double p) {
    if (g_sample_count == kSpeedSamples) {
        memmove(g_samples, g_samples + 1, sizeof(g_samples[0]) * (kSpeedSamples - 1));
        g_sample_count--;
    }
    g_samples[g_sample_count].t = t;
    g_samples[g_sample_count].p = p;
    g_sample_count++;
    int from = 0;
    for (int i = g_sample_count - 1; i >= 0; i--) {
        if (t - g_samples[i].t >= kSpeedWindow) { from = i; break; }
    }
    double dt = t - g_samples[from].t;
    return dt > 0.0 ? (p - g_samples[from].p) / dt : 0.0;
}

/// How much a stretch of travel counts at `speed`: 1 up to kSlowSpeed, kMaxBoost from kFastSpeed.
static double speed_boost(double speed) {
    if (speed <= kSlowSpeed) return 1.0;
    if (speed >= kFastSpeed) return kMaxBoost;
    return 1.0 + (kMaxBoost - 1.0) * (speed - kSlowSpeed) / (kFastSpeed - kSlowSpeed);
}

/// The fingers keep moving after the first switch. The swipe progress is the finger travel in
/// screen widths; a full stroke across a MacBook trackpad measured about 0.8, a normal one-Space
/// swipe stays under 0.4. The second Space comes at kSecondStepAt; past it, every kNextStepEvery
/// of travel moves one more, and faster fingers make the same travel count for more. Moving back
/// does not undo switches already made.
static void extend_swipe(double progress, double time) {
    if ((progress > 0.0 ? 1 : -1) != g_direction) return;
    double p = fabs(progress);
    double speed = swipe_speed(time, p);
    if (p < kSecondStepAt) return;
    if (g_steps == 1) {
        g_steps = 2;
        g_counted = kSecondStepAt;
        if (g_handler) g_handler(g_direction, true);
    }
    if (p <= g_counted) return;
    g_credit += (p - g_counted) * speed_boost(speed);
    g_counted = p;
    while (g_credit >= kNextStepEvery) {
        g_credit -= kNextStepEvery;
        g_steps++;
        if (g_handler) g_handler(g_direction, true);
    }
}

static void reset_tracking(void) {
    g_tracking = false;
    g_fired = false;
}

/// True while a native swipe is being swallowed. A swipe whose ended event never arrived (for
/// example because the tap was disabled meanwhile) stops counting after a while, so it cannot
/// keep swallowing the gesture events of pinches and other swipes forever.
static bool tracking(void) {
    if (g_tracking && CFAbsoluteTimeGetCurrent() - g_tracking_at > kTrackingTimeout) reset_tracking();
    return g_tracking;
}

/// One of the swipe events Quicker posted, coming back through the tap.
///
/// On macOS 27 they come back with source pid 0, like the trackpad's own events, so a count of
/// expected events is not enough: real events of the swipe still in progress arrive first, use up
/// the count and slip through to the Dock, which then animates. Instead each event is recognised
/// by its marker, its pid, or what it carries: the tiny progress of a Dock swipe event, or the
/// empty body of a companion gesture event.
static bool is_own_event(CGEventRef event, int64_t event_type) {
    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == kSwipeMarker) return true;
    if (CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID) == (int64_t)getpid()) return true;
    if (CFAbsoluteTimeGetCurrent() - g_last_post > kOwnEventWindow) {
        g_companions_pending = 0;
        return false;
    }
    if (event_type == kEventDockControl) {
        // kTinyProgress, either as posted or after a round trip through 16.16 fixed point.
        double progress = fabs(CGEventGetDoubleValueField(event, kFieldSwipeProgress));
        return progress > 1.4e-5 && progress < 1.8e-5;
    }
    return g_companions_pending > 0 && CGEventGetIntegerValueField(event, kFieldGestureHIDType) == 0;
}

static CGEventRef tap_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    (void)proxy; (void)refcon;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (g_tap) CGEventTapEnable(g_tap, true);
        // Whatever was in progress was missed while the tap was off.
        g_companions_pending = 0;
        reset_tracking();
        memset(g_swallowed_keys, 0, sizeof(g_swallowed_keys));
        return event;
    }

    if (type == kCGEventFlagsChanged) {
        if (!g_flags_handler) return event;
        if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == IS_REPLAY_MARKER) return event;
        bool hold = g_flags_handler((uint64_t)CGEventGetFlags(event));
        if (!hold) return event;
        if (g_held_flags_count == sizeof(g_held_flags) / sizeof(g_held_flags[0])) return event;
        CGEventRef copy = CGEventCreateCopy(event);
        if (!copy) return event;
        g_held_flags[g_held_flags_count++] = copy;
        return NULL;
    }

    if (type == kCGEventLeftMouseDown || type == kCGEventLeftMouseUp) {
        if (!g_mouse_handler) return event;
        if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == IS_REPLAY_MARKER) return event;
        CGPoint p = CGEventGetLocation(event);
        return g_mouse_handler(type == kCGEventLeftMouseDown, p.x, p.y, (uint64_t)CGEventGetFlags(event)) ? NULL : event;
    }

    if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
        int64_t keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (keycode < 0 || keycode >= 128) return event;
        if (type == kCGEventKeyUp) {
            if (!g_swallowed_keys[keycode]) return event;
            g_swallowed_keys[keycode] = 0;
            return NULL;
        }
        bool is_repeat = CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0;
        if (g_key_handler && g_key_handler((int32_t)keycode, (uint64_t)CGEventGetFlags(event), is_repeat)) {
            g_swallowed_keys[keycode] = 1;
            return NULL;
        }
        // A key-down we let through starts a fresh press: its key-up must reach the app, even if
        // the key-up of an earlier swallowed press got lost.
        if (!is_repeat) g_swallowed_keys[keycode] = 0;
        return event;
    }

    int64_t event_type = CGEventGetIntegerValueField(event, kFieldEventType);
    if (event_type != kEventDockControl && event_type != kEventGesture) return event;

    // Our own synthetic events come straight back through this tap; let them reach the Dock.
    if (is_own_event(event, event_type)) {
        if (event_type == kEventGesture && g_companions_pending > 0) g_companions_pending--;
        return event;
    }
    if (CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID) != 0) return event;  // not from the trackpad

    if (!g_intercept) return event;

    if (event_type == kEventGesture) return tracking() ? NULL : event;  // companion of a swallowed swipe

    if (CGEventGetIntegerValueField(event, kFieldGestureHIDType) != kHIDDockSwipe) return event;
    if (CGEventGetIntegerValueField(event, kFieldSwipeMotion) != kMotionHorizontal) return event;

    switch (CGEventGetIntegerValueField(event, kFieldGesturePhase)) {
    case kPhaseBegan:
        g_tracking = true;
        g_fired = false;
        g_tracking_at = CFAbsoluteTimeGetCurrent();
        return NULL;

    case kPhaseChanged: {
        if (!tracking()) return event;
        g_tracking_at = CFAbsoluteTimeGetCurrent();
        double progress = CGEventGetDoubleValueField(event, kFieldSwipeProgress);
        if (!g_fired && progress != 0.0) fire(progress);
        else if (g_fired) extend_swipe(progress, (double)CGEventGetTimestamp(event) / 1e9);
        return NULL;
    }

    case kPhaseEnded: {
        if (!tracking()) return event;
        double velocity = CGEventGetDoubleValueField(event, kFieldSwipeVelocityX);
        if (!g_fired && velocity != 0.0) fire(velocity);
        reset_tracking();
        if (requires_augmentation()) {
            // macOS 27: the Dock needs the real ended event to close its gesture state.
            // Zero the motion so it does not switch a second time.
            CGEventSetDoubleValueField(event, kFieldSwipeProgress, 0.0);
            CGEventSetDoubleValueField(event, kFieldSwipeVelocityX, 0.0);
            CGEventSetDoubleValueField(event, kFieldSwipeVelocityY, 0.0);
            return event;
        }
        return NULL;
    }

    case kPhaseCancelled:
        reset_tracking();
        return NULL;

    default:
        return tracking() ? NULL : event;
    }
}

bool is_ds_tap_install(void) {
    if (g_tap) return true;
    CGEventMask mask = (1ULL << kEventGesture) | (1ULL << kEventDockControl)
        | CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(kCGEventFlagsChanged)
        | CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp);
    g_tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, tap_callback, NULL);
    if (!g_tap) return false;
    g_tap_source = CFMachPortCreateRunLoopSource(NULL, g_tap, 0);
    if (!g_tap_source) { CFRelease(g_tap); g_tap = NULL; return false; }
    CFRunLoopAddSource(CFRunLoopGetMain(), g_tap_source, kCFRunLoopCommonModes);
    CGEventTapEnable(g_tap, true);

    natural_scrolling = -1;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), &natural_scrolling, natural_scrolling_changed,
                                    CFSTR("SwipeScrollDirectionDidChangeNotification"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    return true;
}

bool is_ds_tap_installed(void) { return g_tap != NULL; }
void is_ds_set_intercept(bool enabled) { g_intercept = enabled; if (!enabled) reset_tracking(); }
void is_ds_set_swipe_handler(ISSwipeHandler handler) { g_handler = handler; }
void is_ds_set_key_handler(ISKeyHandler handler) { g_key_handler = handler; }
void is_ds_set_mouse_handler(ISMouseHandler handler) { g_mouse_handler = handler; }
void is_ds_set_flags_handler(ISFlagsHandler handler) { g_flags_handler = handler; }

void is_ds_release_held_flags(void) {
    for (unsigned i = 0; i < g_held_flags_count; i++) {
        CGEventSetIntegerValueField(g_held_flags[i], kCGEventSourceUserData, IS_REPLAY_MARKER);
        CGEventPost(kCGHIDEventTap, g_held_flags[i]);
        CFRelease(g_held_flags[i]);
    }
    g_held_flags_count = 0;
}
