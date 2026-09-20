// Public interface of the thunk table.
//
// Free of Python.h on purpose, like the other shim headers: Swift builds this
// module without CPython's include paths, so the function pointers cross over
// as opaque pointers and are cast back on the Swift side.
#ifndef SWIFTPY_THUNKS_H
#define SWIFTPY_THUNKS_H

/// How many bindings can be registered: one C entry point each.
#define SWIFTPY_THUNK_COUNT 4096

/// The C function CPython calls for binding `slot`, as a `PyCFunction`. Each
/// one forwards to swiftpy_dispatch with its own slot, which is how a Swift
/// closure gets a C function pointer of its own without capturing anything.
void *swiftpy_thunk(int slot);

/// Implemented in Swift: finds the binding registered for `slot` and runs it.
/// `self`, `args` and the result are `PyObject *`.
void *swiftpy_dispatch(int slot, void *self, void *args);

#endif
