const std = @import("std");
const posix = std.posix;

pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
    pub const white = "\x1b[37m";
    pub const bold_red = "\x1b[1;31m";
    pub const bold_green = "\x1b[1;32m";
    pub const bold_yellow = "\x1b[1;33m";
    pub const bold_blue = "\x1b[1;34m";
    pub const bold_magenta = "\x1b[1;35m";
    pub const bold_cyan = "\x1b[1;36m";
};

pub const Icon = struct {
    pub const check = "✓";
    pub const cross = "✗";
    pub const arrow = "→";
    pub const dot = "•";
    pub const info = "●";
    pub const warning = "⚠";
};

var use_color: bool = true;
var verbose_mode: bool = false;

pub fn init() void {
    if (std.posix.getenv("NO_COLOR")) |_| {
        use_color = false;
        return;
    }
    use_color = std.posix.isatty(std.posix.STDERR_FILENO);
}

pub fn setVerbose(v: bool) void {
    verbose_mode = v;
}

pub fn isVerbose() bool {
    return verbose_mode;
}

fn writeStderr(data: []const u8) void {
    var remaining = data;
    while (remaining.len > 0) {
        const written = posix.write(posix.STDERR_FILENO, remaining) catch return;
        remaining = remaining[written..];
    }
}

fn printFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeStderr(s);
}

pub fn col(color: []const u8) []const u8 {
    return if (use_color) color else "";
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    printFmt(fmt, args);
}

pub fn step(comptime fmt: []const u8, args: anytype) void {
    const c1 = col(Color.bold_blue);
    const c2 = col(Color.reset);
    const c3 = col(Color.white);
    print("{s}{s}{s} {s}" ++ fmt ++ "{s}\n", .{ c1, Icon.arrow, c2, c3 } ++ args ++ .{c2});
}

// Verbose-only step (only prints in verbose mode)
pub fn vstep(comptime fmt: []const u8, args: anytype) void {
    if (verbose_mode) {
        step(fmt, args);
    }
}

pub fn success(comptime fmt: []const u8, args: anytype) void {
    const c1 = col(Color.bold_green);
    const c2 = col(Color.reset);
    const c3 = col(Color.white);
    print("{s}{s}{s} {s}" ++ fmt ++ "{s}\n", .{ c1, Icon.check, c2, c3 } ++ args ++ .{c2});
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (verbose_mode) {
        const c1 = col(Color.dim);
        const c2 = col(Color.reset);
        print("{s}  {s} " ++ fmt ++ "{s}\n", .{ c1, Icon.dot } ++ args ++ .{c2});
    }
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    const c1 = col(Color.bold_red);
    const c2 = col(Color.reset);
    print("{s}{s} error:{s} " ++ fmt ++ "{s}\n", .{ c1, Icon.cross, c2 } ++ args ++ .{c2});
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    const c1 = col(Color.bold_yellow);
    const c2 = col(Color.reset);
    print("{s}{s}{s} " ++ fmt ++ "{s}\n", .{ c1, Icon.warning, c2 } ++ args ++ .{c2});
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    const c1 = col(Color.cyan);
    const c2 = col(Color.reset);
    print("{s}{s}{s} " ++ fmt ++ "{s}\n", .{ c1, Icon.info, c2 } ++ args ++ .{c2});
}
