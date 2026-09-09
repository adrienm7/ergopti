// tools/diagnostics/hs274-provider-click.c
// Post a synthetic UI click at geometry obtained from the verified AX control.

#include <CoreGraphics/CoreGraphics.h>
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    const char *runner = getenv("GITHUB_ACTIONS");
    if (argc != 3 || !runner || strcmp(runner, "true") != 0) {
        fputs("expected two coordinates on a disposable Actions runner\n", stderr);
        return 1;
    }
    double coordinates[2];
    for (int index = 0; index < 2; ++index) {
        char *end = NULL;
        errno = 0;
        coordinates[index] = strtod(argv[index + 1], &end);
        if (errno || end == argv[index + 1] || *end || !isfinite(coordinates[index])) {
            fputs("invalid control coordinate\n", stderr);
            return 1;
        }
    }
    CGPoint point = CGPointMake(coordinates[0], coordinates[1]);
    if (!CGRectContainsPoint(CGDisplayBounds(CGMainDisplayID()), point)) {
        fputs("control is outside the observed primary display\n", stderr);
        return 1;
    }
    if (!CGPreflightPostEventAccess()) {
        fputs("Quartz posting access is unavailable\n", stderr);
        return 1;
    }
    CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, point, kCGMouseButtonLeft);
    CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
    if (!down || !up) {
        if (down) CFRelease(down);
        if (up) CFRelease(up);
        fputs("could not allocate the complete Quartz UI pair\n", stderr);
        return 1;
    }
    CGEventSetIntegerValueField(down, kCGMouseEventClickState, 1);
    CGEventSetIntegerValueField(up, kCGMouseEventClickState, 1);
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down);
    CFRelease(up);
    puts("Posted a synthetic Quartz mouse down/up pair; acceptance is not established.");
    return 0;
}
