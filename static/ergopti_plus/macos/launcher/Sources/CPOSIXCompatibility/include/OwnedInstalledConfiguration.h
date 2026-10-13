/* Native normal-launcher configuration custody; observations are not readiness. */
#ifndef ERGOPTI_OWNED_INSTALLED_CONFIGURATION_H
#define ERGOPTI_OWNED_INSTALLED_CONFIGURATION_H
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct ergopti_owned_configuration ergopti_owned_configuration;
typedef struct ergopti_owned_configuration_route {
  const char* root;
  const char* generation;
  uid_t uid;
  pid_t pid;
} ergopti_owned_configuration_route;

/* Zero arguments: actual live launcher/principal, protected publisher, fixed UID/home. */
ergopti_owned_configuration* ergopti_owned_configuration_acquire(void);
/* Borrowed fixed strings remain owned by the original token; no route is an input. */
int ergopti_owned_configuration_observe_route(ergopti_owned_configuration*, ergopti_owned_configuration_route*);
int ergopti_owned_configuration_capture(ergopti_owned_configuration*);
int ergopti_owned_configuration_current(ergopti_owned_configuration*);
int ergopti_owned_configuration_namespace_current(ergopti_owned_configuration*);
/* Call only after original consumers' genuine retirement; this ACK closes only this holder. */
int ergopti_owned_configuration_release(ergopti_owned_configuration*);
int ergopti_owned_configuration_retired(ergopti_owned_configuration*);
int ergopti_owned_configuration_destroy(ergopti_owned_configuration*);

#ifdef __cplusplus
}
#endif
#endif
