const DEBUG = false;
comptime {
    @setFloatMode(.optimized); // >:) (this will surely not bite us later)
}

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArenaAllocator = std.heap.ArenaAllocator;
const eql = std.meta.eql;

const slices = @import("slices.zig");

const rl = @import("raylib");

const Vector2 = rl.Vector2;
const Vector3 = rl.Vector3;
const Vector4 = rl.Vector4;
const Color = rl.Color;

const pi = 3.14159265358979;

pub fn cap_0_1(x: f32) f32 {
    if (x < 0) return 0;
    if (x > 1) return 1;
    return x;
}

pub const Position = struct {
    x: i32,
    y: i32,

    const Self = @This();
    pub fn add(self: Self, direction: Direction) Self {
        var result = self;
        switch (direction) {
            .up => result.y -= 1,
            .left => result.x -= 1,
            .down => result.y += 1,
            .right => result.x += 1,
        }
        return result;
    }
};

pub const Timestamp = struct {
    seconds_from_beginning: f64,

    const Self = @This();
    pub fn is_before(self: Self, rhs: Timestamp) bool {
        return self.seconds_from_beginning < rhs.seconds_from_beginning;
    }

    pub fn duration_to(self: Self, final: Timestamp) Duration {
        return Duration{
            ._seconds = @floatCast(final.seconds_from_beginning - self.seconds_from_beginning),
        };
    }

    pub fn plus_duration(self: Self, to_add: Duration) Timestamp {
        return Timestamp{
            .seconds_from_beginning = self.seconds_from_beginning + to_add._seconds,
        };
    }

    pub fn timer_that_goes_off_in(self: Self, duration: Duration) Timer {
        return Timer.init(.{
            .current_time = self,
            .total_duration = duration,
        });
    }
};

pub const Duration = struct {
    _seconds: f32,

    const Self = @This();

    pub fn seconds(secs: f32) Duration {
        return .{ ._seconds = secs };
    }
};

pub const Timer = struct {
    start: Timestamp,
    end: Timestamp,

    const Self = @This();

    pub fn init(params: struct { current_time: Timestamp, total_duration: Duration }) Timer {
        return .{
            .start = params.current_time,
            .end = params.current_time.plus_duration(params.total_duration),
        };
    }

    pub fn finished(self: Self, current_time: Timestamp) bool {
        return self.end.is_before(current_time);
    }

    pub fn planned_total_duration(self: Self) Duration {
        return self.start.duration_to(self.end);
    }

    pub fn progress_from_0_to_1(self: Self, current_time: Timestamp) f32 {
        const actual_seconds = self.start.duration_to(current_time)._seconds;
        const total_seconds = self.planned_total_duration()._seconds;
        return actual_seconds / total_seconds;
    }

    pub fn prolonged_by(self: Self, add: Duration) Timer {
        return Timer{
            .start = self.start,
            .end = self.end.plus_duration(add),
        };
    }
};

pub const Health = struct {
    points: i32,

    const Self = @This();

    pub const indestructible = null;
    pub const zero = Health{ .points = 0 };

    pub fn add_mut(self: *Self, other: Health) void {
        self.points += other.points;
    }
    pub fn sub_mut(self: *Self, other: Health) Health {
        const original_points = self.points;
        self.points -= other.points;
        if (self.points < 0) self.points = 0;
        return .{ .points = original_points - self.points };
    }
    pub fn means_dead(self: Self) bool {
        return self.points <= 0;
    }
    pub const is_zero = means_dead;
};

pub const Entity = struct {
    /// `null` means indestructible
    health: ?Health,
    position: Position,
    type: Type,

    const Self = @This();
    pub fn deal_damage(self: *Self, damage: Health) struct { is_dead: bool } {
        if (self.health) |*health| {
            health.sub_mut(damage);
            return .{ .is_dead = health.means_dead() };
        }
        return false;
    }

    pub fn is_passable(self: Self) bool {
        return switch (self.type) {
            .modifier_pickup => true,
            //
            .cat => false,
            .wall => false,
            .bomb => false,
        };
    }

    pub const Type = union(enum) {
        cat: Set(Cat).Handle,
        bomb: Set(Bomb).Handle,
        wall,
        modifier_pickup: Set(ModifierPickup).Handle,

        pub const Tag = std.meta.Tag(@This());
        pub fn tag(self: Type) Tag {
            return std.meta.activeTag(self);
        }
    };
};

pub const Cat = struct {
    entity: EntityHandle,
    controlling_player: ?*Player,
    color: rl.Color,
    wanted_direction: ?Direction,

    // TODO: put effects here
};

