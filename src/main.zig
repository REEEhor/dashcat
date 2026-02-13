var DEBUG = false;
const DO_INVARIANT_ASSERTS = true;
comptime {
    @setFloatMode(.optimized); // >:) (this will surely not bite us later)
}

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArenaAllocator = std.heap.ArenaAllocator;
const eql = std.meta.eql;
const Deque = @import("deque.zig").Deque;

const slices = @import("slices.zig");
const Set = @import("set.zig").Set;

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

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("({d},{d})", .{ self.x, self.y });
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
            _ = health.sub_mut(damage);
            return .{ .is_dead = health.means_dead() };
        }
        return .{ .is_dead = false };
    }

    pub fn is_passable(self: Self) bool {
        return switch (self.type) {
            .modifier_pickup => true,
            //
            .cat => false,
            .enemy => false,
            .wall => false,
            .bomb => false,
        };
    }

    pub const Type = union(enum) {
        cat: Set(Cat).Handle,
        bomb: Set(Bomb).Handle,
        enemy: Set(Enemy).Handle,
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
    distances_map_handle: ?GameState.DistanceMapHandle,

    // TODO: put effects here
};

pub const Enemy = struct {
    entity: EntityHandle,
    type: Type,

    interval_between_movement: Duration,
    timer_until_next_possible_movement: Timer,

    melee_damage: Health,
    interval_between_hits: Duration,
    timer_until_next_possible_hit: Timer,

    const Self = @This();

    pub fn can_do_action(self: Self, current_time: Timestamp) bool {
        return self.can_hit(current_time) or self.can_move(current_time);
    }

    pub fn can_move(self: Self, current_time: Timestamp) bool {
        return self.timer_until_next_possible_movement.finished(current_time);
    }

    pub fn can_hit(self: Self, current_time: Timestamp) bool {
        return self.timer_until_next_possible_hit.finished(current_time);
    }

    pub const Type = union(enum) {
        /// Goes around the walls, ignores bombs
        normal,
    };
};

