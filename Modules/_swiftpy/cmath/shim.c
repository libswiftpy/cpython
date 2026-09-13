#include "Python.h"
#include "Ccmath.h"

PyMODINIT_FUNC PyInit_cmath(void);
void *CcmathInitializer0(void) { return (void *)PyInit_cmath; }