pub const Bomb = struct {
    entity: EntityHandle,
    damage: Health,
    blast_radius_in_tiles: i32,
    timer_till_explosion: Timer,

    pub const Properties = struct {
        starting_health: ?Health,
        damage: Health,
        blast_radius_in_tiles: i32,
        time_to_detonate: Duration,
    };
};

/// NOTE: So far it is only a fire effect
pub const ModifierPickup = struct {
    entity: EntityHandle = undefined,
    damage: Health,
    texture: rl.Texture,
    timer_till_disappear: Timer,
};

pub const Direction = enum {
    up,
    left,
    down,
    right,
};

pub const Controls = struct {
    up: rl.KeyboardKey,
    left: rl.KeyboardKey,
    down: rl.KeyboardKey,
    right: rl.KeyboardKey,
    spawn_bomb: rl.KeyboardKey,
};

pub const Player = struct {
    cat: Set(Cat).Handle,
    controls: Controls,
    bomb_creation_properties: Bomb.Properties,
};

pub fn FixedArray(comptime Item: type) type {
    return struct {
        capacity: usize,
        items: []Item,

        const Self = @This();

        pub fn init(buffer: []Item) Self {
            var items = buffer;
            items.len = 0;
            return .{ .capacity = buffer.len, .items = items };
        }

        pub fn try_append(self: *Self, item: Item) struct { ok: bool } {
            if (self.capacity == self.items.len) {
                return .{ .ok = false };
            }
            self.items.len += 1;
            self.items[self.items.len - 1] = item;
            return .{ .ok = true };
        }

        pub fn append_assert_ok(self: *Self, item: Item) void {
            assert(self.try_append(item).ok);
        }

        pub fn len(self: Self) usize {
            return self.items.len;
        }

        pub fn last(self: Self) *Item {
            return &self.items[self.len() - 1];
        }

        pub fn is_empty(self: Self) bool {
            return self.items.len == 0;
        }

        pub fn non_empty(self: Self) bool {
            return self.items.len != 0;
        }

        pub fn swap_remove_at(self: *Self, at_index: usize) Item {
            const result = self.items[at_index];
            if (self.len() == at_index + 1) {
                self.items.len -= 1;
                return result;
            }
            std.mem.swap(Item, &self.items[at_index], self.last());
            self.items.len -= 1;
            return result;
        }

        pub fn swap_remove(self: *Self, item: Item) struct { was_found_and_removed: bool } {
            const index = for (self.items, 0..) |i, index| {
                if (i == item) break index;
            } else return .{ .was_found_and_removed = false };

            _ = self.swap_remove_at(index);
            return .{ .was_found_and_removed = true };
        }
    };
}

pub const Grid = struct {
    width: i32,
    height: i32,
    depth: usize,
    all_items: []Handle,
    tiles: []Tile,

    pub const Handle = EntityHandle;
    pub const Tile = FixedArray(Handle);

    const Self = @This();
    pub fn init(gpa: Allocator, width: i32, height: i32, depth: usize) Allocator.Error!Self {
        const all_items = try gpa.alloc(Handle, as(usize, width * height) * depth);
        const tiles = try gpa.alloc(Tile, @intCast(width * height));

        for (tiles, 0..) |*tile, index| {
            const start = index * depth;
            const buffer = all_items[start .. start + depth];
            tile.* = Tile.init(buffer);
        }

        return Self{
            .width = width,
            .height = height,
            .depth = depth,
            .all_items = all_items,
            .tiles = tiles,
        };
    }

    pub fn index_from_position(self: Self, position: Position) usize {
        if (position.x < 0 or position.x >= self.width) {
            @branchHint(.cold);
            std.debug.panic(
                "Grid.at(x={d}, y={d}): X is out of bounds for Grid(width={d}, height={d})",
                .{ position.x, position.y, self.width, self.height },
            );
        }
        if (position.y < 0 or position.y >= self.height) {
            @branchHint(.cold);
            std.debug.panic(
                "Grid.at(x={d}, y={d}): Y is out of bounds for Grid(width={d}, height={d})",
                .{ position.x, position.y, self.width, self.height },
            );
        }
        return as(usize, position.y * self.width + position.x);
    }

    pub fn at(self: *Self, position: Position) *Tile {
        const index = self.index_from_position(position);
        return &self.tiles[@intCast(index)];
    }

    pub fn at_or_null(self: *Self, position: Position) ?*Tile {
        const index = position.y * self.width + position.x;
        if (index >= self.tiles.len) return null;
        return &self.tiles[@intCast(index)];
    }

    pub fn iterator(self: *Self) TilesIterator {
        return .{ .current_position = .{ .x = 0, .y = 0 }, .grid = self };
    }

    pub const TilesIterator = struct {
        grid: *Grid,
        current_position: Position,

        pub fn next(self: *TilesIterator) ?struct { tile: *Tile, position: Position } {
            const tile = self.grid.at_or_null(self.current_position) orelse return null;
            const position = self.current_position;
            self.current_position.x += 1;
            if (self.current_position.x == self.grid.width) {
                self.current_position.x = 0;
                self.current_position.y += 1;
            }
            return .{ .tile = tile, .position = position };
        }
    };
};

