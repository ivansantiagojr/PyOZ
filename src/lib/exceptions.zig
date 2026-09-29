//! Exception handling and definition
//!
//! Provides types and utilities for catching, raising, and defining
//! Python exceptions from Zig code.
const fmt_mod = @import("fmt.zig");

const py = @import("python.zig");
const PyObject = py.PyObject;

/// Represents a caught Python exception
pub const PythonException = struct {
    exc_type: ?*PyObject,
    exc_value: ?*PyObject,
    exc_traceback: ?*PyObject,

    /// Get the exception type (e.g., ValueError, TypeError)
    pub fn getType(self: PythonException) ?*PyObject {
        return self.exc_type;
    }

    /// Get the exception value/message
    pub fn getValue(self: PythonException) ?*PyObject {
        return self.exc_value;
    }

    /// Get the exception traceback
    pub fn getTraceback(self: PythonException) ?*PyObject {
        return self.exc_traceback;
    }

    /// Check if this exception matches a specific type
    pub fn matches(self: PythonException, exc_type: *PyObject) bool {
        return py.PyErr_GivenExceptionMatches(self.exc_type, exc_type);
    }

    /// Check if this is a ValueError
    pub fn isValueError(self: PythonException) bool {
        return self.matches(py.PyExc_ValueError());
    }

    /// Check if this is a TypeError
    pub fn isTypeError(self: PythonException) bool {
        return self.matches(py.PyExc_TypeError());
    }

    /// Check if this is a KeyError
    pub fn isKeyError(self: PythonException) bool {
        return self.matches(py.PyExc_KeyError());
    }

    /// Check if this is an IndexError
    pub fn isIndexError(self: PythonException) bool {
        return self.matches(py.PyExc_IndexError());
    }

    /// Check if this is a RuntimeError
    pub fn isRuntimeError(self: PythonException) bool {
        return self.matches(py.PyExc_RuntimeError());
    }

    /// Check if this is a StopIteration
    pub fn isStopIteration(self: PythonException) bool {
        return self.matches(py.PyExc_StopIteration());
    }

    /// Check if this is a ZeroDivisionError
    pub fn isZeroDivisionError(self: PythonException) bool {
        return self.matches(py.PyExc_ZeroDivisionError());
    }

    /// Check if this is an AttributeError
    pub fn isAttributeError(self: PythonException) bool {
        return self.matches(py.PyExc_AttributeError());
    }

    /// Check if this is a MemoryError
    pub fn isMemoryError(self: PythonException) bool {
        return self.matches(py.PyExc_MemoryError());
    }

    /// Check if this is an OSError
    pub fn isOSError(self: PythonException) bool {
        return self.matches(py.PyExc_OSError());
    }

    /// Check if this is a NotImplementedError
    pub fn isNotImplementedError(self: PythonException) bool {
        return self.matches(py.PyExc_NotImplementedError());
    }

    /// Check if this is an OverflowError
    pub fn isOverflowError(self: PythonException) bool {
        return self.matches(py.PyExc_OverflowError());
    }

    /// Check if this is a FileNotFoundError
    pub fn isFileNotFoundError(self: PythonException) bool {
        return self.matches(py.PyExc_FileNotFoundError());
    }

    /// Check if this is a PermissionError
    pub fn isPermissionError(self: PythonException) bool {
        return self.matches(py.PyExc_PermissionError());
    }

    /// Check if this is a TimeoutError
    pub fn isTimeoutError(self: PythonException) bool {
        return self.matches(py.PyExc_TimeoutError());
    }

    /// Check if this is a ConnectionError
    pub fn isConnectionError(self: PythonException) bool {
        return self.matches(py.PyExc_ConnectionError());
    }

    /// Check if this is an EOFError
    pub fn isEOFError(self: PythonException) bool {
        return self.matches(py.PyExc_EOFError());
    }

    /// Check if this is an ImportError
    pub fn isImportError(self: PythonException) bool {
        return self.matches(py.PyExc_ImportError());
    }

    /// Check if this is a NameError
    pub fn isNameError(self: PythonException) bool {
        return self.matches(py.PyExc_NameError());
    }

    /// Check if this is a SyntaxError
    pub fn isSyntaxError(self: PythonException) bool {
        return self.matches(py.PyExc_SyntaxError());
    }

    /// Check if this is a RecursionError
    pub fn isRecursionError(self: PythonException) bool {
        return self.matches(py.PyExc_RecursionError());
    }

    /// Check if this is an ArithmeticError
    pub fn isArithmeticError(self: PythonException) bool {
        return self.matches(py.PyExc_ArithmeticError());
    }

    /// Check if this is a BufferError
    pub fn isBufferError(self: PythonException) bool {
        return self.matches(py.PyExc_BufferError());
    }

    /// Check if this is a SystemError
    pub fn isSystemError(self: PythonException) bool {
        return self.matches(py.PyExc_SystemError());
    }

    /// Check if this is a UnicodeError
    pub fn isUnicodeError(self: PythonException) bool {
        return self.matches(py.PyExc_UnicodeError());
    }

    /// Get the string representation of the exception value
    pub fn getMessage(self: PythonException) ?[]const u8 {
        if (self.exc_value) |val| {
            const str_obj = py.PyObject_Str(val) orelse return null;
            defer py.Py_DecRef(str_obj);
            return py.PyUnicode_AsUTF8(str_obj);
        }
        return null;
    }

    /// Re-raise this exception (restore it to Python's error state)
    pub fn reraise(self: PythonException) void {
        // Restore takes ownership, so we incref first if we want to keep our references
        if (self.exc_type) |t| py.Py_IncRef(t);
        if (self.exc_value) |v| py.Py_IncRef(v);
        if (self.exc_traceback) |tb| py.Py_IncRef(tb);
        py.PyErr_Restore(self.exc_type, self.exc_value, self.exc_traceback);
    }

    /// Release the exception references (call when you've handled the exception)
    pub fn deinit(self: *PythonException) void {
        if (self.exc_type) |t| py.Py_DecRef(t);
        if (self.exc_value) |v| py.Py_DecRef(v);
        if (self.exc_traceback) |tb| py.Py_DecRef(tb);
        self.exc_type = null;
        self.exc_value = null;
        self.exc_traceback = null;
    }
};

