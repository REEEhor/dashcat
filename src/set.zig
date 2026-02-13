const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const slices = @import("slices.zig");

/// The size of a handle is 64 bits.
/// It consists of 32 bit index into an array and 32 bit generation index.
/// This type used to store generation indexes is okay, since
/// even if at every second, there was 1000 entities created, the game
/// could run for almost 50 days:
///     (2 ** 32) / 1000 / 60 / 60 / 24 = ~ 49.710269629629636 days
pub fn Set(comptime Item: type) type {
    return struct {
        entries: std.ArrayList(Entry),
        free_list_head: ?u32,
        len: usize,
        next_free_generation: Generation,

        pub const Entry = union(enum) {
            free: struct { next_free: ?u32 },
            occupied: struct { generation: Generation, item: Item },
        };

        pub const Generation = packed struct { n: u32 };

        pub const ItemPtr = *Item;

        pub const Handle = packed struct {
            generation: Generation,
            index: u32,

            pub const Set = Self;
            pub const empty_handle: Handle = .{ .generation = .{ .n = 0 }, .index = std.math.maxInt(u32) };
        };

        pub fn init_with_capacity(gpa: Allocator, initial_capacity: usize) Allocator.Error!Self {
            return .{
                .entries = try std.ArrayList(Entry).initCapacity(gpa, initial_capacity),
                .free_list_head = null,
                .len = 0,
                .next_free_generation = Generation{ .n = 1 }, // So that we know that n=0 is always invalid
            };
        }

        pub fn get(self: *Self, handle: Handle) ?*Item {
            if (handle.index >= self.entries.items.len) return null;
            const entry = switch (self.entries.items[handle.index]) {
                .free => return null,
                .occupied => |*entry| entry,
            };
            if (handle.generation != entry.generation) return null;
            return &entry.item;
        }

        pub fn remove(self: *Self, handle: Handle) ?Item {
            if (handle.index >= self.entries.items.len) return null;
            const entry: *Entry = &self.entries.items[handle.index];
            switch (entry.*) {
                .free => return null,
                .occupied => |*occupied| {
                    if (occupied.generation != handle.generation) return null;
                    const remove_item = occupied.item;
                    self.next_free_generation.n += 1;
                    entry.* = .{ .free = .{ .next_free = self.free_list_head } };
                    self.free_list_head = handle.index;
                    self.len -= 1;
                    return remove_item;
                },
            }
        }

        pub fn add_with_pointer(
            self: *Self,
            gpa: Allocator,
            item: Item,
        ) Allocator.Error!struct { handle: Handle, ptr: *Item } {
            const generation = self.next_free_generation;
            self.next_free_generation.n += 1;

            const free_entry: *Entry = blk: {
                if (self.free_list_head) |free_index| {
                    // SAFETY: `self.free_list_head` should always point to a `free` item
                    self.free_list_head = self.entries.items[free_index].free.next_free;
                    break :blk &self.entries.items[free_index];
                } else {
                    // The free list is empty, we have to append the item into the list
                    break :blk try self.entries.addOne(gpa);
                }
            };
            free_entry.* = .{ .occupied = .{ .generation = generation, .item = item } };
            const new_item_ptr: *Item = &free_entry.*.occupied.item;

            self.len += 1;

            return .{
                .handle = Handle{
                    .generation = generation,
                    .index = @intCast(slices.index_from_pointer(free_entry, self.entries.items).?),
                },
                .ptr = new_item_ptr,
            };
        }

        pub fn add(self: *Self, gpa: Allocator, item: Item) Allocator.Error!Handle {
            return (try self.add_with_pointer(gpa, item)).handle;
        }

        pub fn iterator(self: *Self) Iterator {
            return .{ .set = self };
        }

        pub const Iterator = struct {
            set: *Self,
            _index: usize = 0,

            pub fn next(self: *Iterator) ?struct { *Item, Handle } {
                while (true) {
                    if (self._index >= self.set.entries.items.len) return null;
                    defer self._index += 1;
                    switch (self.set.entries.items[self._index]) {
                        .free => {},
                        .occupied => |*occupied| return .{
                            &occupied.item, Handle{
                                .generation = occupied.generation,
                                .index = @intCast(self._index),
                            },
                        },
                    }
                }
            }
        };

        const Self = @This();

        pub fn debug_print(self: *Self) void {
            for (self.entries.items, 0..) |e, i| {
                switch (e) {
                    .free => std.debug.print(" (FREE {d})", .{i}),
                    .occupied => |o| std.debug.print(" [{d} g:{d}]", .{ i, o.generation.n }),
                }
            }
            std.debug.print("\n", .{});
        }
    };
}