pub inline fn as(comptime Out: type, number: anytype) Out {
    switch (@typeInfo(Out)) {
        .int => |int| assert(int.signedness != .unsigned or number >= 0),
        else => {},
    }
    return std.math.lossyCast(Out, number);
}

pub const Screen = struct {
    width: f32,
    height: f32,
};

fn map(x: f32, in_min: f32, in_max: f32, out_min: f32, out_max: f32) f32 {
    var value = x;
    const in_range = in_max - in_min;

    value -= in_min; // Value is in [0..in_range]
    value /= in_range; // Value is in [0..1]

    // Do lerp
    value = out_min + value * (out_max - out_min);
    return value;
}

pub const GameView = struct {
    const Self = @This();

    const Spec = struct {
        min_x: f32,
        max_x: f32,
        min_y: f32,
        max_y: f32,

        pub fn x_span(self: @This()) f32 {
            return self.max_x - self.min_x;
        }

        pub fn y_span(self: @This()) f32 {
            return self.max_y - self.min_y;
        }
    };

    on_screen: Spec,
    in_game: Spec,

    pub fn screen_coordinates_from_position(self: Self, position: Position) Vector2 {
        // zig fmt: off
        var x: f32 = @floatFromInt(position.x);
        x = map(
            x,
            self.in_game.min_x, self.in_game.max_x,
            self.on_screen.min_x, self.on_screen.max_x,
        );
        var y: f32 = @floatFromInt(position.y);
        y = map(
            y,
            self.in_game.min_y, self.in_game.max_y,
            self.on_screen.min_y, self.on_screen.max_y,
        );
        return .init(x, y);
        // zig fmt: on
    }

    pub fn scale_to_screen(self: Self, length_in_game: f32) f32 {
        // HACK
        return map(length_in_game, 0, self.in_game.x_span(), 0, self.on_screen.x_span());
    }
};

pub const EntityHandle = Set(Entity).Handle;

//                    0 1 2 3 4 5
// (idx) item_idx:    2 4 5 1 3 0
// (idx) handle_idx:  5 3 0 4 1 2
//           items:   a b c d e f
//                    0 1 2 3 4 5

//                    0 1 2 3 4 5
// (idx) item_idx:    2 4 5 1 3 0
// (idx) handle_idx:  5 3 0 4 1 2
//           items:   a b f d e f
//                    0 1 5 3 4 5
//                        ^

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
            if (handle.index >= self.len) return null;
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
                    .index = as(u32, index_from_pointer(free_entry, self.entries.items).?),
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
    };
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

