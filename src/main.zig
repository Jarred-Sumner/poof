// hello!
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const fs = std.fs;
const options = @import("build_options");

const output = @import("output.zig");
const sandbox = @import("sandbox.zig");

// Version info (set at build time)
const version = options.version;
const git_commit = options.git_commit;

// Re-exports from modules
const allocator = sandbox.allocator;
const Config = sandbox.Config;
const Mode = sandbox.Mode;

const step = output.step;
const vstep = output.vstep;
const success = output.success;
const log = output.log;
const err = output.err;
const warn = output.warn;
const info = output.info;
const col = output.col;
const print = output.print;
const Color = output.Color;

fn parseSize(s: []const u8) !u64 {
    if (s.len == 0) return error.InvalidSize;

    var num_end: usize = 0;
    for (s) |c| {
        if (c >= '0' and c <= '9') {
            num_end += 1;
        } else {
            break;
        }
    }

    if (num_end == 0) return error.InvalidSize;

    const num = try std.fmt.parseInt(u64, s[0..num_end], 10);
    const suffix = s[num_end..];

    if (suffix.len == 0) return num;

    const multiplier: u64 = switch (suffix[0]) {
        'k', 'K' => 1024,
        'm', 'M' => 1024 * 1024,
        'g', 'G' => 1024 * 1024 * 1024,
        else => return error.InvalidSize,
    };

    return num * multiplier;
}

fn generateTimestamp() ![]const u8 {
    const ts = try posix.clock_gettime(.REALTIME);
    const secs: u64 = @intCast(ts.sec);
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getDaySeconds();
    const yd = epoch.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();

    return try std.fmt.allocPrint(allocator, "{d}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    });
}

// C library functions for terminal control
extern "c" fn tcsetpgrp(fd: c_int, pgrp: c_int) c_int;
extern "c" fn getpgrp() c_int;

// Signal handler state
var child_pid: i32 = 0;

fn signalHandler(sig: linux.SIG) callconv(.c) void {
    // Forward signal to child and wait for it to exit
    if (child_pid > 0) {
        _ = linux.kill(child_pid, sig);
        // Wait for child to exit so mounts are cleaned up
        var status: u32 = 0;
        _ = linux.waitpid(child_pid, &status, 0);
    }
    // Cleanup cgroups and temp dirs
    sandbox.cleanupCgroup();
    sandbox.cleanupOverlayDirs();
    // Re-raise signal to get default behavior (exit with signal)
    var default_action: linux.Sigaction = .{
        .handler = .{ .handler = linux.SIG.DFL },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(sig, &default_action, null);
    _ = linux.kill(linux.getpid(), sig);
}

fn setupSignalHandlers() void {
    var action: linux.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = linux.sigemptyset(),
        .flags = linux.SA.RESTART,
    };
    _ = linux.sigaction(linux.SIG.INT, &action, null);
    _ = linux.sigaction(linux.SIG.TERM, &action, null);
    _ = linux.sigaction(linux.SIG.HUP, &action, null);
}

fn reclaimTerminal() void {
    if (!posix.isatty(posix.STDIN_FILENO)) return;

    // Block SIGTTOU/SIGTTIN while we reclaim the terminal
    // (calling tcsetpgrp from background can trigger these)
    var mask = linux.sigemptyset();
    linux.sigaddset(&mask, linux.SIG.TTOU);
    linux.sigaddset(&mask, linux.SIG.TTIN);
    var old_mask: linux.sigset_t = undefined;
    _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, &old_mask);

    _ = tcsetpgrp(posix.STDIN_FILENO, getpgrp());

    // Restore original signal mask
    _ = linux.sigprocmask(linux.SIG.SETMASK, &old_mask, null);
}

const ChangeType = enum { added, edited, deleted };

const Change = struct {
    path: []const u8,
    change_type: ChangeType,
};

const ChangeList = struct {
    items: []Change,
    len: usize,

    fn append(self: *ChangeList, change: Change) void {
        if (self.len < self.items.len) {
            self.items[self.len] = change;
            self.len += 1;
        }
    }
};