/// Catch the current Python exception if one is set
/// Returns null if no exception is pending
/// Usage:
///   if (catchException()) |*exc| {
///       defer exc.deinit();
///       if (exc.isValueError()) { ... }
///   }
pub fn catchException() ?PythonException {
    if (py.PyErr_Occurred() == null) {
        return null;
    }

    var exc = PythonException{
        .exc_type = null,
        .exc_value = null,
        .exc_traceback = null,
    };

    py.PyErr_Fetch(&exc.exc_type, &exc.exc_value, &exc.exc_traceback);
    py.PyErr_NormalizeException(&exc.exc_type, &exc.exc_value, &exc.exc_traceback);

    return exc;
}

/// Check if an exception is pending without clearing it
pub fn exceptionPending() bool {
    return py.PyErr_Occurred() != null;
}

/// Clear any pending exception
pub fn clearException() void {
    py.PyErr_Clear();
}

/// Null type, returned by raise functions so you can write:
///   return pyoz.raiseValueError("msg");
pub const Null = @TypeOf(null);

/// Raise a Python exception with a message
pub inline fn raiseException(exc_type: *PyObject, message: anytype) Null {
    fmt_mod.setError(exc_type, message);
    return null;
}

/// Raise a ValueError with a message
pub inline fn raiseValueError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_ValueError(), message);
    return null;
}

/// Raise a TypeError with a message
pub inline fn raiseTypeError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_TypeError(), message);
    return null;
}

/// Raise a RuntimeError with a message
pub inline fn raiseRuntimeError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_RuntimeError(), message);
    return null;
}

