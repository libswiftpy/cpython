#include "Python.h"
#include "Cbinascii.h"

PyMODINIT_FUNC PyInit_binascii(void);
void *CbinasciiInitializer0(void) { return (void *)PyInit_binascii; }
