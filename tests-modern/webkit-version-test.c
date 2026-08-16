#include <stdio.h>

#include <webkit/webkit.h>

#define REQUIRED_MAJOR 2
#define REQUIRED_MINOR 52
#define REQUIRED_MICRO 5

static int
version_is_supported(unsigned int major, unsigned int minor, unsigned int micro)
{
    if (major != REQUIRED_MAJOR)
        return major > REQUIRED_MAJOR;
    if (minor != REQUIRED_MINOR)
        return minor > REQUIRED_MINOR;
    return micro >= REQUIRED_MICRO;
}

int
main(void)
{
    unsigned int major = webkit_get_major_version();
    unsigned int minor = webkit_get_minor_version();
    unsigned int micro = webkit_get_micro_version();

    printf("WebKitGTK runtime: %u.%u.%u (minimum: %u.%u.%u)\n",
           major, minor, micro,
           REQUIRED_MAJOR, REQUIRED_MINOR, REQUIRED_MICRO);

    if (!version_is_supported(major, minor, micro)) {
        fprintf(stderr, "Unsupported WebKitGTK runtime\n");
        return 1;
    }

    return 0;
}
