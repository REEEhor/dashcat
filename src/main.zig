const DEBUG = false;

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const rl = @import("raylib");

const Vector2 = rl.Vector2;
const Vector3 = rl.Vector3;
const Vector4 = rl.Vector4;

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

pub const Cat = struct {
    color: rl.Color,
    wanted_direction: ?Direction,
    position: Position,
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
    cat: *Cat,
    controls: Controls,
};

pub const Tile = union(enum) {
    cat: *Cat,
    wall,
    empty,

    const Self = @This();
    pub const Tag = std.meta.Tag(Tile);
    pub fn tag(self: Self) Tag {
        return std.meta.activeTag(self);
    }
};

pub const Grid = struct {
    width: i32,
    height: i32,
    tiles: []Tile,

    const Self = @This();
    pub fn init(gpa: Allocator, width: i32, height: i32) Allocator.Error!Self {
        const tiles = try gpa.alloc(Tile, @intCast(width * height));
        for (tiles) |*tile| {
            tile.* = .empty;
        }
        return Self{ .width = width, .height = height, .tiles = tiles };
    }

    pub fn at(self: *Self, position: Position) *Tile {
        const index = position.y * self.width + position.x;
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

pub fn as_f32(number: anytype) f32 {
    return @as(f32, @floatFromInt(number));
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

    var round_arena = ArenaAllocator.init(gpa);
    defer round_arena.deinit();

    var frame_arena = ArenaAllocator.init(gpa);
    defer frame_arena.deinit();

    rl.initWindow(screen.width, screen.height, "Dash Cat");
    defer rl.closeWindow(); // Close window and OpenGL context

    var pause: bool = false;
    var framesCounter: i32 = 0;

    var grid = try Grid.init(round_arena.allocator(), 20, 20);
    const game_view = GameView{
        .in_game = .{ .min_x = 0, .min_y = 0, .max_x = @floatFromInt(grid.width), .max_y = @floatFromInt(grid.height) },
        .on_screen = .{ .min_x = 10, .min_y = 10, .max_x = 800 - 20, .max_y = 800 - 20 },
    };
    const game_map =
        //01234567890123456789
        \\wwwwwwwwwwwwwwwwwwww
        \\w          wwwwwwwww
        \\w          wwwwwwwww
        \\w                  w
        \\w                  w
        \\w  w    w          w
        \\w       w          w
        \\w       w          w
        \\w       w          w
        \\w      wwwwwww     w
        \\w       w          w
        \\w       w          w
        \\w  w               w
        \\w        w    wwwwww
        \\w             wwwwww
        \\w             wwwwww
        \\w             wwwwww
        \\w             wwwwww
        \\ww           wwwwwww
        \\wwwwwwwwwwwwwwwwwwww
    ;

    for (0..@intCast(grid.height)) |y| {
        for (0..@intCast(grid.width)) |x| {
            const width: usize = @intCast(grid.width);
            const map_index: usize = y * (width + 1) + x;
            const char = game_map[map_index];
            std.debug.print("{c}", .{char});
            if (char == 'w') {
                grid.at(.{ .x = @intCast(x), .y = @intCast(y) }).* = .wall;
            } else {
                grid.at(.{ .x = @intCast(x), .y = @intCast(y) }).* = .empty;
            }
        }
        std.debug.print("\n", .{});
    }

    var cats = try std.ArrayList(Cat).initCapacity(round_arena.allocator(), 1);
    try cats.append(round_arena.allocator(), Cat{
        .color = rl.Color.red,
        .wanted_direction = null,
        .position = .{ .x = 4, .y = 5 },
    });

    for (cats.items) |*cat| {
        grid.at(cat.position).* = .{ .cat = cat };
    }
    const players = &[_]Player{.{
        .cat = &cats.items[0],
        .controls = Controls{ .up = .w, .left = .a, .down = .s, .right = .d },
    }};

    rl.setTargetFPS(60); // Set our game to run at 60 frames-per-second
    //--------------------------------------------------------------------------------------

    // Main game loop
    while (!rl.windowShouldClose()) { // Detect window close button or ESC key
        defer std.debug.assert(frame_arena.reset(.retain_capacity));

        // Update
        //----------------------------------------------------------------------------------
        if (rl.isKeyPressed(.space)) {
            pause = !pause;
        }

        if (!pause) {
            for (players) |player| {
                if (rl.isKeyPressed(player.controls.up)) player.cat.wanted_direction = .up;
                if (rl.isKeyPressed(player.controls.left)) player.cat.wanted_direction = .left;
                if (rl.isKeyPressed(player.controls.right)) player.cat.wanted_direction = .right;
                if (rl.isKeyPressed(player.controls.down)) player.cat.wanted_direction = .down;
            }

            for (cats.items) |*cat| {
                defer cat.wanted_direction = null;
                const wanted_direction = cat.wanted_direction orelse continue;

                const old_position = cat.position;
                while (true) {
                    const new_position = cat.position.add(wanted_direction);
                    if (grid.at(new_position).tag() != .empty) break;
                    cat.position = new_position;
                }
                grid.at(old_position).* = .empty;
                grid.at(cat.position).* = .{ .cat = cat };
            }
        } else {
            framesCounter += 1;
        }
        //----------------------------------------------------------------------------------

        // Draw
        //----------------------------------------------------------------------------------
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(.ray_white);

        // rl.drawCircleV(ballPosition, ballRadius, .maroon);
        // rl.drawText("PRESS SPACE to PAUSE BALL MOVEMENT", 10, rl.getScreenHeight() - 25, 20, .light_gray);

        const tile_size_length = 27;
        const tile_size = rl.Vector2.init(tile_size_length, tile_size_length);
        var tiles_iterator = grid.iterator();
        while (tiles_iterator.next()) |item| {
            const coords = game_view.screen_coordinates_from_position(item.position);
            rl.drawRectangleV(coords, tile_size.subtractValue(0.1), .light_gray);

            switch (item.tile.*) {
                .cat => |cat| {
                    rl.drawRectangleRounded(.init(coords.x, coords.y, tile_size.x - 0.1, tile_size.y - 0.1), 0.1, 0, cat.color);
                },
                .empty => {
                    // nothing
                },
                .wall => {
                    rl.drawRectangleV(coords, tile_size, .dark_gray);
                },
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
