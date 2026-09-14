#include "Python.h"
#include "Cselect.h"

PyMODINIT_FUNC PyInit_select(void);
void *CselectInitializer0(void) { return (void *)PyInit_select; }