/// Raise a KeyError with a message
pub inline fn raiseKeyError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_KeyError(), message);
    return null;
}

/// Raise an IndexError with a message
pub inline fn raiseIndexError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_IndexError(), message);
    return null;
}

/// Raise an AttributeError with a message
pub inline fn raiseAttributeError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_AttributeError(), message);
    return null;
}

/// Raise a MemoryError with a message
pub inline fn raiseMemoryError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_MemoryError(), message);
    return null;
}

/// Raise an OSError with a message
pub inline fn raiseOSError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_OSError(), message);
    return null;
}

/// Raise a NotImplementedError with a message
pub inline fn raiseNotImplementedError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_NotImplementedError(), message);
    return null;
}

/// Raise an OverflowError with a message
pub inline fn raiseOverflowError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_OverflowError(), message);
    return null;
}

/// Raise a ZeroDivisionError with a message
pub inline fn raiseZeroDivisionError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_ZeroDivisionError(), message);
    return null;
}

/// Raise a FileNotFoundError with a message
pub inline fn raiseFileNotFoundError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_FileNotFoundError(), message);
    return null;
}

/// Raise a PermissionError with a message
pub inline fn raisePermissionError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_PermissionError(), message);
    return null;
}

/// Raise a TimeoutError with a message
pub inline fn raiseTimeoutError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_TimeoutError(), message);
    return null;
}

/// Raise a ConnectionError with a message
pub inline fn raiseConnectionError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_ConnectionError(), message);
    return null;
}

/// Raise an EOFError with a message
pub inline fn raiseEOFError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_EOFError(), message);
    return null;
}

/// Raise an ImportError with a message
pub inline fn raiseImportError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_ImportError(), message);
    return null;
}

/// Raise a StopIteration
pub inline fn raiseStopIteration() Null {
    py.PyErr_SetString(py.PyExc_StopIteration(), "");
    return null;
}

/// Raise a SystemError with a message
pub inline fn raiseSystemError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_SystemError(), message);
    return null;
}

/// Raise a BufferError with a message
pub inline fn raiseBufferError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_BufferError(), message);
    return null;
}

/// Raise an ArithmeticError with a message
pub inline fn raiseArithmeticError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_ArithmeticError(), message);
    return null;
}

/// Raise a RecursionError with a message
pub inline fn raiseRecursionError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_RecursionError(), message);
    return null;
}

/// Raise an AssertionError with a message
pub inline fn raiseAssertionError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_AssertionError(), message);
    return null;
}

/// Raise a FloatingPointError with a message
pub inline fn raiseFloatingPointError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_FloatingPointError(), message);
    return null;
}

/// Raise a LookupError with a message
pub inline fn raiseLookupError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_LookupError(), message);
    return null;
}

/// Raise a NameError with a message
pub inline fn raiseNameError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_NameError(), message);
    return null;
}

/// Raise an UnboundLocalError with a message
pub inline fn raiseUnboundLocalError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_UnboundLocalError(), message);
    return null;
}

/// Raise a ReferenceError with a message
pub inline fn raiseReferenceError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_ReferenceError(), message);
    return null;
}

/// Raise a StopAsyncIteration
pub inline fn raiseStopAsyncIteration() Null {
    py.PyErr_SetString(py.PyExc_StopAsyncIteration(), "");
    return null;
}

/// Raise a SyntaxError with a message
pub inline fn raiseSyntaxError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_SyntaxError(), message);
    return null;
}

/// Raise a UnicodeError with a message
pub inline fn raiseUnicodeError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_UnicodeError(), message);
    return null;
}

/// Raise a ModuleNotFoundError with a message
pub inline fn raiseModuleNotFoundError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_ModuleNotFoundError(), message);
    return null;
}

/// Raise a BlockingIOError with a message
pub inline fn raiseBlockingIOError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_BlockingIOError(), message);
    return null;
}

