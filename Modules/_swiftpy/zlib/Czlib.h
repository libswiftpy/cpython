// Public interface of the zlib module target.
//
// Free of Python.h on purpose: Swift builds this module without CPython's
// include paths, so the initializer crosses over as an opaque pointer and is
// cast back to PythonModuleInitializer on the Swift side.
#ifndef SWIFTPY_CZLIB_H
#define SWIFTPY_CZLIB_H

void *CzlibInitializer(void);

#endif
