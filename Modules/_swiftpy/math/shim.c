#include "Python.h"
#include "Cmath.h"

PyMODINIT_FUNC PyInit_math(void);
void *CmathInitializer0(void) { return (void *)PyInit_math; }
PyMODINIT_FUNC PyInit__math_integer(void);
void *CmathInitializer1(void) { return (void *)PyInit__math_integer; }