/// Raise a BrokenPipeError with a message
pub inline fn raiseBrokenPipeError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_BrokenPipeError(), message);
    return null;
}

/// Raise a ChildProcessError with a message
pub inline fn raiseChildProcessError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_ChildProcessError(), message);
    return null;
}

/// Raise a ConnectionAbortedError with a message
pub inline fn raiseConnectionAbortedError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_ConnectionAbortedError(), message);
    return null;
}

/// Raise a ConnectionRefusedError with a message
pub inline fn raiseConnectionRefusedError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_ConnectionRefusedError(), message);
    return null;
}

/// Raise a ConnectionResetError with a message
pub inline fn raiseConnectionResetError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_ConnectionResetError(), message);
    return null;
}

/// Raise a FileExistsError with a message
pub inline fn raiseFileExistsError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_FileExistsError(), message);
    return null;
}

/// Raise an InterruptedError with a message
pub inline fn raiseInterruptedError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_InterruptedError(), message);
    return null;
}

/// Raise an IsADirectoryError with a message
pub inline fn raiseIsADirectoryError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_IsADirectoryError(), message);
    return null;
}

/// Raise a NotADirectoryError with a message
pub inline fn raiseNotADirectoryError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_NotADirectoryError(), message);
    return null;
}

/// Raise a ProcessLookupError with a message
pub inline fn raiseProcessLookupError(message: anytype) Null {
    fmt_mod.setError(py.PyExc_ProcessLookupError(), message);
    return null;
}