pub const GameState = struct {
    gpa: Allocator,

    entities: Set(Entity),
    cats: Set(Cat),
    bombs: Set(Bomb),
    modifier_pickups: Set(ModifierPickup),

    visual_effects: Set(VisualEffect),

    grid: Grid,

    random: std.Random,

    const Self = @This();

    pub fn get(self: *Self, handle: anytype) ?@TypeOf(handle).Set.ItemPtr {
        return switch (@TypeOf(handle)) {
            EntityHandle => self.entities.get(handle),
            Set(Cat).Handle => self.cats.get(handle),
            Set(Bomb).Handle => self.bombs.get(handle),
            Set(ModifierPickup).Handle => self.modifier_pickups.get(handle),
            else => |Invalid| @compileError(std.fmt.comptimePrint(
                "Invalid handle type: {s}",
                .{@typeName(Invalid)},
            )),
        };
    }

    pub fn is_indestructible_wall_at(self: *Self, position: Position) bool {
        for (self.grid.at(position).items) |handle| {
            const entity = self.entities.get(handle).?;
            if (entity.type.tag() == .wall and entity.health == null) {
                return true;
            }
        }
        return false;
    }

    pub fn is_passable_at(self: *Self, position: Position) bool {
        for (self.grid.at(position).items) |handle| {
            const entity = self.entities.get(handle).?;
            if (!entity.is_passable()) {
                return false;
            }
        }
        return true;
    }

    pub fn deal_damage_at(self: *Self, position: Position, damage: Health, skip: EntityHandle) struct { damage_dealt: Health } {
        var total_damage = Health.zero;
        for (self.grid.at(position).items) |entity_handle| {
            if (entity_handle == skip) continue;
            const entity: *Entity = self.get(entity_handle) orelse continue;
            const health = &(entity.health orelse continue);
            total_damage.add_mut(health.sub_mut(damage));
            if (health.means_dead()) {
                assert(self.remove_entity(entity_handle).removal_sucessful);
            }
        }
        return .{ .damage_dealt = total_damage };
    }

    pub fn remove_entity(self: *Self, entity_handle: EntityHandle) struct { removal_sucessful: bool } {
        const entity: *Entity = self.entities.get(entity_handle) orelse return .{ .removal_sucessful = false };
        assert(self.grid.at(entity.position).swap_remove(entity_handle).was_found_and_removed);
        switch (entity.type) {
            .cat => |cat_handle| {
                const cat = self.cats.remove(cat_handle).?;
                if (cat.controlling_player) |player| {
                    player.cat = .empty_handle;
                }
            },
            .bomb => |bomb_handle| {
                const bomb = self.bombs.remove(bomb_handle).?;
                _ = bomb;
            },
            .modifier_pickup => |modifier_pickup_handle| {
                const modifier_pickup = self.modifier_pickups.remove(modifier_pickup_handle).?;
                _ = modifier_pickup;
            },
            .wall => {},
        }
        return .{ .removal_sucessful = true };
    }

    pub fn move_assert_ok(self: *Self, entity_handle: EntityHandle, to: Position) void {
        const entity = self.entities.get(entity_handle) orelse return;
        const old_position = entity.position;
        const new_position = to;
        entity.position = new_position;
        assert(self.grid.at(old_position).swap_remove(entity_handle).was_found_and_removed);
        self.grid.at(new_position).append_assert_ok(entity_handle);
    }

    pub fn CreateResult(comptime T: type) type {
        return struct {
            ptr: *T,
            entity_ptr: *Entity,
            entity_handle: EntityHandle,
            handle: Set(T).Handle,
        };
    }

    pub const CreateOption = enum {
        /// Return all things (`ptr`, `entity_ptr`, `handle`, `entity_handle`)
        all,
        /// Return just the handle
        handle,
    };

    // pub fn remove_entity(self: *Self, entity: *Entity) void {
    //     const entity_index: usize = index_from_pointer(entity, self.entities.items) orelse std.debug.panic("Invalid pointer!", .{});
    //     switch (entity.type) {
    //         .cat => |cat| {
    //             // self.cats.swapRemove()
    //         },
    //         .bomb => |bomb| bomb.as_entity = new_entity_ptr,
    //         .wall => {},
    //         .modifier_pickup => |modifier_pickup| modifier_pickup.as_entity = new_entity_ptr,
    //     }
    //     if (entity_index != self.entities.items.len) {
    //         const swapped_entity: *Entity = slices.last_ptr(self.entities.items);
    //         const new_entity_ptr: *Entity = &self.entities.items[entity_index];
    //         switch (swapped_entity.type) {
    //             .cat => |cat| cat.as_entity = new_entity_ptr,
    //             .bomb => |bomb| bomb.as_entity = new_entity_ptr,
    //             .wall => {},
    //             .modifier_pickup => |modifier_pickup| modifier_pickup.as_entity = new_entity_ptr,
    //         }
    //     }
    // }

    pub const CreateCatParams = struct {
        controlling_player: ?*Player,
        starting_health: Health,
        position: Position,
        color: rl.Color,
    };
    pub fn create_cat(self: *Self, params: CreateCatParams) Allocator.Error!Set(Cat).Handle {
        return (try self.create_cat_all(params)).handle;
    }
    pub fn create_cat_all(
        self: *Self,
        params: CreateCatParams,
    ) Allocator.Error!CreateResult(Cat) {
        const entity_entry = try self.entities.add_with_pointer(self.gpa, .{
            .health = params.starting_health,
            .position = params.position,
            .type = undefined,
        });
        const cat_entry = try self.cats.add_with_pointer(self.gpa, .{
            .entity = entity_entry.handle,
            .color = params.color,
            .controlling_player = params.controlling_player,
            .wanted_direction = null,
        });
        entity_entry.ptr.type = .{ .cat = cat_entry.handle };
        if (params.controlling_player) |controlling_player| {
            controlling_player.cat = cat_entry.handle;
        }
        assert(self.grid.at(params.position).try_append(entity_entry.handle).ok);
        return .{
            .ptr = cat_entry.ptr,
            .handle = cat_entry.handle,
            .entity_ptr = entity_entry.ptr,
            .entity_handle = entity_entry.handle,
        };
    }

    pub const CreateBombParams = struct {
        position: Position,
        current_time: Timestamp,
        properties: Bomb.Properties,
    };
    pub fn create_bomb(self: *Self, params: CreateBombParams) Allocator.Error!Set(Bomb).Handle {
        return (try self.create_bomb_all(params)).handle;
    }
    pub fn create_bomb_all(self: *Self, params: CreateBombParams) Allocator.Error!CreateResult(Bomb) {
        const entity_entry = try self.entities.add_with_pointer(self.gpa, .{
            .health = params.properties.starting_health,
            .position = params.position,
            .type = undefined,
        });
        const bomb_entry = try self.bombs.add_with_pointer(self.gpa, .{
            .entity = entity_entry.handle,
            .damage = params.properties.damage,
            .blast_radius_in_tiles = params.properties.blast_radius_in_tiles,
            .timer_till_explosion = params.current_time.timer_that_goes_off_in(params.properties.time_to_detonate),
        });
        entity_entry.ptr.type = .{ .bomb = bomb_entry.handle };
        assert(self.grid.at(params.position).try_append(entity_entry.handle).ok);
        return .{
            .ptr = bomb_entry.ptr,
            .handle = bomb_entry.handle,
            .entity_ptr = entity_entry.ptr,
            .entity_handle = entity_entry.handle,
        };
    }

    pub const CreateWallParams = struct {
        health: ?Health,
        position: Position,
    };
    pub fn create_wall_all(self: *Self, params: CreateWallParams) Allocator.Error!CreateResult(Entity) {
        const wall = try self.entities.add_with_pointer(self.gpa, .{
            .health = params.health,
            .position = params.position,
            .type = .wall,
        });
        assert(self.grid.at(params.position).try_append(wall.handle).ok);
        return .{
            .ptr = wall.ptr,
            .handle = wall.handle,
            .entity_ptr = wall.ptr,
            .entity_handle = wall.handle,
        };
    }

    pub const CreateEffectPickupParams = struct {
        modifier_pickup: ModifierPickup,
        position: Position,
        health: ?Health = Health.indestructible,
    };
    pub fn create_modifier_pickup_all(self: *Self, params: CreateEffectPickupParams) Allocator.Error!CreateResult(ModifierPickup) {
        const entity = try self.entities.add_with_pointer(self.gpa, .{
            .health = params.health,
            .position = params.position,
            .type = undefined,
        });
        const modifier_pickup = try self.modifier_pickups.add_with_pointer(self.gpa, params.modifier_pickup);
        entity.ptr.type = .{ .modifier_pickup = modifier_pickup.handle };
        modifier_pickup.ptr.entity = entity.handle;
        self.grid.at(params.position).append_assert_ok(entity.handle);
        return .{
            .ptr = modifier_pickup.ptr,
            .handle = modifier_pickup.handle,
            .entity_ptr = entity.ptr,
            .entity_handle = entity.handle,
        };
    }

    pub fn create_visual_effect(self: *Self, effect: VisualEffect) Allocator.Error!Set(VisualEffect).Handle {
        return try self.visual_effects.add(self.gpa, effect);
    }
};