// Recursively collect changed files in upper dir
fn collectChanges(upper_path: []const u8, target_dir: []const u8, strip_prefix: []const u8, changes: *ChangeList) void {
    var dir = fs.openDirAbsolute(upper_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ upper_path, entry.name }) catch continue;

        // Build display path (relative to target)
        const display_path = if (std.mem.startsWith(u8, full_path, strip_prefix))
            full_path[strip_prefix.len..]
        else
            full_path;

        if (entry.kind == .directory) {
            // Check if directory is empty (new empty dir) or has contents
            var subdir = fs.openDirAbsolute(full_path, .{ .iterate = true }) catch continue;
            var sub_iter = subdir.iterate();
            const has_children = (sub_iter.next() catch null) != null;
            subdir.close();

            if (has_children) {
                // Recurse into subdirectories with contents
                collectChanges(full_path, target_dir, strip_prefix, changes);
            } else {
                // Empty directory - new dir
                const path_with_slash = std.fmt.allocPrint(allocator, "{s}/", .{display_path}) catch continue;
                changes.append(.{ .path = path_with_slash, .change_type = .added });
            }
        } else if (entry.kind == .character_device) {
            // Whiteout - file was deleted
            changes.append(.{ .path = display_path, .change_type = .deleted });
        } else {
            // Check if file exists in target (edited) or not (added)
            const target_path = std.fmt.allocPrint(allocator, "{s}{s}", .{ target_dir, display_path }) catch continue;
            const change_type: ChangeType = if (fs.accessAbsolute(target_path, .{}))
                .edited
            else |_|
                .added;
            changes.append(.{ .path = display_path, .change_type = change_type });
        }
    }
}

fn printChanges(changes: []const Change, upper_dir: []const u8) void {
    const red = col(Color.red);
    const green = col(Color.green);
    const yellow = col(Color.yellow);
    const dim = col(Color.dim);
    const reset = col(Color.reset);

    // Print summary line with temp folder path
    info("{d} changed file{s} {s}{s}{s}", .{
        changes.len,
        if (changes.len == 1) "" else "s",
        dim,
        upper_dir,
        reset,
    });

    // Print each change with colored prefix only
    for (changes) |change| {
        // Strip leading / from path
        const path = if (change.path.len > 0 and change.path[0] == '/')
            change.path[1..]
        else
            change.path;

        switch (change.change_type) {
            .deleted => print("  {s}-{s} {s}\n", .{ red, reset, path }),
            .added => print("  {s}+{s} {s}\n", .{ green, reset, path }),
            .edited => print("  {s}~{s} {s}\n", .{ yellow, reset, path }),
        }
    }
}

