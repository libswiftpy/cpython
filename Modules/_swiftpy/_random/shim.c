#include "Python.h"
#include "Crandom.h"

PyMODINIT_FUNC PyInit__random(void);
void *CrandomInitializer0(void) { return (void *)PyInit__random; }
