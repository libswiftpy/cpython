#include "Python.h"
#include "Cposixsubprocess.h"
#include <TargetConditionals.h>

// The module forks, which the iOS/visionOS libpython is built without, and a
// target cannot drop a source per platform, so the source is pulled in here.
#if TARGET_OS_OSX
#include "../../_posixsubprocess.c"
void *CposixsubprocessInitializer0(void) { return (void *)PyInit__posixsubprocess; }
#else
void *CposixsubprocessInitializer0(void) { return NULL; }
#endif
