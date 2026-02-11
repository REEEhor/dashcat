const DEBUG = false;
comptime {
    @setFloatMode(.optimized); // >:) (this will surely not bite us later)
}

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArenaAllocator = std.heap.ArenaAllocator;

const rl = @import("raylib");

const Vector2 = rl.Vector2;
const Vector3 = rl.Vector3;
const Vector4 = rl.Vector4;
const Color = rl.Color;

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
            .seconds = @floatCast(final.seconds_from_beginning - self.seconds_from_beginning),
        };
    }

    pub fn plus_duration(self: Self, to_add: Duration) Timestamp {
        return Timestamp{
            .seconds_from_beginning = self.seconds_from_beginning + to_add.seconds,
        };
    }
};

pub const Duration = struct {
    seconds: f32,

    const Self = @This();

    pub fn from_seconds(seconds: f32) Duration {
        return .{ .seconds = seconds };
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
        const actual_seconds = self.start.duration_to(current_time);
        const total_seconds = self.planned_total_duration();
        return actual_seconds / total_seconds;
    }
};

pub const Health = struct {
    points: i32,

    const Self = @This();

    pub const indestructible = null;

    pub fn add_mut(self: *Self, other: Health) void {
        self.points += other.points;
    }
    pub fn sub_mut(self: *Self, other: Health) void {
        self.points -= other.points;
        if (self.points < 0) self.points = 0;
    }
    pub fn means_dead(self: Self) bool {
        return self.points <= 0;
    }
};

pub const Entity = struct {
    /// `null` means indestructible
    health: ?Health,
    position: Position,
    type: Type,

    const Self = @This();
    pub fn deal_damage(self: *Self, damage: Health) void {
        if (self.health) |*health| {
            health.sub_mut(damage);
        }
    }

    pub const Type = union(enum) {
        cat: *Cat,
        bomb: *Bomb,
        wall,
    };
};

pub const Cat = struct {
    as_entity: *Entity,
    controlling_player: ?*Player,
    color: rl.Color,
    wanted_direction: ?Direction,

    const Self = @This();
    pub fn position(self: *Self) *Position {
        return &self.as_entity.position;
    }
};

pub const Bomb = struct {
    as_entity: *Entity,
    damage: i32,
    blast_radius_in_tiles: i32,
    timer: Timer,

    pub const Properties = struct {
        starting_health: ?Health,
        damage: Health,
        blast_radius_in_tiles: i32,
        time_to_detonate: Duration,
    };
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
};

