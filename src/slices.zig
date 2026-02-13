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

pub fn index_from_pointer(ptr_to_item: anytype, slice: anytype) ?usize {
    comptime assert(@typeInfo(@TypeOf(slice)).pointer.size == .slice);
    comptime assert(@typeInfo(@TypeOf(slice)).pointer.child == @typeInfo(@TypeOf(ptr_to_item)).pointer.child);

    const min: usize = @intFromPtr(slice.ptr);
    const max: usize = @intFromPtr(slice.ptr + slice.len);
    const value: usize = @intFromPtr(ptr_to_item);

    const check = (min <= value) and (value < max);
    if (!check) return null;

    return ptr_to_item - slice.ptr;
}
