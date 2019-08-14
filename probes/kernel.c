#if defined(__DragonFly__) \
 || defined(__FreeBSD__) \
 || defined(__NetBSD__) \
 || defined(__OpenBSD__)
bsd

#elif defined(_WIN32) \
   || defined(__CYGWIN__)
#include <windows.h>
#ifdef _WIN32_WINNT
winnt
#else
win32
#endif

#elif defined(__linux__)
linux

#elif defined(__unix__)
unix

#else
#error "unsupported kernel"

#endif
