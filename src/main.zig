const std = @import("std");
const ink = @import("ink");
const clap = @import("clap");
const config = @import("config");
const cli = @import("cli.zig");

const Memory = ink.tui.memory.Memory;

pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  defer _ = gpa.deinit();
    
  const allocator = gpa.allocator();
  const ctx = cli.Ctx.init(allocator);
    
  const params = comptime clap.parseParamsComptime(
    \\-h, --help     Display this help and exit.
    \\-V, --version  Display version information and exit.
    \\-j, --json     Output AST as JSON.
    \\-v, --view     View rendered markdown in TUI.
    \\-w, --watch    Watch file for changes and re-render.
    \\-t, --timing   Show parse timing information.
    \\<str>
    \\
  );
  
  var diag = clap.Diagnostic{};
  var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
    .diagnostic = &diag,
    .allocator = std.heap.page_allocator,
  }) catch |err| {
    try diag.reportToFile(.stderr(), err);
    return err;
  }; defer res.deinit();
  
  
  if (res.args.help != 0) return clap.helpToFile(.stderr(), clap.Help, &params, .{});
  if (res.args.version != 0) return try ctx.version();
  
  const watching = res.args.watch != 0;
  const timing = res.args.timing != 0;

  const path = res.positionals[0] orelse {
    if (res.args.json != 0) {
      ctx.printf("usage: ink --json <file.md>\n", .{});
      std.process.exit(1);
    }
    
    const tui = ink.tui.Tui.init(allocator) catch |err| {
      ctx.printf("error: tui init failed: {s}\n", .{@errorName(err)});
      std.process.exit(1);
    };
    defer tui.deinit();
    
    while (true) {
      const picked = ink.tui.picker.run(tui) catch |err| {
        ctx.printf("error: file picker failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
      };
      const result = picked orelse return;
      defer allocator.free(result.path);

      switch (result.action) {
        .edit => handleEditor(tui, result.path, ctx),
        .view => if (try viewLoop(tui, .{
          .path = result.path,
          .watching = watching,
          .has_picker = true,
        }, ctx)) return,
      }
    }
  };
  
  if (res.args.view != 0) {
    const tui = try ink.tui.Tui.init(allocator);
    defer tui.deinit();
    _ = try viewLoop(tui, .{
      .path = path,
      .watching = watching,
      .has_picker = false,
    }, ctx);
    return;
  }

  if (res.args.json != 0) {
    var arena = ink.Arena.init(std.heap.page_allocator);
    defer arena.deinit();

    const markdown = readFile(&arena, path, ctx) orelse return;
    const root = try ink.parse(&arena, markdown);

    const stdout_file = std.fs.File.stdout();
    const buf = try arena.allocator().alloc(u8, markdown.len * 4);

    var stdout_writer = stdout_file.writer(buf);
    const w = &stdout_writer.interface;

    defer w.flush() catch {};
    try ink.toJson(w, root);

    return;
  }

  const mem = Memory.load(allocator);
  if (watching) try watchNormal(allocator, path, ctx, timing, mem)
  else try renderNormal(allocator, path, ctx, timing, mem);
}

const TuiOptions = struct {
  path: []const u8,
  watching: bool,
  has_picker: bool,
};

const LaunchResult = enum { 
  quit, back_to_picker, edit 
};

fn handleEditor(tui: *ink.tui.Tui, path: []const u8, ctx: cli.Ctx) void {
  tui.suspendForEditor();
  launchEditor(path, ctx);
  tui.resumeFromEditor();
}

fn viewLoop(tui: *ink.tui.Tui, opts: TuiOptions, ctx: cli.Ctx) !bool {
  while (true) switch (try launchTui(tui, opts)) {
    .quit => return true,
    .back_to_picker => return false,
    .edit => handleEditor(tui, opts.path, ctx),
  };
}

fn launchTui(tui: *ink.tui.Tui, opts: TuiOptions) !LaunchResult {
  const alloc = tui.alloc;
  const mem = Memory.load(alloc);

  var arena = ink.Arena.init(std.heap.page_allocator);
  defer arena.deinit();

  const ctx = cli.Ctx.init(alloc);
  const markdown = readFile(&arena, opts.path, ctx) orelse return .quit;
  const root = try ink.parse(&arena, markdown);

  var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
  defer aw.deinit();

  var highlighter = try ink.Highlighter.init(std.heap.page_allocator);
  try ink.render(&aw.writer, root, .{
    .highlighter = &highlighter,
    .show_urls = mem.show_urls,
    .tui = true,
  });

  try aw.writer.flush();
  const rendered = aw.writer.buffer[0..aw.writer.end];
  return switch (try ink.tui.run(tui, rendered, opts.path, .{
    .watching = opts.watching,
    .has_picker = opts.has_picker,
  })) {
    .quit => .quit,
    .back_to_picker => .back_to_picker,
    .edit => .edit,
  };
}