pub const Player = struct {
    cat: ?*Cat,
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
    all_items: []*Entity,
    tiles: []Tile,

    pub const Tile = FixedArray(*Entity);

    const Self = @This();
    pub fn init(gpa: Allocator, width: i32, height: i32, depth: usize) Allocator.Error!Self {
        const all_items = try gpa.alloc(*Entity, as(usize, width * height) * depth);
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

    pub fn move_assert_ok(self: *Self, entity: *Entity, to: Position) void {
        const old_position = entity.position;
        const new_position = to;
        entity.position = new_position;
        assert(self.at(old_position).swap_remove(entity).was_found_and_removed);
        self.at(new_position).append_assert_ok(entity);
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

// pub fn Set(comptime T: type) type {
//     return struct {

//         // elements:

//         const Self = @This();
//         pub const Item = struct {};
//     };
// }

pub const GameState = struct {
    gpa: Allocator,
    entities: std.ArrayList(Entity),
    cats: std.ArrayList(Cat),
    bombs: std.ArrayList(Bomb),

    cat_texture: rl.Texture,
    bomb_texture: rl.Texture,

    grid: Grid,

    const Self = @This();

    pub const CreateCatParams = struct {
        controlling_player: ?*Player,
        starting_health: Health,
        position: Position,
        color: rl.Color,
    };
    pub fn create_cat(self: *Self, params: CreateCatParams) Allocator.Error!*Cat {
        const entity = try self.entities.addOne(self.gpa);
        const cat = try self.cats.addOne(self.gpa);
        entity.* = .{
            .health = params.starting_health,
            .position = params.position,
            .type = .{ .cat = cat },
        };
        cat.* = .{
            .as_entity = entity,
            .color = params.color,
            .controlling_player = params.controlling_player,
            .wanted_direction = null,
        };
        assert(self.grid.at(params.position).try_append(entity).ok);
        return cat;
    }

    pub const CreateBombParams = struct {
        position: Position,
        current_time: Timestamp,
        properties: Bomb.Properties,
    };
    pub fn create_bomb(self: *Self, params: CreateBombParams) Allocator.Error!*Bomb {
        const entity = try self.entities.addOne(self.gpa);
        const bomb = try self.bombs.addOne(self.gpa);

        entity.* = .{
            .health = params.properties.starting_health,
            .position = params.position,
            .type = .{ .bomb = bomb },
        };

        bomb.* = .{
            .as_entity = entity,
            .damage = params.properties.damage,
            .blast_radius_in_tiles = params.properties.blast_radius_in_tiles,
            .time_detonate_in_frames = params.properties.time_detonate_in_frames,
            .total_detonation_time_in_frame = params.properties.total_detonation_time_in_frame,
        };

        assert(self.grid.at(params.position).try_append(entity).ok);
        return bomb;
    }

    pub const CreateWallParams = struct {
        health: ?Health,
        position: Position,
    };
    pub fn create_wall(self: *Self, params: CreateWallParams) Allocator.Error!*Entity {
        const wall: *Entity = try self.entities.addOne(self.gpa);
        wall.* = .{
            .health = params.health,
            .position = params.position,
            .type = .wall,
        };
        assert(self.grid.at(params.position).try_append(wall).ok);
        return wall;
    }
};

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

    var state = GameState{
        .gpa = round_arena.allocator(),
        .cat_texture = cat_texture,
        .bomb_texture = bomb_texture,
        .bombs = try .initCapacity(round_arena.allocator(), 0),
        .cats = try .initCapacity(round_arena.allocator(), 0),
        .entities = try .initCapacity(round_arena.allocator(), 0),
        .grid = grid,
    };

    for (0..@intCast(grid.height)) |y| {
        for (0..@intCast(grid.width)) |x| {
            const width: usize = @intCast(grid.width);
            const map_index: usize = y * (width + 1) + x;
            const char = game_map[map_index];
            std.debug.print("{c}", .{char});
            if (char == 'w') {
                _ = try state.create_wall(.{
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
        .cat = null,
        .controls = Controls{ .up = .w, .left = .a, .down = .s, .right = .d },
        .bomb_creation_properties = Bomb.Properties{
            .blast_radius_in_tiles = 1,
            .damage = Health{ .points = 5 },
            .starting_health = Health.indestructible,
            .time_to_detonate = Duration.from_seconds(4),
        },
    });
    const player_cat = try state.create_cat(.{
        .color = Color.red.brightness(0.8),
        .controlling_player = &players.items[0],
        .position = .{ .x = 1, .y = 5 },
        .starting_health = Health{ .points = 15 },
    });
    players.items[0].cat = player_cat;

    rl.setTargetFPS(60); // Set our game to run at 60 frames-per-second
    //--------------------------------------------------------------------------------------

    var thicness: f32 = 0.1;

    // Main game loop
    while (!rl.windowShouldClose()) { // Detect window close button or ESC key
        defer std.debug.assert(frame_arena.reset(.retain_capacity));

        // Update
        //----------------------------------------------------------------------------------
        if (rl.isKeyPressed(.space)) {
            pause = !pause;
        }

        thicness += rl.getMouseWheelMove() / 100;

        if (!pause) {
            for (players.items) |*player| {
                if (rl.isKeyPressed(player.controls.up)) player.cat.?.wanted_direction = .up;
                if (rl.isKeyPressed(player.controls.left)) player.cat.?.wanted_direction = .left;
                if (rl.isKeyPressed(player.controls.right)) player.cat.?.wanted_direction = .right;
                if (rl.isKeyPressed(player.controls.down)) player.cat.?.wanted_direction = .down;
            }

            for (state.cats.items) |*cat| {
                defer cat.wanted_direction = null;
                const wanted_direction = cat.wanted_direction orelse continue;

                var final_position = cat.position().*;
                while (true) {
                    const next_position = final_position.add(wanted_direction);
                    if (state.grid.at(next_position).non_empty()) break;
                    final_position = next_position;
                }
                state.grid.move_assert_ok(cat.as_entity, final_position);
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

        const tile_size_on_screen = game_view.scale_to_screen(1) * 1.03;
        var tiles_iterator = grid.iterator();
        while (tiles_iterator.next()) |item| {
            const coords = game_view.screen_coordinates_from_position(item.position);
            const x_int = as(i32, coords.x);
            const y_int = as(i32, coords.y);
            for (item.tile.items) |entity| {
                switch (entity.type) {
                    .cat => |cat| {
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

        // On pause, we draw a blinking message
        if (pause and @mod(@divFloor(framesCounter, 30), 2) == 0) {
            rl.drawText("PAUSED", 350, 200, 30, .gray);
        }

        rl.drawFPS(10, 10);
        //----------------------------------------------------------------------------------
    }
}
