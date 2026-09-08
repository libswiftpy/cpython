#include "Python.h"
#include "Czlib.h"

PyMODINIT_FUNC PyInit_zlib(void);

void *CzlibInitializer(void) {
    return (void *)PyInit_zlib;
}
