/* Made by Swift/build-xcframework.sh: the configuration of the SDK being built for. */
#include <TargetConditionals.h>

#if TARGET_OS_VISION && TARGET_OS_SIMULATOR
#include "pyconfig-xrsimulator.h"
#elif TARGET_OS_VISION
#include "pyconfig-xros.h"
#elif TARGET_OS_SIMULATOR
#include "pyconfig-iphonesimulator.h"
#elif TARGET_OS_IPHONE
#include "pyconfig-iphoneos.h"
#else
#include "pyconfig-macosx.h"
#endif