pub const DistanceMap = struct {
    grid: []Distance,
    width: u32,
    height: u32,

    pub fn init(gpa: Allocator, width: u32, height: u32) Allocator.Error!DistanceMap {
        const grid = try gpa.alloc(Distance, width * height);
        for (0..(height * width)) |index| {
            grid[index] = infinity;
        }
        return .{
            .grid = grid,
            .width = width,
            .height = height,
        };
    }

    pub fn is_inside(self: Self, position: Position) bool {
        if (position.x >= self.width or position.x < 0) return false;
        if (position.y >= self.height or position.y < 0) return false;
        return true;
    }

    pub fn set_all_to_infinity(self: *Self) void {
        for (self.grid) |*d| d.* = infinity;
    }

    pub fn distance_at(self: Self, position: Position) Distance {
        const index = self.get_index(position);
        return self.grid[index];
    }

    pub fn distance_at_ptr(self: *Self, position: Position) *Distance {
        const index = self.get_index(position);
        return &self.grid[index];
    }

    pub fn get_index(self: Self, position: Position) usize {
        assert(self.is_inside(position));
        return (as(usize, position.y) * self.width) + as(usize, position.x);
    }

    pub const Distance = u32;
    pub const infinity: Distance = std.math.maxInt(Distance);
    const Self = @This();
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
    color: rl.Color,
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
            if (self.capacity <= self.items.len) {
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
                if (eql(i, item)) break index;
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
        .@"struct" => |info| {
            const BackingInteger = info.backing_integer.?;
            assert(number >= 0);
            const raw: BackingInteger = @truncate(number);
            return @bitCast(raw);
        },
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

pub const GameState = struct {
    gpa: Allocator,

    entities: Set(Entity),
    cats: Set(Cat),
    enemies: Set(Enemy),
    bombs: Set(Bomb),
    modifier_pickups: Set(ModifierPickup),

    distances_to_players: std.ArrayList(DistanceMap),

    visual_effects: Set(VisualEffect),

    grid: Grid,

    random: std.Random,

    const Self = @This();

    pub const DistanceMapHandle = packed struct { index: u32 };

    pub fn get(self: *Self, handle: anytype) ?@TypeOf(handle).Set.ItemPtr {
        return switch (@TypeOf(handle)) {
            EntityHandle => self.entities.get(handle),
            Set(Cat).Handle => self.cats.get(handle),
            Set(Bomb).Handle => self.bombs.get(handle),
            Set(ModifierPickup).Handle => self.modifier_pickups.get(handle),
            Set(Enemy).Handle => self.enemies.get(handle),
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
        debug_assert_invariants(self);
        defer debug_assert_invariants(self);
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
        debug_assert_invariants(self);
        defer debug_assert_invariants(self);
        const entity: Entity = self.entities.remove(entity_handle) orelse return .{ .removal_sucessful = false };
        assert(self.grid.at(entity.position).swap_remove(entity_handle).was_found_and_removed);
        switch (entity.type) {
            .cat => |cat_handle| {
                const cat = self.cats.remove(cat_handle).?;
                if (cat.distances_map_handle) |index| {
                    self.distances_to_players.items[index.index].set_all_to_infinity();
                }
                if (cat.controlling_player) |player| {
                    player.cat = .empty_handle;
                }
            },
            .enemy => |enemy_handle| {
                const enemy = self.enemies.remove(enemy_handle).?;
                _ = enemy;
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
        const entity = self.entities.get(entity_handle).?;
        const old_position = entity.position;
        const new_position = to;
        entity.position = new_position;
        assert(self.grid.at(old_position).swap_remove(entity_handle).was_found_and_removed);
        self.grid.at(new_position).append_assert_ok(entity_handle);
    }

    pub fn recalculate_distances_from(
        self: *Self,
        temporary_allocator: Allocator,
        start: Position,
        distances_handle: DistanceMapHandle,
    ) Allocator.Error!void {
        // Do a BFS
        const distance_map = &self.distances_to_players.items[distances_handle.index];
        distance_map.set_all_to_infinity();

        const not_visited = DistanceMap.infinity;

        var to_visit = try Deque(Position).initCapacity(temporary_allocator, 10);
        defer to_visit.deinit(temporary_allocator);

        try to_visit.pushBack(temporary_allocator, start);
        distance_map.distance_at_ptr(start).* = 0;

        while (to_visit.popFront()) |current_position| {
            const current_distance = distance_map.distance_at(current_position);

            for (&[_]Direction{ .up, .left, .down, .right }) |direction| {
                const neighbour_position = current_position.add(direction);
                if (!distance_map.is_inside(neighbour_position)) continue;
                if (distance_map.distance_at(neighbour_position) != not_visited) continue;
                if (!self.is_passable_at(neighbour_position)) continue;
                distance_map.distance_at_ptr(neighbour_position).* = current_distance + 1;
                try to_visit.pushBack(temporary_allocator, neighbour_position);
            }
        }
    }

    pub fn CreateResult(comptime T: type) type {
        return struct {
            ptr: *T,
            entity_ptr: *Entity,
            entity_handle: EntityHandle,
            handle: Set(T).Handle,

            pub fn init(entity: anytype, entity_subtype: anytype) @This() {
                return .{
                    .ptr = entity_subtype.ptr,
                    .handle = entity_subtype.handle,
                    .entity_handle = entity.handle,
                    .entity_ptr = entity.ptr,
                };
            }
        };
    }

    pub const CreateOption = enum {
        /// Return all things (`ptr`, `entity_ptr`, `handle`, `entity_handle`)
        all,
        /// Return just the handle
        handle,
    };

    pub const CreateCatParams = struct {
        controlling_player: ?*Player,
        starting_health: Health,
        position: Position,
        color: rl.Color,
        register_in_distance_map: bool,
        temporary_allocator: Allocator,
    };
    pub fn create_cat(self: *Self, params: CreateCatParams) Allocator.Error!Set(Cat).Handle {
        return (try self.create_cat_all(params)).handle;
    }
    pub fn create_cat_all(
        self: *Self,
        params: CreateCatParams,
    ) Allocator.Error!CreateResult(Cat) {
        const distances_handle: ?DistanceMapHandle = blk: {
            if (!params.register_in_distance_map) break :blk null;
            try self.distances_to_players.append(self.gpa, try .init(
                self.gpa,
                as(u32, self.grid.width),
                as(u32, self.grid.height),
            ));
            const distances_handle = as(DistanceMapHandle, self.distances_to_players.items.len - 1);
            try self.recalculate_distances_from(params.temporary_allocator, params.position, distances_handle);
            break :blk distances_handle;
        };

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
            .distances_map_handle = distances_handle,
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

    pub const CreateEnemyParams = struct {
        position: Position,
        health: Health,
        enemy_type: Enemy.Type,
        melee_damage: Health,
        interval_between_hits: Duration,
        interval_between_movement: Duration,
        current_time: Timestamp,
    };
    pub fn create_enemy(self: *Self, params: CreateEnemyParams) Allocator.Error!Set(Enemy).Handle {
        return (try self.create_enemy_all(params)).handle;
    }
    pub fn create_enemy_all(self: *Self, params: CreateEnemyParams) Allocator.Error!CreateResult(Enemy) {
        const entity = try self.entities.add_with_pointer(self.gpa, .{
            .health = params.health,
            .position = params.position,
            .type = undefined,
        });
        const enemy = try self.enemies.add_with_pointer(self.gpa, .{
            .entity = entity.handle,
            .melee_damage = params.melee_damage,
            .type = params.enemy_type,
            .interval_between_hits = params.interval_between_hits,
            .timer_until_next_possible_hit = params.current_time.timer_that_goes_off_in(params.interval_between_hits),

            .interval_between_movement = params.interval_between_movement,
            .timer_until_next_possible_movement = params.current_time.timer_that_goes_off_in(params.interval_between_movement),
        });
        entity.ptr.type = .{ .enemy = enemy.handle };
        self.grid.at(params.position).append_assert_ok(entity.handle);
        return .init(entity, enemy);
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

fn debug_check_entity(state: *GameState, entity: *Entity, entity_handle: EntityHandle) void {
    assert(state.entities.get(entity_handle).? == entity);
    switch (entity.type) {
        .wall => {},
        .modifier_pickup => |pickup_handle| {
            const pickup = state.modifier_pickups.get(pickup_handle).?;
            assert(eql(pickup.entity, entity_handle));
        },
        .cat => |cat_handle| {
            const cat = state.cats.get(cat_handle).?;
            assert(eql(cat.entity, entity_handle));
        },
        .bomb => |bomb_handle| {
            const bomb = state.bombs.get(bomb_handle).?;
            assert(eql(bomb.entity, entity_handle));
        },
        .enemy => |enemy_handle| {
            const enemy = state.enemies.get(enemy_handle).?;
            assert(eql(enemy.entity, entity_handle));
        },
    }
}

pub fn debug_assert_invariants(state: *GameState) void {
    if (!DO_INVARIANT_ASSERTS) return;
    var it_entity = state.entities.iterator();
    while (it_entity.next()) |entry| {
        const entity, const entity_handle = entry;
        debug_check_entity(state, entity, entity_handle);
    }

    var it = state.grid.iterator();
    while (it.next()) |entry| {
        for (entry.tile.items) |handle| {
            const entity = state.entities.get(handle).?;
            assert(eql(entity.position, entry.position));
            debug_check_entity(state, entity, handle);
        }
    }

    for (state.grid.tiles) |tile| {
        for (tile.items) |handle| {
            const entity = state.entities.get(handle).?;
            debug_check_entity(state, entity, handle);
        }
    }
}

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
        \\w  w    w       e  w
        \\w       w          w
        \\w1      w          w
        \\w       w          w
        \\w     wwwwwwww     w
        \\w       w          w
        \\w       w          w
        \\w  w               w
        \\w        w    ww www
        \\w             wwewww
        \\w             wwewww
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
        .enemies = try .init_with_capacity(round_arena.allocator(), 0),
        .modifier_pickups = try .init_with_capacity(round_arena.allocator(), 0),
        .visual_effects = try .init_with_capacity(round_arena.allocator(), 0),
        .distances_to_players = try .initCapacity(round_arena.allocator(), 0),
        .grid = grid,
        .random = prng.random(),
    };

    var _players_buffer: [10]Player = undefined;
    var players = ArrayList(Player).initBuffer(&_players_buffer);
    players.appendAssumeCapacity(.{
        .cat = .empty_handle,
        .color = Color.red.brightness(0.8),
        .controls = Controls{ .up = .w, .left = .a, .down = .s, .right = .d, .spawn_bomb = .space },
        .bomb_creation_properties = Bomb.Properties{
            .blast_radius_in_tiles = 2,
            .damage = Health{ .points = 5 },
            .starting_health = Health.indestructible,
            .time_to_detonate = Duration.seconds(2),
        },
    });

    for (0..@intCast(grid.height)) |y| {
        for (0..@intCast(grid.width)) |x| {
            const width: usize = @intCast(grid.width);
            const map_index: usize = y * (width + 1) + x;
            const char = game_map[map_index];
            const position = Position{ .x = as(i32, x), .y = as(i32, y) };
            switch (char) {
                ' ' => {},
                'w' => {
                    _ = try state.create_wall_all(.{
                        .position = position,
                        .health = .indestructible,
                    });
                },
                '1'...'9' => {
                    const player_index = char - '1';
                    if (player_index >= players.items.len) {
                        std.debug.print("Invalid player index: {c} at position: {f}. Maximum is: {d}\n", .{
                            char, position, players.items.len,
                        });
                        return error.invalid_player_index;
                    }
                    const player = &players.items[player_index];
                    if (state.cats.get(player.cat)) |cat| {
                        const previous_position = state.entities.get(cat.entity).?.position;
                        std.debug.print("Player {c} has the starting position defined a second time at: {f}. First time was: {f}.\n", .{
                            char, position, previous_position,
                        });
                        return error.player_starting_position_defined_multiple_times;
                    }
                    const player_cat = try state.create_cat(.{
                        .color = player.color,
                        .controlling_player = &players.items[0],
                        .position = .{ .x = 1, .y = 5 },
                        .starting_health = Health{ .points = 15 },
                        .register_in_distance_map = true,
                        .temporary_allocator = frame_arena.allocator(),
                    });
                    player.cat = player_cat;
                },
                'e' => {
                    _ = try state.create_enemy(.{
                        .position = position,
                        .enemy_type = .normal,
                        .health = Health{ .points = 5 },
                        .melee_damage = Health{ .points = 4 },
                        .interval_between_hits = Duration.seconds(0.8),
                        .interval_between_movement = Duration.seconds(1.1),
                        .current_time = Timestamp{ .seconds_from_beginning = rl.getTime() },
                    });
                },
                else => {
                    std.debug.print("Invalid character '{c}' at position: {f}\n", .{ char, position });
                    return error.invalid_character;
                },
            }
        }
    }

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
        if (rl.isKeyPressed(.f3)) {
            DEBUG = !DEBUG;
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
                    if (cat.distances_map_handle) |map_handle| {
                        state.recalculate_distances_from(frame_arena.allocator(), final_position, map_handle) catch |err| {
                            comptime assert(@TypeOf(err) == Allocator.Error);
                            std.log.warn("Out of memory when recalculating cat distances from: {f}. Cat handle: {any}", .{ final_position, entry.@"1" });
                        };
                    }
                }
            }

            // Update enemies
            var it_enemies = state.enemies.iterator();
            enemies: while (it_enemies.next()) |entry| {
                const enemy, const enemy_handle = entry;
                _ = enemy_handle;
                const entity: *Entity = state.entities.get(enemy.entity).?;

                switch (enemy.type) {
                    .normal => {
                        if (!enemy.can_do_action(current_time)) continue :enemies;
                        var best_position: ?Position = null;
                        var best_distance = DistanceMap.infinity;
                        for (&[_]Direction{ .up, .left, .down, .right }) |direction| {
                            const position = entity.position.add(direction);
                            var min_distance = DistanceMap.infinity;
                            for (state.distances_to_players.items) |*distance_map| {
                                min_distance = @min(min_distance, distance_map.distance_at(position));
                            }
                            if (min_distance < best_distance) {
                                best_distance = min_distance;
                                best_position = position;
                            }
                        }
                        const pos = best_position orelse continue :enemies;
                        if (best_distance == 0) {
                            if (!enemy.can_hit(current_time)) continue :enemies;
                            enemy.timer_until_next_possible_hit = current_time.timer_that_goes_off_in(enemy.interval_between_hits);
                            _ = state.deal_damage_at(pos, enemy.melee_damage, enemy.entity);
                        } else if (state.is_passable_at(pos)) {
                            if (!enemy.can_move(current_time)) continue :enemies;
                            enemy.timer_until_next_possible_movement = current_time.timer_that_goes_off_in(enemy.interval_between_movement);
                            state.move_assert_ok(enemy.entity, pos);
                        }
                    },
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
                    .enemy => |enemy_handle| {
                        const enemy = state.get(enemy_handle).?;
                        _ = enemy;
                        // TODO: use a custom texture for enemies
                        rl.drawTexture(cat_texture, x_int, y_int, .red);
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
                const distance = state.distances_to_players.items[0].distance_at(item.position);
                if (distance == DistanceMap.infinity) {
                    rl.drawText(
                        "no",
                        @intFromFloat(coords.x + 9),
                        @intFromFloat(coords.y + 14),
                        10,
                        .red,
                    );
                } else {
                    rl.drawText(
                        std.fmt.allocPrintSentinel(frame_arena.allocator(), "{d}", .{distance}, 0) catch unreachable,
                        @intFromFloat(coords.x + 12),
                        @intFromFloat(coords.y + 14),
                        10,
                        .red,
                    );
                }
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

test {
    _ = @import("set.zig");
}
