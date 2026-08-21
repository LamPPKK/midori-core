#include <stdio.h>

#include <webkit/webkit.h>

#ifndef XANH_REQUIRED_WEBKIT_MAJOR
#error "XANH_REQUIRED_WEBKIT_MAJOR must be supplied by CMake"
#endif
#ifndef XANH_REQUIRED_WEBKIT_MINOR
#error "XANH_REQUIRED_WEBKIT_MINOR must be supplied by CMake"
#endif
#ifndef XANH_REQUIRED_WEBKIT_MICRO
#error "XANH_REQUIRED_WEBKIT_MICRO must be supplied by CMake"
#endif

static int
version_is_supported(unsigned int major, unsigned int minor, unsigned int micro)
{
    if (major != XANH_REQUIRED_WEBKIT_MAJOR)
        return major > XANH_REQUIRED_WEBKIT_MAJOR;
    if (minor != XANH_REQUIRED_WEBKIT_MINOR)
        return minor > XANH_REQUIRED_WEBKIT_MINOR;
    return micro >= XANH_REQUIRED_WEBKIT_MICRO;
}

int
main(void)
{
    unsigned int major = webkit_get_major_version();
    unsigned int minor = webkit_get_minor_version();
    unsigned int micro = webkit_get_micro_version();

    printf("WebKitGTK runtime: %u.%u.%u (minimum: %u.%u.%u)\n",
           major, minor, micro,
           XANH_REQUIRED_WEBKIT_MAJOR,
           XANH_REQUIRED_WEBKIT_MINOR,
           XANH_REQUIRED_WEBKIT_MICRO);

    if (!version_is_supported(major, minor, micro)) {
        fprintf(stderr, "Unsupported WebKitGTK runtime\n");
        return 1;
    }

    return 0;
}
