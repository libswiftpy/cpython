#include "Python.h"
#include "Carray.h"

PyMODINIT_FUNC PyInit_array(void);
void *CarrayInitializer0(void) { return (void *)PyInit_array; }
