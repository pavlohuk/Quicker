// DDC/CI over the display's I2C bus on Apple silicon, through IOAVService (private IOKit API, the
// way MonitorControl and m1ddc do it).

#include "CShims.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>

typedef CFTypeRef (*AVCreateFn)(CFAllocatorRef, io_service_t);
typedef IOReturn (*AVI2CFn)(CFTypeRef, uint32_t chip, uint32_t offset, void *buffer, uint32_t size);

static AVCreateFn av_create;
static AVI2CFn av_write, av_read;

static bool load(void) {
    static int loaded = -1;
    if (loaded < 0) {
        av_create = (AVCreateFn)dlsym(RTLD_DEFAULT, "IOAVServiceCreateWithService");
        av_write = (AVI2CFn)dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C");
        av_read = (AVI2CFn)dlsym(RTLD_DEFAULT, "IOAVServiceReadI2C");
        loaded = av_create && av_write && av_read;
    }
    return loaded;
}

static const uint32_t kChip = 0x37;     // DDC/CI device address
static const uint32_t kOffset = 0x51;   // host address, sent as the sub-address
static const uint8_t kHostWrite = 0x6E; // destination address byte the checksum starts from

static uint32_t number(CFDictionaryRef dict, CFStringRef key) {
    CFTypeRef value = dict ? CFDictionaryGetValue(dict, key) : NULL;
    uint32_t out = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberSInt32Type, &out);
    return out;
}

const void *is_ddc_service(uint32_t vendor, uint32_t model, uint32_t serial, bool sole_fallback) {
    if (!load()) return NULL;
    io_iterator_t it;
    if (IORegistryEntryCreateIterator(IORegistryGetRootEntry(kIOMainPortDefault), kIOServicePlane,
                                      kIORegistryIterateRecursively, &it) != KERN_SUCCESS) return NULL;

    // A framebuffer comes before the AV service of the same port in registry order, so each
    // external service is paired with the attributes of the framebuffer seen last.
    uint32_t fb_vendor = 0, fb_model = 0, fb_serial = 0;
    io_service_t best = 0, sole = 0;
    int best_score = 0, externals = 0;
    io_registry_entry_t entry;
    while ((entry = IOIteratorNext(it))) {
        io_name_t name;
        if (IORegistryEntryGetName(entry, name) != KERN_SUCCESS) name[0] = 0;
        if (strcmp(name, "AppleCLCD2") == 0 || strcmp(name, "IOMobileFramebufferShim") == 0) {
            fb_vendor = fb_model = fb_serial = 0;
            CFTypeRef attrs = IORegistryEntryCreateCFProperty(entry, CFSTR("DisplayAttributes"), NULL, 0);
            if (attrs && CFGetTypeID(attrs) == CFDictionaryGetTypeID()) {
                CFTypeRef product = CFDictionaryGetValue(attrs, CFSTR("ProductAttributes"));
                if (product && CFGetTypeID(product) == CFDictionaryGetTypeID()) {
                    fb_vendor = number(product, CFSTR("LegacyManufacturerID"));
                    fb_model = number(product, CFSTR("ProductID"));
                    fb_serial = number(product, CFSTR("SerialNumber"));
                }
            }
            if (attrs) CFRelease(attrs);
        } else if (strcmp(name, "DCPAVServiceProxy") == 0) {
            CFTypeRef location = IORegistryEntryCreateCFProperty(entry, CFSTR("Location"), NULL, 0);
            bool external = location && CFGetTypeID(location) == CFStringGetTypeID()
                && CFStringCompare(location, CFSTR("External"), 0) == kCFCompareEqualTo;
            if (location) CFRelease(location);
            if (external) {
                externals++;
                if (!sole) { sole = entry; IOObjectRetain(sole); }
                int score = 0;
                if (fb_model && fb_model == model) {
                    score = 2 + (fb_vendor && fb_vendor == vendor) + (fb_serial && fb_serial == serial);
                }
                if (score > best_score) {
                    if (best) IOObjectRelease(best);
                    best = entry;
                    IOObjectRetain(best);
                    best_score = score;
                }
            }
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(it);

    io_service_t pick = best ? best : (sole_fallback && externals == 1 ? sole : 0);
    CFTypeRef service = pick ? av_create(kCFAllocatorDefault, pick) : NULL;
    if (best) IOObjectRelease(best);
    if (sole) IOObjectRelease(sole);
    return service;
}

void is_ddc_release(const void *service) {
    if (service) CFRelease((CFTypeRef)service);
}

bool is_ddc_write(const void *service, uint8_t code, uint16_t value) {
    if (!service || !load()) return false;
    uint8_t data[6] = {0x84, 0x03, code, (uint8_t)(value >> 8), (uint8_t)(value & 0xFF), 0};
    data[5] = kHostWrite ^ kOffset ^ data[0] ^ data[1] ^ data[2] ^ data[3] ^ data[4];
    // Some displays miss a single write; a second one costs little.
    bool ok = false;
    for (int i = 0; i < 2; i++) {
        usleep(10000);
        if (av_write((CFTypeRef)service, kChip, kOffset, data, sizeof(data)) == kIOReturnSuccess) ok = true;
    }
    return ok;
}

bool is_ddc_read(const void *service, uint8_t code, uint16_t *current, uint16_t *maximum) {
    if (!service || !load()) return false;
    uint8_t request[4] = {0x82, 0x01, code, 0};
    request[3] = kHostWrite ^ kOffset ^ request[0] ^ request[1] ^ request[2];
    for (int attempt = 0; attempt < 3; attempt++) {
        usleep(10000);
        if (av_write((CFTypeRef)service, kChip, kOffset, request, sizeof(request)) != kIOReturnSuccess) continue;
        usleep(50000);  // the display needs about 40 ms to answer
        uint8_t reply[12] = {0};
        if (av_read((CFTypeRef)service, kChip, kOffset, reply, sizeof(reply)) != kIOReturnSuccess) continue;
        // 6E 88 02 <result> <code> <type> <max hi> <max lo> <cur hi> <cur lo> <checksum>
        if (reply[2] != 0x02 || reply[3] != 0x00 || reply[4] != code) continue;
        uint16_t max = (uint16_t)(reply[6] << 8 | reply[7]);
        if (max == 0) continue;
        *maximum = max;
        *current = (uint16_t)(reply[8] << 8 | reply[9]);
        return true;
    }
    return false;
}
