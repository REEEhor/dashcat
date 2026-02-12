const std = @import("std");
const assert = std.debug.assert;

pub fn last_ptr(slice: anytype) *(@typeInfo(@TypeOf(slice)).pointer.child) {
    assert(slice.len != 0);
    return &slice[slice.len - 1];
}

pub fn last_ptr_or_null(slice: anytype) *(@typeInfo(@TypeOf(slice)).pointer.child) {
    if (slice.len == 0) return null;
    return &slice[slice.len - 1];
}
