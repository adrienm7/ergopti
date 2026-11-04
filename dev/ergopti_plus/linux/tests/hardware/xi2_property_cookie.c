/* Private non-input XI2 ABI/property-cookie oracle, never a production loader. */
#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/extensions/XInput2.h>
#include <stddef.h>
#include <limits.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include "xi2_property_types.h"

#define MATCH_FIELD(a,b,f) _Static_assert(offsetof(a,f)==offsetof(b,f), "offset " #f); \
 _Static_assert(sizeof(((a*)0)->f)==sizeof(((b*)0)->f), "size " #f)
#define MATCH_TYPE(a,b) _Static_assert(sizeof(a)==sizeof(b), "size " #a); \
 _Static_assert(_Alignof(a)==_Alignof(b), "alignment " #a)
MATCH_TYPE(ErgoptiXIPropertyCookieV2,XGenericEventCookie);
MATCH_FIELD(ErgoptiXIPropertyCookieV2,XGenericEventCookie,type);
MATCH_FIELD(ErgoptiXIPropertyCookieV2,XGenericEventCookie,serial);
MATCH_FIELD(ErgoptiXIPropertyCookieV2,XGenericEventCookie,send_event);
MATCH_FIELD(ErgoptiXIPropertyCookieV2,XGenericEventCookie,display);
MATCH_FIELD(ErgoptiXIPropertyCookieV2,XGenericEventCookie,extension);
MATCH_FIELD(ErgoptiXIPropertyCookieV2,XGenericEventCookie,evtype);
MATCH_FIELD(ErgoptiXIPropertyCookieV2,XGenericEventCookie,cookie);
MATCH_FIELD(ErgoptiXIPropertyCookieV2,XGenericEventCookie,data);
MATCH_TYPE(ErgoptiXIPropertyEventV2,XIPropertyEvent);
MATCH_FIELD(ErgoptiXIPropertyEventV2,XIPropertyEvent,type);
MATCH_FIELD(ErgoptiXIPropertyEventV2,XIPropertyEvent,serial);
MATCH_FIELD(ErgoptiXIPropertyEventV2,XIPropertyEvent,send_event);
MATCH_FIELD(ErgoptiXIPropertyEventV2,XIPropertyEvent,display);
MATCH_FIELD(ErgoptiXIPropertyEventV2,XIPropertyEvent,extension);
MATCH_FIELD(ErgoptiXIPropertyEventV2,XIPropertyEvent,evtype);
MATCH_FIELD(ErgoptiXIPropertyEventV2,XIPropertyEvent,time);
MATCH_FIELD(ErgoptiXIPropertyEventV2,XIPropertyEvent,deviceid);
MATCH_FIELD(ErgoptiXIPropertyEventV2,XIPropertyEvent,property);
MATCH_FIELD(ErgoptiXIPropertyEventV2,XIPropertyEvent,what);
MATCH_TYPE(ErgoptiXIPropertyMaskV2,XIEventMask);
MATCH_FIELD(ErgoptiXIPropertyMaskV2,XIEventMask,deviceid);
MATCH_FIELD(ErgoptiXIPropertyMaskV2,XIEventMask,mask_len);
MATCH_FIELD(ErgoptiXIPropertyMaskV2,XIEventMask,mask);
_Static_assert(sizeof(ErgoptiXIPropertyCookieV2)<=sizeof(XEvent),"original buffer capacity");
_Static_assert(sizeof(unsigned long)==8,"this private experiment requires the pinned LP64 host");

struct facts { unsigned long serial,time,property; int deviceid,what; };
static int errors, fetched, freed, events, published, opened, closed;
static int peer_matches(sa_family_t family,const struct ucred *peer,pid_t expected) {
 return family==AF_UNIX && peer && expected>0 && peer->pid==expected && peer->uid==getuid();
}
static int bind_peer(Display *d,pid_t expected,struct ucred *peer) {
 struct sockaddr_storage address; socklen_t address_size=sizeof(address),peer_size=sizeof(*peer);
 int fd=ConnectionNumber(d);
 if(fd<0 || getpeername(fd,(struct sockaddr*)&address,&address_size)!=0 ||
    address_size<sizeof(sa_family_t) || address.ss_family!=AF_UNIX ||
    getsockopt(fd,SOL_SOCKET,SO_PEERCRED,peer,&peer_size)!=0 || peer_size!=sizeof(*peer)) return 0;
 return peer_matches(address.ss_family,peer,expected);
}
static int xerror(Display *d, XErrorEvent *e) { (void)d; (void)e; errors++; return 0; }
static double monotonic(void) {
 struct timespec t; if(clock_gettime(CLOCK_MONOTONIC,&t)!=0) return -1;
 return (double)t.tv_sec+(double)t.tv_nsec/1000000000.0;
}
/* Outer original queue/Display/opcode anchors are independent of scalar payload.
 * Read only initialized payload fields; never copy/read payload.display. */
static int scalars(const XGenericEventCookie *c, Display *d, int opcode, struct facts *out) {
 if(!c || c->type!=GenericEvent || c->display!=d || c->send_event ||
    c->extension!=opcode || c->evtype!=XI_PropertyEvent || !c->data) return 0;
 const XIPropertyEvent *p=c->data;
 if(p->type!=GenericEvent || p->send_event || p->extension!=opcode ||
    p->evtype!=XI_PropertyEvent || p->serial!=c->serial ||
    p->serial>9007199254740991UL || p->time>UINT32_MAX ||
    p->property==0 || p->property>UINT32_MAX || p->deviceid<0 ||
    (p->what!=XIPropertyCreated && p->what!=XIPropertyModified && p->what!=XIPropertyDeleted)) return 0;
 out->serial=p->serial; out->time=p->time; out->property=p->property;
 out->deviceid=p->deviceid; out->what=p->what; return 1;
}
/* These structures are controlled, not genuine fetched events. The Display
 * field in the property payload is deliberately neither initialized nor read. */
static int controlled(void) {
 XIPropertyEvent p;
 p.type=GenericEvent;p.serial=7;p.send_event=0;p.extension=131;p.evtype=XI_PropertyEvent;
 p.time=9;p.deviceid=3;p.property=27;p.what=XIPropertyCreated;
 Display *d=(Display*)(uintptr_t)1;
 XGenericEventCookie c={.type=GenericEvent,.serial=7,.send_event=0,.display=d,
  .extension=131,.evtype=XI_PropertyEvent,.cookie=1,.data=&p};
 struct facts f; int passed=0;
#define CHECK(x) do { if(!(x)) return 1; passed++; } while(0)
 CHECK(scalars(&c,d,131,&f)==1 && f.property==27 && f.what==XIPropertyCreated);
 c.display=NULL;CHECK(!scalars(&c,d,131,&f));c.display=d;
 c.extension=132;CHECK(!scalars(&c,d,131,&f));c.extension=131;
 c.evtype=XI_Motion;CHECK(!scalars(&c,d,131,&f));c.evtype=XI_PropertyEvent;
 c.send_event=1;CHECK(!scalars(&c,d,131,&f));c.send_event=0;
 c.data=NULL;CHECK(!scalars(&c,d,131,&f));c.data=&p;
 p.serial=8;CHECK(!scalars(&c,d,131,&f));p.serial=7;
 p.property=0;CHECK(!scalars(&c,d,131,&f));p.property=27;
 p.time=(unsigned long)UINT32_MAX+1;CHECK(!scalars(&c,d,131,&f));p.time=9;
 p.deviceid=-1;CHECK(!scalars(&c,d,131,&f));p.deviceid=3;
 p.what=3;CHECK(!scalars(&c,d,131,&f));p.what=XIPropertyCreated;
 CHECK(scalars(&c,d,131,&f)==1);
 struct ucred peer={.pid=getpid(),.uid=getuid(),.gid=getgid()};
 CHECK(peer_matches(AF_UNIX,&peer,getpid()));
 CHECK(!peer_matches(AF_INET,&peer,getpid()));
 peer.pid=0;CHECK(!peer_matches(AF_UNIX,&peer,getpid()));peer.pid=getpid();
 peer.uid=(uid_t)(getuid()+1);CHECK(!peer_matches(AF_UNIX,&peer,getpid()));
#undef CHECK
 printf("{\"controlled_passed\":%d,\"native_fetch\":0,\"native_free\":0}\n",passed);
 return 0;
}
/* One exact connection and one XNextEvent queue. Lifetime/cursor values are
 * private C custody counters; they are never claimed as native source epochs. */
static int observe(Display *d,int opcode,int device,Atom property,int what,unsigned long *cursor) {
 double until=monotonic()+1.0;if(until<1.0)return 0;
 while(monotonic()<until) {
  if(XPending(d)>0) {
   XEvent e;XNextEvent(d,&e);events++;(*cursor)++;
   if(e.type!=GenericEvent || e.xcookie.display!=d || e.xcookie.extension!=opcode ||
      e.xcookie.evtype!=XI_PropertyEvent || e.xcookie.send_event) continue;
   unsigned long owned_cursor=*cursor;
   if(!XGetEventData(d,&e.xcookie)) return 0;
   fetched++;
   struct facts f;int copied=scalars(&e.xcookie,d,opcode,&f);
   XFreeEventData(d,&e.xcookie);freed++;
   /* No cookie/payload pointer is used after free. Publish detached scalars
    * only after original connection/queue lifetime (same C owner) revalidation. */
   if(owned_cursor!=*cursor || fetched!=freed || errors) return 0;
   if(!copied) return 0;
   if(f.deviceid==device && f.property==property && f.what==what) { published++;return 1; }
  } else { struct timespec pause={.tv_sec=0,.tv_nsec=5000000};nanosleep(&pause,NULL); }
 }
 return 0;
}
static int property_equals(Display *d,int device,Atom property,const unsigned char *expected,int size) {
 Atom type=None;int format=0;unsigned long count=0,after=0;unsigned char *bytes=NULL;
 int status=XIGetProperty(d,device,property,0,64,False,AnyPropertyType,&type,&format,&count,&after,&bytes);
 int same=status==Success && type==XA_STRING && format==8 && count==(unsigned long)size &&
  after==0 && bytes && memcmp(bytes,expected,(size_t)size)==0;
 if(bytes)XFree(bytes);
 return same;
}
static int property_absent(Display *d,int device,Atom property) {
 int count=0;Atom *list=XIListProperties(d,device,&count);
 int absent=count>=0 && (count==0 || list!=NULL);
 if(!absent){if(list)XFree(list);return 0;}
 for(int i=0;i<count;i++)if(list[i]==property)absent=0;
 if(list)XFree(list);
 return absent;
}
int main(int argc,char **argv) {
 if(argc==2 && strcmp(argv[1],"--controlled")==0)return controlled();
 if(argc!=3)return 2;
 char *pid_end=NULL;errno=0;long expected_pid=strtol(argv[2],&pid_end,10);
 if(errno || !pid_end || pid_end==argv[2] || *pid_end || expected_pid<=0 || expected_pid>INT_MAX)return 2;
 Display *d=XOpenDisplay(argv[1]);if(!d){puts("{\"stage\":\"display-unavailable\",\"opened\":0}");return 2;}
 opened++;XSetErrorHandler(xerror);
 struct ucred peer={0};
 if(!bind_peer(d,(pid_t)expected_pid,&peer)) {
  int refused_close=XCloseDisplay(d);closed++;
  printf("{\"stage\":\"peer-refused\",\"opened\":1,\"closed_calls\":1,\"close_status\":%d,\"fetched\":0,\"freed\":0}\n",refused_close);
  return 2;
 }
 int stage=0,ok=0,opcode=0,event=0,error=0,major=2,minor=0,device=-1,request_sent=0;
 Atom property=None;XIDeviceInfo *devices=NULL;int count=0;
 unsigned long cursor=0;
 unsigned char mask[XIMaskLen(XI_PropertyEvent)]={0};XISetMask(mask,XI_PropertyEvent);
 XIEventMask selection={.deviceid=XIAllDevices,.mask_len=sizeof(mask),.mask=mask};
 if(!XQueryExtension(d,"XInputExtension",&opcode,&event,&error))goto done;
 stage=1;if(XIQueryVersion(d,&major,&minor)!=Success || major<2)goto done;
 stage=2;devices=XIQueryDevice(d,XIAllDevices,&count);if(!devices)goto done;
 for(int i=0;i<count;i++)if(devices[i].enabled && devices[i].use==XISlavePointer){device=devices[i].deviceid;break;}
 XIFreeDeviceInfo(devices);devices=NULL;if(device<0)goto done;
 stage=3;if(XISelectEvents(d,DefaultRootWindow(d),&selection,1)!=Success)goto done;
 XSync(d,False);if(errors)goto done;
 char name[100];int n=snprintf(name,sizeof(name),"_ERGOPTI_PRIVATE_PROPERTY_COOKIE_%ld",(long)getpid());
 if(n<=0 || n>=(int)sizeof(name))goto done;
 property=XInternAtom(d,name,False);if(property==None || !property_absent(d,device,property))goto done;
 static const unsigned char first[]="owned-property-one",second[]="owned-property-two";
 stage=4;request_sent=1;XIChangeProperty(d,device,property,XA_STRING,8,XIPropModeReplace,(unsigned char*)first,sizeof(first)-1);
 XSync(d,False);if(errors || !observe(d,opcode,device,property,XIPropertyCreated,&cursor) ||
  !property_equals(d,device,property,first,sizeof(first)-1))goto done;
 stage=5;XIChangeProperty(d,device,property,XA_STRING,8,XIPropModeReplace,(unsigned char*)second,sizeof(second)-1);
 XSync(d,False);if(errors || !observe(d,opcode,device,property,XIPropertyModified,&cursor) ||
  !property_equals(d,device,property,second,sizeof(second)-1))goto done;
 stage=6;XIDeleteProperty(d,device,property);XSync(d,False);
 if(errors || !observe(d,opcode,device,property,XIPropertyDeleted,&cursor) || !property_absent(d,device,property))goto done;
 request_sent=0;stage=7;ok=fetched==3 && freed==3 && published==3 && errors==0;
done:
 if(devices)XIFreeDeviceInfo(devices);
 if(request_sent && property!=None){XIDeleteProperty(d,device,property);XSync(d,False);}
 int close_status=XCloseDisplay(d);closed++;
 if(close_status!=0 || fetched!=freed || errors)ok=0;
 printf("{\"stage\":%d,\"opened\":%d,\"closed_calls\":%d,\"close_status\":%d,\"xi_major\":%d,\"xi_minor\":%d,\"events\":%d,\"fetched\":%d,\"freed\":%d,\"published\":%d,\"xerrors\":%d,\"input_injections\":0,\"native_epoch_claim\":false,\"server_peer_pid\":%ld,\"server_peer_uid\":%lu}\n",stage,opened,closed,close_status,major,minor,events,fetched,freed,published,errors,(long)peer.pid,(unsigned long)peer.uid);
 return ok?0:1;
}
