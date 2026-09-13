#include "Python.h"
#include "Csqlite3.h"

PyMODINIT_FUNC PyInit__sqlite3(void);
void *Csqlite3Initializer0(void) { return (void *)PyInit__sqlite3; }