/// Standard Python exception types for use as bases
pub const PyExc = struct {
    // Base
    pub fn BaseException() *PyObject {
        return py.PyExc_BaseException();
    }
    pub fn Exception() *PyObject {
        return py.PyExc_Exception();
    }
    pub fn GeneratorExit() *PyObject {
        return py.PyExc_GeneratorExit();
    }
    pub fn KeyboardInterrupt() *PyObject {
        return py.PyExc_KeyboardInterrupt();
    }
    pub fn SystemExit() *PyObject {
        return py.PyExc_SystemExit();
    }
    // ArithmeticError hierarchy
    pub fn ArithmeticError() *PyObject {
        return py.PyExc_ArithmeticError();
    }
    pub fn FloatingPointError() *PyObject {
        return py.PyExc_FloatingPointError();
    }
    pub fn OverflowError() *PyObject {
        return py.PyExc_OverflowError();
    }
    pub fn ZeroDivisionError() *PyObject {
        return py.PyExc_ZeroDivisionError();
    }
    // Simple Exception subclasses
    pub fn AssertionError() *PyObject {
        return py.PyExc_AssertionError();
    }
    pub fn AttributeError() *PyObject {
        return py.PyExc_AttributeError();
    }
    pub fn BufferError() *PyObject {
        return py.PyExc_BufferError();
    }
    pub fn EOFError() *PyObject {
        return py.PyExc_EOFError();
    }
    // ImportError hierarchy
    pub fn ImportError() *PyObject {
        return py.PyExc_ImportError();
    }
    pub fn ModuleNotFoundError() *PyObject {
        return py.PyExc_ModuleNotFoundError();
    }
    // LookupError hierarchy
    pub fn LookupError() *PyObject {
        return py.PyExc_LookupError();
    }
    pub fn IndexError() *PyObject {
        return py.PyExc_IndexError();
    }
    pub fn KeyError() *PyObject {
        return py.PyExc_KeyError();
    }
    pub fn MemoryError() *PyObject {
        return py.PyExc_MemoryError();
    }
    // NameError hierarchy
    pub fn NameError() *PyObject {
        return py.PyExc_NameError();
    }
    pub fn UnboundLocalError() *PyObject {
        return py.PyExc_UnboundLocalError();
    }
    // OSError hierarchy
    pub fn OSError() *PyObject {
        return py.PyExc_OSError();
    }
    pub fn BlockingIOError() *PyObject {
        return py.PyExc_BlockingIOError();
    }
    pub fn ChildProcessError() *PyObject {
        return py.PyExc_ChildProcessError();
    }
    pub fn ConnectionError() *PyObject {
        return py.PyExc_ConnectionError();
    }
    pub fn BrokenPipeError() *PyObject {
        return py.PyExc_BrokenPipeError();
    }
    pub fn ConnectionAbortedError() *PyObject {
        return py.PyExc_ConnectionAbortedError();
    }
    pub fn ConnectionRefusedError() *PyObject {
        return py.PyExc_ConnectionRefusedError();
    }
    pub fn ConnectionResetError() *PyObject {
        return py.PyExc_ConnectionResetError();
    }
    pub fn FileExistsError() *PyObject {
        return py.PyExc_FileExistsError();
    }
    pub fn FileNotFoundError() *PyObject {
        return py.PyExc_FileNotFoundError();
    }
    pub fn InterruptedError() *PyObject {
        return py.PyExc_InterruptedError();
    }
    pub fn IsADirectoryError() *PyObject {
        return py.PyExc_IsADirectoryError();
    }
    pub fn NotADirectoryError() *PyObject {
        return py.PyExc_NotADirectoryError();
    }
    pub fn PermissionError() *PyObject {
        return py.PyExc_PermissionError();
    }
    pub fn ProcessLookupError() *PyObject {
        return py.PyExc_ProcessLookupError();
    }
    pub fn TimeoutError() *PyObject {
        return py.PyExc_TimeoutError();
    }
    pub fn ReferenceError() *PyObject {
        return py.PyExc_ReferenceError();
    }
    // RuntimeError hierarchy
    pub fn RuntimeError() *PyObject {
        return py.PyExc_RuntimeError();
    }
    pub fn NotImplementedError() *PyObject {
        return py.PyExc_NotImplementedError();
    }
    pub fn RecursionError() *PyObject {
        return py.PyExc_RecursionError();
    }
    pub fn StopAsyncIteration() *PyObject {
        return py.PyExc_StopAsyncIteration();
    }
    pub fn StopIteration() *PyObject {
        return py.PyExc_StopIteration();
    }
    // SyntaxError hierarchy
    pub fn SyntaxError() *PyObject {
        return py.PyExc_SyntaxError();
    }
    pub fn IndentationError() *PyObject {
        return py.PyExc_IndentationError();
    }
    pub fn TabError() *PyObject {
        return py.PyExc_TabError();
    }
    pub fn SystemError() *PyObject {
        return py.PyExc_SystemError();
    }
    pub fn TypeError() *PyObject {
        return py.PyExc_TypeError();
    }
    // ValueError hierarchy
    pub fn ValueError() *PyObject {
        return py.PyExc_ValueError();
    }
    pub fn UnicodeError() *PyObject {
        return py.PyExc_UnicodeError();
    }
    // Warning hierarchy
    pub fn Warning() *PyObject {
        return py.PyExc_Warning();
    }
    pub fn BytesWarning() *PyObject {
        return py.PyExc_BytesWarning();
    }
    pub fn DeprecationWarning() *PyObject {
        return py.PyExc_DeprecationWarning();
    }
    pub fn FutureWarning() *PyObject {
        return py.PyExc_FutureWarning();
    }
    pub fn ImportWarning() *PyObject {
        return py.PyExc_ImportWarning();
    }
    pub fn PendingDeprecationWarning() *PyObject {
        return py.PyExc_PendingDeprecationWarning();
    }
    pub fn ResourceWarning() *PyObject {
        return py.PyExc_ResourceWarning();
    }
    pub fn RuntimeWarning() *PyObject {
        return py.PyExc_RuntimeWarning();
    }
    pub fn SyntaxWarning() *PyObject {
        return py.PyExc_SyntaxWarning();
    }
    pub fn UnicodeWarning() *PyObject {
        return py.PyExc_UnicodeWarning();
    }
    pub fn UserWarning() *PyObject {
        return py.PyExc_UserWarning();
    }
};