fn launchEditor(path: []const u8, ctx: cli.Ctx) void {
  const editor = std.posix.getenv("EDITOR") orelse "vi";
  var child = std.process.Child.init(&.{ editor, path }, ctx.allocator);
  child.stdin_behavior = .Inherit;
  child.stdout_behavior = .Inherit;
  child.stderr_behavior = .Inherit;

  _ = child.spawnAndWait() catch |err| {
    ctx.printf("error: failed to launch editor: {s}\n", .{@errorName(err)});
    std.process.exit(1);
  };
}

fn readFile(arena: *ink.Arena, path: []const u8, ctx: cli.Ctx) ?[]const u8 {
  const file = std.fs.cwd().openFile(path, .{}) catch |err| {
    ctx.printf("\x1b[1;31merror\x1b[0m: cannot open \x1b[33m'{s}'\x1b[0m: {s}\n", .{ path, @errorName(err) });
    std.process.exit(1);
  };
  defer file.close();

  return file.readToEndAlloc(arena.allocator(), std.math.maxInt(usize)) catch |err| {
    ctx.printf("\x1b[1;31merror\x1b[0m: cannot read \x1b[33m'{s}'\x1b[0m: {s}\n", .{ path, @errorName(err) });
    std.process.exit(1);
  };
}

fn renderNormal(_: std.mem.Allocator, path: []const u8, ctx: cli.Ctx, timing: bool, mem: Memory) !void {
  var arena = ink.Arena.init(std.heap.page_allocator);
  defer arena.deinit();

  const markdown = readFile(&arena, path, ctx) orelse return;

  const start = try std.time.Instant.now();
  const root = try ink.parse(&arena, markdown);
  const end = try std.time.Instant.now();

  const buf = try arena.allocator().alloc(u8, markdown.len * 4);
  var stdout = std.fs.File.stdout().writer(buf);

  const w = &stdout.interface;
  defer stdout.interface.flush() catch {};

  var highlighter = try ink.Highlighter.init(std.heap.page_allocator);
  try ink.render(w, root, .{ .highlighter = &highlighter, .margin = mem.margin, .line_wrap_percent = mem.line_wrap_percent });
  try w.writeAll("\n");

  if (timing) {
    const elapsed: f64 = @floatFromInt(end.since(start));
    const secs = elapsed / std.time.ns_per_s;
    const mb = @as(f64, @floatFromInt(markdown.len)) / (1024.0 * 1024.0);
    try w.print("\nparsed in {d:.6}s ({d:.2} MB/s)\n", .{ secs, mb / secs });
  }
}

fn watchNormal(_: std.mem.Allocator, path: []const u8, ctx: cli.Ctx, timing: bool, mem: Memory) !void {
  _ = std.fs.cwd().statFile(path) catch {
    ctx.printf("\x1b[1;31merror\x1b[0m: cannot open \x1b[33m'{s}'\x1b[0m: file not found\n", .{path});
    std.process.exit(1);
  };

  const stdin_fd = std.posix.STDIN_FILENO;
  const orig_termios = std.posix.tcgetattr(stdin_fd) catch null;
  if (orig_termios) |orig| {
    var raw = orig;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = true;
    std.posix.tcsetattr(stdin_fd, .FLUSH, raw) catch {};
  }
  defer if (orig_termios) |orig| {
    std.posix.tcsetattr(stdin_fd, .FLUSH, orig) catch {};
  };

  var last_mtime: i128 = 0;
  var last_size: u64 = 0;

  while (true) {
    const stat = std.fs.cwd().statFile(path) catch {
      std.Thread.sleep(200 * std.time.ns_per_ms);
      continue;
    };

    if (stat.mtime != last_mtime or stat.size != last_size) {
      last_mtime = stat.mtime;
      last_size = stat.size;

      var arena = ink.Arena.init(std.heap.page_allocator);
      defer arena.deinit();

      const markdown = readFile(&arena, path, ctx) orelse continue;

      const start = try std.time.Instant.now();
      const root = try ink.parse(&arena, markdown);
      const end = try std.time.Instant.now();

      const buf = try arena.allocator().alloc(u8, markdown.len * 4);
      var out = std.fs.File.stdout().writer(buf);
      const w = &out.interface;

      try w.writeAll("\x1b[H\x1b[2J\x1b[3J");

      var highlighter = try ink.Highlighter.init(std.heap.page_allocator);
      try ink.render(w, root, .{ .highlighter = &highlighter, .margin = mem.margin, .line_wrap_percent = mem.line_wrap_percent });

      if (timing) {
        const elapsed: f64 = @floatFromInt(end.since(start));
        const secs = elapsed / std.time.ns_per_s;
        const mb = @as(f64, @floatFromInt(markdown.len)) / (1024.0 * 1024.0);
        try w.print("\nparsed in {d:.6}s ({d:.2} MB/s)\n", .{ secs, mb / secs });
      }

      try w.flush();
    }

    std.Thread.sleep(200 * std.time.ns_per_ms);
  }
}
