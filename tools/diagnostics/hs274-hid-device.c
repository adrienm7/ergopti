// tools/diagnostics/hs274-hid-device.c
// Observe virtual HID acquisition on a disposable runner without sending input.

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>

typedef CFTypeRef (*CreateDevice)(CFAllocatorRef, CFDictionaryRef, CFOptionFlags);

int main(int argc, char **argv) {
    if (argc != 2) {
        fputs("expected a fresh output JSON path\n", stderr);
        return 1;
    }
    FILE *output = fopen(argv[1], "wx");
    if (!output) {
        perror("open HID observation receipt");
        return 1;
    }
    void *library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        fprintf(output, "{\"status\":\"IOKit_load_failed\",\"hs274_fixed\":false}\n");
        return fclose(output) == 0 ? 1 : 2;
    }
    CreateDevice create = (CreateDevice)dlsym(library, "IOHIDUserDeviceCreate");
    if (!create) {
        fprintf(output, "{\"status\":\"device_creation_API_unavailable\",\"hs274_fixed\":false}\n");
        dlclose(library);
        return fclose(output) == 0 ? 1 : 2;
    }
    // Standard boot keyboard descriptor; no input report is ever submitted.
    const unsigned char descriptor[] = {
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x05, 0x07,
        0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01,
        0x75, 0x08, 0x81, 0x01, 0x95, 0x06, 0x75, 0x08,
        0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00,
        0x29, 0x65, 0x81, 0x00, 0xC0
    };
    CFDataRef report = CFDataCreate(kCFAllocatorDefault, descriptor, sizeof(descriptor));
    if (!report) {
        fprintf(output, "{\"status\":\"descriptor_allocation_failed\",\"hs274_fixed\":false}\n");
        dlclose(library);
        return fclose(output) == 0 ? 1 : 2;
    }
    const void *keys[] = { CFSTR(kIOHIDReportDescriptorKey), CFSTR(kIOHIDProductKey) };
    const void *values[] = { report, CFSTR("Ergopti HS274 isolated capability probe") };
    CFDictionaryRef properties = CFDictionaryCreate(
        kCFAllocatorDefault, keys, values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks
    );
    if (!properties) {
        CFRelease(report);
        fprintf(output, "{\"status\":\"properties_allocation_failed\",\"hs274_fixed\":false}\n");
        dlclose(library);
        return fclose(output) == 0 ? 1 : 2;
    }
    CFTypeRef device = create(kCFAllocatorDefault, properties, 0);
    int created = device != NULL;
    if (device) CFRelease(device);
    CFRelease(properties);
    CFRelease(report);
    dlclose(library);
    int written = fprintf(output,
        "{\"status\":\"capabilities_observed\",\"uid\":%u,"
        "\"virtual_device_created\":%s,\"input_reports_sent\":0,"
        "\"hs274_fixed\":false}\n",
        (unsigned)getuid(), created ? "true" : "false"
    );
    int closed = fclose(output);
    return written > 0 && closed == 0 ? 0 : 1;
}