/// Base exception type enum for compile-time specification
pub const ExcBase = enum {
    // BaseException level
    BaseException,
    Exception,
    GeneratorExit,
    KeyboardInterrupt,
    SystemExit,
    // ArithmeticError hierarchy
    ArithmeticError,
    FloatingPointError,
    OverflowError,
    ZeroDivisionError,
    // Simple Exception subclasses
    AssertionError,
    AttributeError,
    BufferError,
    EOFError,
    // ImportError hierarchy
    ImportError,
    ModuleNotFoundError,
    // LookupError hierarchy
    LookupError,
    IndexError,
    KeyError,
    MemoryError,
    // NameError hierarchy
    NameError,
    UnboundLocalError,
    // OSError hierarchy
    OSError,
    BlockingIOError,
    ChildProcessError,
    ConnectionError,
    BrokenPipeError,
    ConnectionAbortedError,
    ConnectionRefusedError,
    ConnectionResetError,
    FileExistsError,
    FileNotFoundError,
    InterruptedError,
    IsADirectoryError,
    NotADirectoryError,
    PermissionError,
    ProcessLookupError,
    TimeoutError,
    ReferenceError,
    // RuntimeError hierarchy
    RuntimeError,
    NotImplementedError,
    RecursionError,
    StopAsyncIteration,
    StopIteration,
    // SyntaxError hierarchy
    SyntaxError,
    IndentationError,
    TabError,
    SystemError,
    TypeError,
    // ValueError hierarchy
    ValueError,
    UnicodeError,
    // Warning hierarchy
    Warning,
    BytesWarning,
    DeprecationWarning,
    FutureWarning,
    ImportWarning,
    PendingDeprecationWarning,
    ResourceWarning,
    RuntimeWarning,
    SyntaxWarning,
    UnicodeWarning,
    UserWarning,

    pub fn toPyObject(self: ExcBase) *PyObject {
        return switch (self) {
            .BaseException => py.PyExc_BaseException(),
            .Exception => py.PyExc_Exception(),
            .GeneratorExit => py.PyExc_GeneratorExit(),
            .KeyboardInterrupt => py.PyExc_KeyboardInterrupt(),
            .SystemExit => py.PyExc_SystemExit(),
            .ArithmeticError => py.PyExc_ArithmeticError(),
            .FloatingPointError => py.PyExc_FloatingPointError(),
            .OverflowError => py.PyExc_OverflowError(),
            .ZeroDivisionError => py.PyExc_ZeroDivisionError(),
            .AssertionError => py.PyExc_AssertionError(),
            .AttributeError => py.PyExc_AttributeError(),
            .BufferError => py.PyExc_BufferError(),
            .EOFError => py.PyExc_EOFError(),
            .ImportError => py.PyExc_ImportError(),
            .ModuleNotFoundError => py.PyExc_ModuleNotFoundError(),
            .LookupError => py.PyExc_LookupError(),
            .IndexError => py.PyExc_IndexError(),
            .KeyError => py.PyExc_KeyError(),
            .MemoryError => py.PyExc_MemoryError(),
            .NameError => py.PyExc_NameError(),
            .UnboundLocalError => py.PyExc_UnboundLocalError(),
            .OSError => py.PyExc_OSError(),
            .BlockingIOError => py.PyExc_BlockingIOError(),
            .ChildProcessError => py.PyExc_ChildProcessError(),
            .ConnectionError => py.PyExc_ConnectionError(),
            .BrokenPipeError => py.PyExc_BrokenPipeError(),
            .ConnectionAbortedError => py.PyExc_ConnectionAbortedError(),
            .ConnectionRefusedError => py.PyExc_ConnectionRefusedError(),
            .ConnectionResetError => py.PyExc_ConnectionResetError(),
            .FileExistsError => py.PyExc_FileExistsError(),
            .FileNotFoundError => py.PyExc_FileNotFoundError(),
            .InterruptedError => py.PyExc_InterruptedError(),
            .IsADirectoryError => py.PyExc_IsADirectoryError(),
            .NotADirectoryError => py.PyExc_NotADirectoryError(),
            .PermissionError => py.PyExc_PermissionError(),
            .ProcessLookupError => py.PyExc_ProcessLookupError(),
            .TimeoutError => py.PyExc_TimeoutError(),
            .ReferenceError => py.PyExc_ReferenceError(),
            .RuntimeError => py.PyExc_RuntimeError(),
            .NotImplementedError => py.PyExc_NotImplementedError(),
            .RecursionError => py.PyExc_RecursionError(),
            .StopAsyncIteration => py.PyExc_StopAsyncIteration(),
            .StopIteration => py.PyExc_StopIteration(),
            .SyntaxError => py.PyExc_SyntaxError(),
            .IndentationError => py.PyExc_IndentationError(),
            .TabError => py.PyExc_TabError(),
            .SystemError => py.PyExc_SystemError(),
            .TypeError => py.PyExc_TypeError(),
            .ValueError => py.PyExc_ValueError(),
            .UnicodeError => py.PyExc_UnicodeError(),
            .Warning => py.PyExc_Warning(),
            .BytesWarning => py.PyExc_BytesWarning(),
            .DeprecationWarning => py.PyExc_DeprecationWarning(),
            .FutureWarning => py.PyExc_FutureWarning(),
            .ImportWarning => py.PyExc_ImportWarning(),
            .PendingDeprecationWarning => py.PyExc_PendingDeprecationWarning(),
            .ResourceWarning => py.PyExc_ResourceWarning(),
            .RuntimeWarning => py.PyExc_RuntimeWarning(),
            .SyntaxWarning => py.PyExc_SyntaxWarning(),
            .UnicodeWarning => py.PyExc_UnicodeWarning(),
            .UserWarning => py.PyExc_UserWarning(),
        };
    }
};

