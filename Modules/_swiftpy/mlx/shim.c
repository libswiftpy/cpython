#include "Python.h"
#include "Cmlxcore.h"

// nanobind's NB_MODULE(core, m), from MLXCore.xcframework.
PyMODINIT_FUNC PyInit_core(void);
void *CmlxcoreInitializer0(void) { return (void *)PyInit_core; }