// Handle enter mode - show changes and prompt to apply
fn handleEnterModeChanges(config: Config) void {
    const upper_dir = config.upper_dir orelse return;
    const target_dir = config.enter_target orelse return;

    // Reclaim the terminal - the child shell was the foreground process group
    reclaimTerminal();

    // The changes to target_dir are in upper_dir + target_dir path
    const changes_path = std.fmt.allocPrint(allocator, "{s}{s}", .{ upper_dir, target_dir }) catch return;

    // Check if any changes exist
    var dir = fs.openDirAbsolute(changes_path, .{ .iterate = true }) catch {
        success("No changes made to {s}", .{target_dir});
        return;
    };
    defer dir.close();

    // Count changes
    var change_count: usize = 0;
    var iter = dir.iterate();
    while (iter.next() catch null) |_| {
        change_count += 1;
    }

    if (change_count == 0) {
        success("No changes made to {s}", .{target_dir});
        return;
    }

    // Collect all changes (max 1000)
    var change_buf: [1000]Change = undefined;
    var changes = ChangeList{ .items = &change_buf, .len = 0 };
    collectChanges(changes_path, target_dir, changes_path, &changes);

    if (changes.len == 0) {
        success("No changes made to {s}", .{target_dir});
        return;
    }

    print("\n", .{});
    printChanges(changes.items[0..changes.len], upper_dir);
    print("\n", .{});

    // Prompt user
    const c1 = col(Color.bold_yellow);
    const c2 = col(Color.reset);
    print("{s}Apply these changes to {s}?{s} [y/N/d(iff)]: ", .{ c1, target_dir, c2 });

    // Read user input
    var input_buf: [16]u8 = undefined;
    const n = posix.read(posix.STDIN_FILENO, &input_buf) catch {
        print("\n", .{});
        keepChanges(upper_dir);
        return;
    };
    const input = input_buf[0..n];

    const trimmed = std.mem.trim(u8, input, " \t\r\n");

    if (std.mem.eql(u8, trimmed, "y") or std.mem.eql(u8, trimmed, "Y") or std.mem.eql(u8, trimmed, "yes")) {
        // Apply changes using rsync or cp
        applyChanges(changes_path, target_dir);
    } else if (std.mem.eql(u8, trimmed, "d") or std.mem.eql(u8, trimmed, "D") or std.mem.eql(u8, trimmed, "diff")) {
        // Show full diff (--no-pager to avoid "terminal not fully functional" issues)
        const full_diff_argv = [_][]const u8{ "git", "--no-pager", "diff", "--no-index", target_dir, changes_path };
        var full_diff_proc = std.process.Child.init(&full_diff_argv, allocator);
        full_diff_proc.stderr_behavior = .Inherit;
        full_diff_proc.stdout_behavior = .Inherit;
        _ = full_diff_proc.spawnAndWait() catch {};

        // Prompt again
        print("\n{s}Apply these changes?{s} [y/N]: ", .{ c1, c2 });
        var input_buf2: [16]u8 = undefined;
        const n2 = posix.read(posix.STDIN_FILENO, &input_buf2) catch {
            print("\n", .{});
            keepChanges(upper_dir);
            return;
        };
        const trimmed2 = std.mem.trim(u8, input_buf2[0..n2], " \t\r\n");
        if (std.mem.eql(u8, trimmed2, "y") or std.mem.eql(u8, trimmed2, "Y")) {
            applyChanges(changes_path, target_dir);
        } else {
            keepChanges(upper_dir);
        }
    } else {
        keepChanges(upper_dir);
    }
}

fn keepChanges(upper_dir: []const u8) void {
    // Don't delete the temp dir - user wants to keep it
    sandbox.cleanup_temp_base = null;
    sandbox.cleanup_work_dir = null;
    sandbox.cleanup_merged_dir = null;
    const c = col(Color.cyan);
    const r = col(Color.reset);
    info("Changes saved to {s}{s}{s}", .{ c, upper_dir, r });
}

fn applyChanges(source: []const u8, target: []const u8) void {
    step("Applying changes to {s}", .{target});

    // Use rsync to copy changes (handles deletions via whiteouts would need special handling)
    // For now, just copy the files
    const argv = [_][]const u8{ "cp", "-r", "-T", source, target };
    var proc = std.process.Child.init(&argv, allocator);
    proc.stderr_behavior = .Inherit;
    proc.stdout_behavior = .Inherit;
    const term = proc.spawnAndWait() catch {
        err("Failed to apply changes", .{});
        return;
    };

    if (term.Exited == 0) {
        success("Changes applied successfully", .{});
    } else {
        err("Failed to apply changes (exit code {})", .{term.Exited});
    }
}