test "basic operations" {
    const gpa = std.testing.allocator;
    var set = try Set(i32).init_with_capacity(gpa, 10);
    defer set.entries.deinit(gpa);

    assert(set.len == 0);
    assert(set.remove(.empty_handle) == null);
    assert(set.get(.empty_handle) == null);

    {
        const item10 = try set.add_with_pointer(gpa, 10);
        assert(set.len == 1);
        assert(set.get(item10.handle).?.* == 10);
        assert(set.remove(item10.handle).? == 10);
        assert(set.len == 0);
    }

    {
        const item10 = try set.add_with_pointer(gpa, 10);
        assert(set.get(item10.handle).?.* == 10);
        assert(set.len == 1);
        const item20 = try set.add_with_pointer(gpa, 20);
        assert(set.get(item20.handle).?.* == 20);
        assert(set.len == 2);

        assert(set.remove(item10.handle).? == 10);
        assert(set.len == 1);
        assert(set.remove(item10.handle) == null);
        assert(set.remove(.empty_handle) == null);
        assert(set.remove(item20.handle).? == 20);
        assert(set.remove(item20.handle) == null);
        assert(set.len == 0);
    }
    {
        _ = try set.add_with_pointer(gpa, 10);
        const item20 = try set.add_with_pointer(gpa, 20);
        _ = try set.add_with_pointer(gpa, 30);
        var it = set.iterator();
        var buffer: [3]i32 = undefined;
        buffer[0] = it.next().?.@"0".*;
        buffer[1] = it.next().?.@"0".*;
        buffer[2] = it.next().?.@"0".*;
        assert(it.next() == null);
        assert(it.next() == null);
        assert(it.next() == null);

        std.sort.pdq(i32, &buffer, {}, struct {
            fn f(_: void, a: i32, b: i32) bool {
                return a < b;
            }
        }.f);

        assert(buffer[0] == 10);
        assert(buffer[1] == 20);
        assert(buffer[2] == 30);

        assert(set.remove(item20.handle).? == 20);
        it = set.iterator();

        buffer[0] = it.next().?.@"0".*;
        buffer[1] = it.next().?.@"0".*;
        assert(it.next() == null);
        assert(it.next() == null);
        assert(it.next() == null);

        if (buffer[0] > buffer[1]) std.mem.swap(i32, &buffer[0], &buffer[1]);
        assert(buffer[0] == 10);
        assert(buffer[1] == 30);
    }
}

test "big insert and removal test" {
    const gpa = std.testing.allocator;
    var set = try Set(usize).init_with_capacity(gpa, 10);
    defer set.entries.deinit(gpa);

    {
        const len = 100;
        var handles: [len]Set(usize).Handle = undefined;

        for (0..len) |item| {
            handles[item] = try set.add(gpa, item);
        }

        assert(set.remove(handles[1]).? == 1);
        // assert(set.remove(handles[80]).? == 80);

        var check: [len]bool = undefined;
        @memset(&check, false);

        var it = set.iterator();
        while (it.next()) |entry| {
            if (set.get(entry.@"1") == null) {
                std.debug.print("{d}\n", .{entry.@"0".*});
                return error.test_failed;
            }
        }
    }
}
