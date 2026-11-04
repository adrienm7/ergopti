/* Exact three typedef blocks extracted from the pinned proposed Probe. */
typedef struct {
			int type; unsigned long serial; int send_event; struct _XDisplay *display;
			int extension, evtype; unsigned int cookie; void *data;
		} ErgoptiXIPropertyCookieV2;
typedef struct {
			int type; unsigned long serial; int send_event; struct _XDisplay *display;
			int extension, evtype; unsigned long time; int deviceid;
			unsigned long property; int what;
		} ErgoptiXIPropertyEventV2;
typedef struct { int deviceid, mask_len; unsigned char *mask; } ErgoptiXIPropertyMaskV2;