pub fn run(config: Config) u8 {
    const orig_uid = linux.getuid();
    const orig_gid = linux.getgid();

    // Show startup info (minimal unless verbose)
    if (config.mode == .exec) {
        vstep("Starting ephemeral environment", .{});
    } else if (config.enter_target != null) {
        // Interactive mode (enter or run without --upper)
        vstep("Entering poof mode for {s}", .{config.enter_target.?});
    } else {
        vstep("Starting persistent environment", .{});
    }
    log("uid={} gid={}", .{ orig_uid, orig_gid });

    // Set up cgroups BEFORE fork so child inherits limits
    if (config.memory_limit != null or config.pids_limit != null) {
        sandbox.setupCgroup(config) catch |cgroup_err| {
            err("cgroup setup failed: {}", .{cgroup_err});
            return 1;
        };
        vstep("Resource limits applied", .{});
    }

    // Set up cleanup paths BEFORE fork (child sets globals but parent does cleanup)
    if (config.mode == .exec) {
        // For exec: create temp dir now so parent knows the path to clean up
        sandbox.cleanup_temp_base = sandbox.makeTempDir() catch |e| {
            err("makeTempDir: {}", .{e});
            return 1;
        };
    } else if (config.mode == .run or config.mode == .enter) {
        // For run/enter: set up paths for .work and .merged cleanup
        sandbox.cleanup_work_dir = std.fmt.allocPrint(allocator, "{s}.work", .{config.upper_dir.?}) catch null;
        sandbox.cleanup_merged_dir = std.fmt.allocPrint(allocator, "{s}.merged", .{config.upper_dir.?}) catch null;
        // For enter mode (and interactive run), also clean up the temp upper dir
        if (config.enter_target != null) {
            sandbox.cleanup_temp_base = config.upper_dir;
        }
    }

    // Set up signal handlers BEFORE fork for cleanup on SIGTERM/SIGINT
    setupSignalHandlers();

    // Fork to create isolated child
    const pid = linux.fork();

    if (pid == 0) {
        // Child
        sandbox.childMain(config, orig_uid, orig_gid);
    } else if (pid > 0) {
        // Parent - wait for child with optional timeout
        child_pid = @intCast(pid);
        log("child pid={}", .{child_pid});

        if (config.timeout) |timeout_secs| {
            // Get monotonic time for timeout tracking
            const start_ts = posix.clock_gettime(.MONOTONIC) catch {
                // Fall back to no timeout if clock fails
                const status = posix.waitpid(child_pid, 0).status;
                sandbox.cleanupCgroup();
                sandbox.cleanupOverlayDirs();
                if ((status & 0x7f) == 0) return @truncate((status >> 8) & 0xff);
                if (((status & 0x7f) + 1) >> 1 > 0) return 128 + @as(u8, @truncate(status & 0x7f));
                return 1;
            };
            const deadline_sec: i64 = start_ts.sec + timeout_secs;

            while (true) {
                // Non-blocking wait
                const result = posix.waitpid(child_pid, posix.W.NOHANG);
                if (result.pid != 0) {
                    // Child exited
                    sandbox.cleanupCgroup();
                    sandbox.cleanupOverlayDirs();
                    const status = result.status;
                    if ((status & 0x7f) == 0) {
                        return @truncate((status >> 8) & 0xff);
                    }
                    if (((status & 0x7f) + 1) >> 1 > 0) {
                        return 128 + @as(u8, @truncate(status & 0x7f));
                    }
                    return 1;
                }

                // Check timeout
                const now_ts = posix.clock_gettime(.MONOTONIC) catch continue;
                if (now_ts.sec >= deadline_sec) {
                    warn("timeout after {d}s, killing process", .{timeout_secs});
                    _ = linux.kill(child_pid, linux.SIG.KILL);
                    _ = posix.waitpid(child_pid, 0);
                    sandbox.cleanupCgroup();
                    sandbox.cleanupOverlayDirs();
                    return 124; // Standard timeout exit code
                }

                // Sleep briefly before checking again (10ms)
                posix.nanosleep(0, 10_000_000);
            }
        } else {
            // No timeout - blocking wait
            const status = posix.waitpid(child_pid, 0).status;
            sandbox.cleanupCgroup();

            // Handle interactive mode - prompt to apply changes before cleanup
            if (config.enter_target != null) {
                handleEnterModeChanges(config);
            }

            sandbox.cleanupOverlayDirs();

            if ((status & 0x7f) == 0) {
                return @truncate((status >> 8) & 0xff);
            }
            if (((status & 0x7f) + 1) >> 1 > 0) {
                return 128 + @as(u8, @truncate(status & 0x7f));
            }
            return 1;
        }
    } else {
        err("fork failed: {}", .{sandbox.errnoFromSyscall(pid)});
        sandbox.cleanupCgroup();
        sandbox.cleanupOverlayDirs();
        return 1;
    }
}

fn printVersion() void {
    if (git_commit.len > 0) {
        print("poof {s} ({s})\n", .{ version, git_commit });
    } else {
        print("poof {s}\n", .{version});
    }
}

