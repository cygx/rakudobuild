#if defined(__DragonFly__)
dragonfly

#elif defined(__FreeBSD__)
freebsd

#elif defined(__NetBSD__)
netbsd

#elif defined(__OpenBSD__)
openbsd

#elif defined(__CYGWIN__)
cygwin

#elif defined(__MINGW32__)
mingw

#elif defined(_WIN32)
mswin

#elif defined(__linux__)
generic-linux

#else
#error "unsupported distro"

#endif