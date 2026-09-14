#include "Python.h"
#include "Csocket.h"

PyMODINIT_FUNC PyInit__socket(void);
void *CsocketInitializer0(void) { return (void *)PyInit__socket; }