pub const VisualEffect = struct {
    /// `null` means indefinite
    timer_till_disappear: ?Timer,
    position: Position,
    type: Type,
    pub const Type = union(enum) {
        after_dash: struct { intensity_percentile: i8 = 100 },
        fire,

        const Self = @This();
        pub const Tag = std.meta.Tag(Self);
        pub fn tag(self: Self) Tag {
            return std.meta.activeTag(self);
        }
    };
};

// pub fn draw_progress_bar(coords: Vector2, progress: f32) void {

// }

pub fn main() anyerror!void {
    // Initialization
    //--------------------------------------------------------------------------------------

    const screen = Screen{
        .height = 800,
        .width = 800,
    };

    var _gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const gpa = _gpa.allocator();

    var static_arena = ArenaAllocator.init(gpa);
    defer static_arena.deinit();

    var round_arena = ArenaAllocator.init(gpa);
    defer round_arena.deinit();

    var frame_arena = ArenaAllocator.init(gpa);
    defer frame_arena.deinit();

    rl.initWindow(screen.width, screen.height, "Dash Cat");
    defer rl.closeWindow(); // Close window and OpenGL context

    var pause: bool = false;
    var framesCounter: i32 = 0;

    var grid = try Grid.init(round_arena.allocator(), 20, 20, 20);
    const game_view = GameView{
        .in_game = .{ .min_x = 0, .min_y = 0, .max_x = @floatFromInt(grid.width), .max_y = @floatFromInt(grid.height) },
        .on_screen = .{ .min_x = 10, .min_y = 10, .max_x = 800 - 20, .max_y = 800 - 20 },
    };

    const cat_texture = blk: {
        var image = try rl.loadImage("assets/cat.png");
        const new_side_length: i32 = @intFromFloat(game_view.scale_to_screen(1));
        image.resize(new_side_length, new_side_length);
        break :blk try rl.Texture.fromImage(image);
    };
    const bomb_texture = blk: {
        var image = try rl.loadImage("assets/bomb.png");
        const new_side_length: i32 = @intFromFloat(game_view.scale_to_screen(1));
        image.resize(new_side_length, new_side_length);
        break :blk try rl.Texture.fromImage(image);
    };
    const fire_texture = blk: {
        var image = try rl.loadImage("assets/fire1.png");
        const new_side_length: i32 = @intFromFloat(game_view.scale_to_screen(1));
        image.resize(new_side_length, new_side_length);
        break :blk try rl.Texture.fromImage(image);
    };
    const game_map =
        //01234567890123456789
        \\wwwwwwwwwwwwwwwwwwww
        \\w          wwwwwwwww
        \\w   ww           www
        \\w          wwwww www
        \\w                  w
        \\w  w    w          w
        \\w       w          w
        \\w       w          w
        \\w       w          w
        \\w     wwwwwwww     w
        \\w       w          w
        \\w       w          w
        \\w  w               w
        \\w        w    ww www
        \\w             ww www
        \\w             ww www
        \\w             ww www
        \\ww           www www
        \\ww               www
        \\wwwwwwwwwwwwwwwwwwww
    ;

    var prng = std.Random.DefaultPrng.init(42);
    var state = GameState{
        .gpa = round_arena.allocator(),
        .bombs = try .init_with_capacity(round_arena.allocator(), 0),
        .cats = try .init_with_capacity(round_arena.allocator(), 0),
        .entities = try .init_with_capacity(round_arena.allocator(), 0),
        .modifier_pickups = try .init_with_capacity(round_arena.allocator(), 0),
        .visual_effects = try .init_with_capacity(round_arena.allocator(), 0),
        .grid = grid,
        .random = prng.random(),
    };

    for (0..@intCast(grid.height)) |y| {
        for (0..@intCast(grid.width)) |x| {
            const width: usize = @intCast(grid.width);
            const map_index: usize = y * (width + 1) + x;
            const char = game_map[map_index];
            std.debug.print("{c}", .{char});
            if (char == 'w') {
                _ = try state.create_wall_all(.{
                    .position = .{ .x = as(i32, x), .y = as(i32, y) },
                    .health = .indestructible,
                });
            }
        }
        std.debug.print("\n", .{});
    }

    var _players_buffer: [10]Player = undefined;
    var players = ArrayList(Player).initBuffer(&_players_buffer);
    players.appendAssumeCapacity(.{
        .cat = .empty_handle,
        .controls = Controls{ .up = .w, .left = .a, .down = .s, .right = .d, .spawn_bomb = .space },
        .bomb_creation_properties = Bomb.Properties{
            .blast_radius_in_tiles = 2,
            .damage = Health{ .points = 5 },
            .starting_health = Health.indestructible,
            .time_to_detonate = Duration.seconds(4),
        },
    });
    const player_cat = try state.create_cat(.{
        .color = Color.red.brightness(0.8),
        .controlling_player = &players.items[0],
        .position = .{ .x = 1, .y = 5 },
        .starting_health = Health{ .points = 15 },
    });
    players.items[0].cat = player_cat;

    rl.setTargetFPS(60);
    //--------------------------------------------------------------------------------------

    var thicness: f32 = 0.1;

    // Main game loop
    while (!rl.windowShouldClose()) { // Detect window close button or ESC key
        const current_time = Timestamp{ .seconds_from_beginning = rl.getTime() };
        defer std.debug.assert(frame_arena.reset(.retain_capacity));

        // Update
        //----------------------------------------------------------------------------------
        if (rl.isKeyPressed(.p)) {
            pause = !pause;
        }

        thicness += rl.getMouseWheelMove() / 100;

        if (!pause) {
            // Update players
            for (players.items) |*player| {
                const cat = state.cats.get(player.cat) orelse continue;
                const cat_position = state.get(cat.entity).?.position;
                if (rl.isKeyPressed(player.controls.up)) cat.wanted_direction = .up;
                if (rl.isKeyPressed(player.controls.left)) cat.wanted_direction = .left;
                if (rl.isKeyPressed(player.controls.right)) cat.wanted_direction = .right;
                if (rl.isKeyPressed(player.controls.down)) cat.wanted_direction = .down;
                if (rl.isKeyPressed(player.controls.spawn_bomb)) {
                    const no_other_bomb = for (state.grid.at(cat_position).items) |entity| {
                        if (state.get(entity).?.type.tag() == .bomb) break false;
                    } else true;
                    if (no_other_bomb) {
                        _ = try state.create_bomb(.{
                            .current_time = current_time,
                            .position = cat_position,
                            .properties = player.bomb_creation_properties,
                        });
                    }
                }
            }

            // Update cats
            var it_cats = state.cats.iterator();
            while (it_cats.next()) |entry| {
                const cat, _ = entry;
                const cat_entity: *Entity = state.get(cat.entity).?;
                defer cat.wanted_direction = null;
                const wanted_direction = cat.wanted_direction orelse continue;

                const original_position = cat_entity.position;
                var final_position = original_position;
                search: while (true) {
                    const next_position = final_position.add(wanted_direction);
                    for (state.grid.at(next_position).items) |another_entity_handle| {
                        _ = another_entity_handle;
                        // FIXME: actually pickup the effect
                        // if (another_entity.type.tag() != .modifier_pickup) break;
                        break :search;
                    }
                    final_position = next_position;
                }
                if (!eql(original_position, final_position)) {
                    state.move_assert_ok(cat.entity, final_position);
                }
            }

            // Update bombs
            var it_bombs = state.bombs.iterator();
            while (it_bombs.next()) |entry| {
                const bomb_ptr, _ = entry;
                if (!bomb_ptr.timer_till_explosion.finished(current_time)) continue;
                const bomb = bomb_ptr; // Copy the bomb
                const bomb_entity: *Entity = state.get(bomb.entity).?;

                var starting_damage = bomb.damage;
                _ = starting_damage.sub_mut(state.deal_damage_at(bomb_entity.position, bomb.damage, bomb.entity).damage_dealt);

                const base_effect_timer = current_time.timer_that_goes_off_in(.seconds(0.3));
                _ = try state.create_visual_effect(VisualEffect{
                    .position = bomb_entity.position,
                    .timer_till_disappear = base_effect_timer.prolonged_by(.seconds(state.random.float(f32) * 0.1)),
                    .type = .fire,
                });

                directions: for (&[_]Direction{ .up, .left, .down, .right }) |direction| {
                    var position = bomb_entity.position;
                    var damage_to_deal = starting_damage;
                    for (0..as(usize, bomb.blast_radius_in_tiles)) |_| {
                        if (damage_to_deal.is_zero()) continue :directions;
                        position = position.add(direction);
                        const damage_dealt = state.deal_damage_at(position, bomb.damage, .empty_handle).damage_dealt;
                        _ = damage_to_deal.sub_mut(damage_dealt);
                        for (state.grid.at(position).items) |handle| {
                            const entity = state.entities.get(handle).?;
                            if (entity.type.tag() == .wall or entity.type.tag() == .bomb) continue :directions;
                        }
                        _ = try state.create_visual_effect(VisualEffect{
                            .position = position,
                            .timer_till_disappear = base_effect_timer.prolonged_by(.seconds(state.random.float(f32) * 0.1)),
                            .type = .fire,
                        });
                    }
                }

                _ = state.remove_entity(bomb.entity);
            }

            // Update effect pickups
            var it_modifier_pickups = state.modifier_pickups.iterator();
            while (it_modifier_pickups.next()) |entry| {
                const modifier_pickup, _ = entry;
                if (!modifier_pickup.timer_till_disappear.finished(current_time)) continue;
                assert(state.remove_entity(modifier_pickup.entity).removal_sucessful);
            }
        } else {
            framesCounter += 1;
        }
        //----------------------------------------------------------------------------------

        // Draw
        //----------------------------------------------------------------------------------
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(.init(242, 242, 242, 255));

        const lines_color = rl.Color.white;
        const line_thickness = game_view.scale_to_screen(thicness);
        {
            // Draw horizontal tiles
            for (0..@intCast(grid.height + 1)) |y_in_game| {
                var start = game_view.screen_coordinates_from_position(.{ .x = 0, .y = @intCast(y_in_game) });
                start = start.add(.{ .x = 0, .y = -line_thickness / 2 });
                rl.drawRectangleV(start, .{ .x = game_view.on_screen.x_span(), .y = line_thickness }, lines_color);
            }
            // Draw vertical tiles
            for (0..@intCast(grid.width + 1)) |x_in_game| {
                var start = game_view.screen_coordinates_from_position(.{ .x = @intCast(x_in_game), .y = 0 });
                start = start.add(.{ .x = -line_thickness / 2, .y = 0 });
                rl.drawRectangleV(start, .{ .x = line_thickness, .y = game_view.on_screen.y_span() }, lines_color);
            }
        }

        const tile_size_on_screen = game_view.scale_to_screen(1) * 1.02;
        var tiles_iterator = grid.iterator();
        while (tiles_iterator.next()) |item| {
            const coords = game_view.screen_coordinates_from_position(item.position);
            const x_int = as(i32, coords.x);
            const y_int = as(i32, coords.y);
            for (item.tile.items) |handle| {
                const entity: *Entity = state.get(handle).?;
                switch (entity.type) {
                    .cat => |cat_handle| {
                        const cat = state.get(cat_handle).?;
                        rl.drawTexture(cat_texture, x_int, y_int, cat.color);
                    },
                    .wall => {
                        rl.drawRectangle(
                            x_int,
                            y_int,
                            as(i32, tile_size_on_screen),
                            as(i32, tile_size_on_screen),
                            rl.Color.dark_blue.contrast(-0.6),
                        );
                    },
                    .bomb => {
                        rl.drawTexture(bomb_texture, x_int, y_int, .white);
                    },
                    .modifier_pickup => |pickup_handle| {
                        const pickup = state.get(pickup_handle).?;
                        rl.drawTexture(pickup.texture, x_int, y_int, .white);
                    },
                }
            }

            if (DEBUG) {
                rl.drawText(
                    std.fmt.allocPrintSentinel(frame_arena.allocator(), "{d},{d}", .{ item.position.x, item.position.y }, 0) catch unreachable,
                    @intFromFloat(coords.x),
                    @intFromFloat(coords.y),
                    10,
                    .red,
                );
            }
        }

        var it_visual_effects = state.visual_effects.iterator();
        while (it_visual_effects.next()) |entry| {
            const visual_effect, const visual_effect_handle = entry;
            if (visual_effect.timer_till_disappear) |timer| if (timer.finished(current_time)) {
                // for (state.visual_effects.entries.items, 0..) |e, i| {
                //     switch (e) {
                //         .free => std.debug.print(" [index={d} free]", .{i}),
                //         .occupied => |o| std.debug.print(" [index={d} gen={d}]", .{ i, o.generation.n }),
                //     }
                // }
                assert(state.visual_effects.remove(visual_effect_handle) != null);
                continue;
            };

            const coords = game_view.screen_coordinates_from_position(visual_effect.position);
            // const x_int = as(i32, coords.x);
            // const y_int = as(i32, coords.y);

            switch (visual_effect.type) {
                .fire => {
                    // const progress = visual_effect.timer_till_disappear.?.progress_from_0_to_1(current_time);
                    // const scale = cap_0_1(std.math.pow(f32, 1 - progress, 2));
                    const scale = 1;
                    const rotation = state.random.float(f32) * 2 * pi;
                    rl.drawTextureEx(fire_texture, coords, rotation, scale, .white);
                },
                .after_dash => |after_dash| {
                    _ = after_dash;
                    //
                },
            }
        }

        rl.drawText(
            std.fmt.allocPrintSentinel(frame_arena.allocator(), "Health: {d}", .{
                if (state.cats.get(players.items[0].cat)) |c| state.entities.get(c.entity).?.health.?.points else -1,
            }, 0) catch unreachable,
            120,
            10,
            20,
            rl.Color.green,
        );

        // On pause, we draw a blinking message
        if (pause and @mod(@divFloor(framesCounter, 30), 2) == 0) {
            rl.drawText("PAUSED", 350, 200, 30, .gray);
        }

        rl.drawFPS(10, 10);
        //----------------------------------------------------------------------------------
    }
}