/// Exception definition for the module
pub const ExceptionDef = struct {
    /// Name of the exception (e.g., "MyError")
    name: [*:0]const u8,
    /// Full qualified name (e.g., "mymodule.MyError") - set during module init
    full_name: ?[*:0]const u8 = null,
    /// Base exception type
    base: ExcBase = .Exception,
    /// Documentation string
    doc: ?[*:0]const u8 = null,
    /// Runtime storage for the created exception type
    exception_type: ?*PyObject = null,
};

/// Create an exception definition
/// Supports two syntaxes:
/// - Full options: pyoz.exception("MyError", .{ .doc = "...", .base = .ValueError })
/// - Shorthand:    pyoz.exception("MyError", .ValueError)
pub fn exception(comptime name: [*:0]const u8, comptime opts: anytype) ExceptionDef {
    const OptsType = @TypeOf(opts);
    const type_info = @typeInfo(OptsType);

    // Check if opts is an enum literal (shorthand syntax like .ValueError)
    if (type_info == .enum_literal) {
        const base: ExcBase = opts; // coerce enum literal to ExcBase
        return .{
            .name = name,
            .doc = null,
            .base = base,
        };
    }

    // Check if opts is an ExcBase enum value
    if (OptsType == ExcBase) {
        return .{
            .name = name,
            .doc = null,
            .base = opts,
        };
    }

    // Otherwise expect a struct with optional doc and base fields
    return .{
        .name = name,
        .doc = if (@hasField(OptsType, "doc")) opts.doc else null,
        .base = if (@hasField(OptsType, "base")) opts.base else .Exception,
    };
}

/// Helper to raise a custom exception
pub inline fn raise(exc: *const ExceptionDef, msg: [*:0]const u8) Null {
    if (exc.exception_type) |exc_type| {
        py.PyErr_SetString(exc_type, msg);
    } else {
        // Fallback to RuntimeError if exception wasn't initialized
        py.PyErr_SetString(py.PyExc_RuntimeError(), msg);
    }
    return null;
}
