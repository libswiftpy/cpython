// Umbrella header for the CPython module.
//
// Each platform gets its own staged headers, because pyconfig.h is generated
// per build, and TargetConditionals picks the right one — including telling
// an iOS simulator destination apart from a device.
#include <TargetConditionals.h>

#if TARGET_OS_SIMULATOR
#include "../../.cpython-dist-iphonesimulator/include/python/Python.h"
#elif TARGET_OS_IPHONE
#include "../../.cpython-dist-iphoneos/include/python/Python.h"
#else
#include "../../.cpython-dist/include/python/Python.h"
#endif