fn printModeHelp(mode: sandbox.Mode) void {
    const C = col(Color.cyan);
    const B = col(Color.bold);
    const G = col(Color.green);
    const Y = col(Color.yellow);
    const RE = col(Color.red);
    const D = col(Color.dim);
    const R = col(Color.reset);

    switch (mode) {
        .exec => {
            print("\n{s}poof exec{s} — Run command in ephemeral sandbox {s}(changes vanish){s}\n", .{ C, R, D, R });
            print("\n{s}USAGE{s}\n", .{ B, R });
            print("  poof exec [options] [--] {s}<program>{s} [args...]\n", .{ Y, R });
            print("\n{s}EXAMPLES{s}\n", .{ B, R });
            print("  {s}${s} poof exec claude --dangerously-skip-permissions\n", .{ D, R });
            print("  {s}${s} poof exec rm -rf ~                 {s}# Safe! Nothing happens{s}\n", .{ D, R, D, R });
            print("  {s}${s} poof exec bash                    {s}# Disposable shell{s}\n", .{ D, R, D, R });
            print("  {s}${s} poof exec --timeout=60 ./build.sh  {s}# Kill if > 60s{s}\n", .{ D, R, D, R });
            print("\n{s}OPTIONS{s}\n", .{ B, R });
            print("  {s}--timeout=<secs>{s}    Kill after N seconds (exit code 124)\n", .{ G, R });
            print("  {s}--memory=<size>{s}     Memory limit (e.g. 100M, 1G)\n", .{ G, R });
            print("  {s}--pids=<max>{s}        Max processes (fork bomb protection)\n", .{ G, R });
            print("  {s}-v, --verbose{s}       Show detailed progress\n\n", .{ G, R });
        },
        .run => {
            print("\n{s}poof run{s} — Run command, review changes, apply or discard\n", .{ C, R });
            print("\n{s}USAGE{s}\n", .{ B, R });
            print("  poof run [options] [--] {s}<program>{s} [args...]\n", .{ Y, R });
            print("\n{s}EXAMPLES{s}\n", .{ B, R });
            print("  {s}${s} poof run claude --dangerously-skip-permissions\n", .{ D, R });
            print("  {s}${s} poof run bun install              {s}# Review changes first{s}\n", .{ D, R, D, R });
            print("  {s}${s} poof run --upper=./changes bash   {s}# Persist to ./changes/{s}\n", .{ D, R, D, R });
            print("\n{s}When the command exits, you'll see:{s}\n", .{ D, R });
            print("  {s}●{s} 3 changed files {s}/tmp/poof-xxx{s}\n", .{ C, R, D, R });
            print("    {s}+{s} src/new-file.txt\n", .{ G, R });
            print("    {s}~{s} src/modified.txt\n", .{ Y, R });
            print("    {s}-{s} src/deleted.txt\n", .{ RE, R });
            print("\n  {s}Apply changes?{s} [y/N/d]\n", .{ Y, R });
            print("    {s}y{s} — Apply all changes to host\n", .{ G, R });
            print("    {s}n{s} — Discard (keep in temp dir)\n", .{ G, R });
            print("    {s}d{s} — Show full diff first\n", .{ G, R });
            print("\n{s}OPTIONS{s}\n", .{ B, R });
            print("  {s}--upper=<dir>{s}       Save changes to directory (skip prompt)\n", .{ G, R });
            print("  {s}--timeout=<secs>{s}    Kill after N seconds\n", .{ G, R });
            print("  {s}--memory=<size>{s}     Memory limit (e.g. 100M, 1G)\n", .{ G, R });
            print("  {s}--pids=<max>{s}        Max processes\n", .{ G, R });
            print("  {s}-v, --verbose{s}       Show detailed progress\n\n", .{ G, R });
        },
        .enter => {
            print("\n{s}poof enter{s} — Interactive sandbox with $SHELL\n", .{ C, R });
            print("\n{s}USAGE{s}\n", .{ B, R });
            print("  poof enter [options] [directory]\n", .{});
            print("\n{s}Opens your shell in an isolated environment.{s}\n", .{ D, R });
            print("{s}When you exit, review changes and apply or discard.{s}\n", .{ D, R });
            print("\n{s}EXAMPLES{s}\n", .{ B, R });
            print("  {s}${s} poof enter                        {s}# Sandbox current dir{s}\n", .{ D, R, D, R });
            print("  {s}${s} poof enter /etc                   {s}# Sandbox /etc{s}\n", .{ D, R, D, R });
            print("  {s}${s} cd myproject && poof enter        {s}# Edit safely{s}\n\n", .{ D, R, D, R });
        },
    }
}

