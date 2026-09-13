#include "Python.h"
#include "Csha1.h"

PyMODINIT_FUNC PyInit__sha1(void);
void *Csha1Initializer0(void) { return (void *)PyInit__sha1; }