fn printUsage() void {
    const B = col(Color.bold);
    const C = col(Color.cyan);
    const M = col(Color.magenta);
    const G = col(Color.green);
    const Y = col(Color.yellow);
    const D = col(Color.dim);
    const R = col(Color.reset);

    // Banner
    print(
        \\
        \\{s} ▗▄▄▖  ▗▄▖  ▗▄▖ ▗▄▄▄▖{s}
        \\{s} ▐▌ ▐▌▐▌ ▐▌▐▌ ▐▌▐▌   {s}
        \\{s} ▐▛▀▘ ▐▌ ▐▌▐▌ ▐▌▐▛▀▀▘{s}
        \\{s} ▐▌   ▝▚▄▞▘▝▚▄▞▘▐▌   {s}
        \\{s}  Ephemeral filesystem isolation{s}
        \\
        \\
    , .{ M, R, M, R, M, R, M, R, D, R });

    // Usage & Commands
    print(
        \\{s}USAGE{s}
        \\  {s}poof{s} {s}<command>{s} [options] [--] {s}<program>{s} [args...]
        \\
        \\{s}COMMANDS{s}
        \\  {s}exec{s}  <program>             Run in ephemeral mode {s}(changes vanish){s}
        \\  {s}run{s}   <program>             Review & apply on exit {s}(or --upper to persist){s}
        \\  {s}enter{s}                       Interactive $SHELL {s}(review & apply on exit){s}
        \\
    , .{ B, R, C, R, Y, R, G, R, B, R, C, R, D, R, C, R, D, R, C, R, D, R });

    // Options
    print(
        \\{s}OPTIONS{s}
        \\  {s}-v, --verbose{s}               Show detailed progress
        \\  {s}-h, --help{s}                  Show this help
        \\  {s}-V, --version{s}               Show version
        \\  {s}--upper=<dir>{s}               Directory for changes {s}(run mode){s}
        \\  {s}--timeout=<secs>{s}            Kill after N seconds
        \\  {s}--memory=<bytes>{s}            Memory limit {s}(e.g. 100M, 1G){s}
        \\  {s}--pids=<max>{s}                Max processes {s}(fork bomb protection){s}
        \\
    , .{ B, R, G, R, G, R, G, R, G, R, D, R, G, R, G, R, D, R, G, R, D, R });

    // Isolation
    print(
        \\{s}ISOLATION{s}
        \\  {s}•{s} Mount namespace with overlay filesystem
        \\  {s}•{s} PID namespace {s}(isolated process tree){s}
        \\  {s}•{s} UTS namespace {s}(isolated hostname){s}
        \\  {s}•{s} IPC namespace {s}(isolated System V IPC){s}
        \\
    , .{ B, R, M, R, M, R, D, R, M, R, D, R, M, R, D, R });

    // Examples
    print(
        \\{s}EXAMPLES{s}
        \\  {s}${s} poof exec claude --dangerously-skip-permissions
        \\  {s}${s} poof exec rm -rf ~                {s}# Safe! Nothing happens{s}
        \\  {s}${s} poof run bun install              {s}# Review changes first{s}
        \\
        \\{s}NOTE{s}  Works inside Docker/Podman {s}(1 nesting level, kernel limit){s}
        \\{s}ENV{s}   IS_SANDBOX=1 is set inside the sandbox
        \\
        \\
    , .{ B, R, D, R, D, R, D, R, D, R, D, R, Y, R, D, R, G, R });
}

pub fn main() u8 {
    output.init();

    const args = std.process.argsAlloc(allocator) catch {
        err("out of memory", .{});
        return 1;
    };

    if (args.len < 2) {
        printUsage();
        return 1;
    }

    var cwd_buf: [4096]u8 = undefined;
    const cwd = posix.getcwd(&cwd_buf) catch "/";

    var config = Config{
        .mode = .exec,
        .command = &.{},
        .cwd = cwd,
    };

    var upper_dir: ?[]const u8 = null;
    var mode: ?Mode = null;
    var cmd_start: usize = args.len;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return 0;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return 0;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            output.setVerbose(true);
        } else if (std.mem.startsWith(u8, arg, "--upper=")) {
            upper_dir = arg[8..];
        } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
            config.timeout = std.fmt.parseInt(u32, arg[10..], 10) catch {
                err("invalid timeout: {s}", .{arg[10..]});
                return 1;
            };
        } else if (std.mem.startsWith(u8, arg, "--memory=")) {
            config.memory_limit = parseSize(arg[9..]) catch {
                err("invalid memory limit: {s} (use e.g. 100M, 1G)", .{arg[9..]});
                return 1;
            };
        } else if (std.mem.startsWith(u8, arg, "--pids=")) {
            config.pids_limit = std.fmt.parseInt(u32, arg[7..], 10) catch {
                err("invalid pids limit: {s}", .{arg[7..]});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--")) {
            cmd_start = i + 1;
            break;
        } else if (std.mem.eql(u8, arg, "exec")) {
            mode = .exec;
        } else if (std.mem.eql(u8, arg, "run")) {
            mode = .run;
        } else if (std.mem.eql(u8, arg, "enter")) {
            mode = .enter;
        } else if (arg.len > 0 and arg[0] != '-') {
            cmd_start = i;
            break;
        } else {
            err("unknown option: {s}", .{arg});
            return 1;
        }
    }

    if (mode == null) {
        err("missing command: exec, run, or enter", .{});
        printUsage();
        return 1;
    }

    config.mode = mode.?;
    config.verbose = output.isVerbose();

    // Handle enter mode specially - uses $SHELL, no command needed
    if (config.mode == .enter) {
        const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
        const shell_args = allocator.alloc([]const u8, 1) catch {
            err("out of memory", .{});
            return 1;
        };
        shell_args[0] = shell;
        config.command = shell_args;
        config.enter_target = cwd;

        // Create temp upper dir for enter mode
        config.upper_dir = sandbox.makeTempDir() catch {
            err("failed to create temp dir", .{});
            return 1;
        };
    } else {
        if (cmd_start >= args.len) {
            printModeHelp(config.mode);
            return 1;
        }
        config.command = args[cmd_start..];
    }

    // Determine upper directory for run mode
    if (config.mode == .run) {
        const is_interactive = std.posix.isatty(std.posix.STDIN_FILENO);

        if (upper_dir) |dir| {
            // --upper explicitly provided: persist changes there
            if (dir.len > 0 and dir[0] != '/') {
                config.upper_dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, dir }) catch {
                    err("out of memory", .{});
                    return 1;
                };
            } else {
                config.upper_dir = dir;
            }
        } else if (is_interactive) {
            // Interactive mode without --upper: use temp dir and prompt y/n/d on exit
            config.upper_dir = sandbox.makeTempDir() catch {
                err("failed to create temp dir", .{});
                return 1;
            };
            config.enter_target = cwd; // Triggers y/n/d prompt on exit
        } else {
            // Non-interactive without --upper: auto-generate from command name
            const cmd_name = std.fs.path.basename(config.command[0]);
            const base_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, cmd_name }) catch {
                err("out of memory", .{});
                return 1;
            };

            // Check if base path exists, if so append timestamp
            if (std.fs.accessAbsolute(base_path, .{})) |_| {
                const ts = generateTimestamp() catch {
                    err("clock error", .{});
                    return 1;
                };
                config.upper_dir = std.fmt.allocPrint(allocator, "{s}.{s}", .{ base_path, ts }) catch {
                    err("out of memory", .{});
                    return 1;
                };
            } else |_| {
                config.upper_dir = base_path;
            }

            const hc = col(Color.bold ++ Color.cyan);
            const rc = col(Color.reset);
            info("Changes will persist to {s}{s}{s}", .{ hc, config.upper_dir.?, rc });
        }
    }

    return run(config);
}
