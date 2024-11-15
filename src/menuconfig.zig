const std = @import("std");
const vaxis = @import("vaxis");
const Cell = vaxis.Cell;
const TextInput = vaxis.widgets.TextInput;
const border = vaxis.widgets.border;

// This can contain internal events as well as Vaxis events.
// Internal events can be posted into the same queue as vaxis events to allow
// for a single event loop with exhaustive switching. Booya
const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    foo: u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        //fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();

    // Initialize a tty
    var tty = try vaxis.Tty.init();
    defer tty.deinit();

    // init our text input widget. The text input widget needs an allocator to
    // store the contents of the input
    var app = try App.init(alloc);
    defer app.deinit(tty);

    // The event loop requires an intrusive init. We create an instance with
    // stable pointers to Vaxis and our TTY, then init the instance. Doing so
    // installs a signal handler for SIGWINCH on posix TTYs
    //
    // This event loop is thread safe. It reads the tty in a separate thread
    var loop: vaxis.Loop(Event) = .{
        .tty = &tty,
        .vaxis = &app.vx,
    };
    try loop.init();

    // Start the read loop. This puts the terminal in raw mode and begins
    // reading user input
    try loop.start();
    defer loop.stop();

    // Optionally enter the alternate screen
    try app.vx.enterAltScreen(tty.anyWriter());

    // We'll adjust the color index every keypress for the border
    var color_idx: u8 = 0;

    // Sends queries to terminal to detect certain features. This should always
    // be called after entering the alt screen, if you are using the alt screen
    try app.vx.queryTerminal(tty.anyWriter(), 1 * std.time.ns_per_s);

    while (true) {
        // nextEvent blocks until an event is in the queue
        const event = loop.nextEvent();
        // exhaustive switching ftw. Vaxis will send events if your Event enum
        // has the fields for those events (ie "key_press", "winsize")
        switch (event) {
            .key_press => |key| {
                color_idx = switch (color_idx) {
                    255 => 0,
                    else => color_idx + 1,
                };
                if (key.matches('c', .{ .ctrl = true })) {
                    break;
                } else if (key.matches('l', .{ .ctrl = true })) {
                    app.vx.queueRefresh();
                } else {
                    try app.input.update(.{ .key_press = key });
                }
            },
            .winsize => |ws| try app.vx.resize(alloc, tty.anyWriter(), ws),
            else => {},
        }

        try app.render(color_idx, tty);
    }
}

pub const App = struct {
    allocator: std.mem.Allocator,
    vx: vaxis.Vaxis,
    input: TextInput,
    pub fn init(alloc: std.mem.Allocator) !App {
        // Initialize Vaxis
        const vx = try vaxis.init(alloc, .{});
        // deinit takes an optional allocator. If your program is exiting, you can
        // choose to pass a null allocator to save some exit time.
        return .{
            .allocator = alloc,
            .vx = vx,
            .input = TextInput.init(alloc, &vx.unicode),
        };
    }

    pub fn deinit(self: *App, tty: vaxis.Tty) void {
        self.input.deinit();
        self.vx.deinit(self.allocator, tty.anyWriter());
    }

    pub fn render(self: *App, color_idx: u8, tty: vaxis.Tty) !void {
        // vx.window() returns the root window. This window is the size of the
        // terminal and can spawn child windows as logical areas. Child windows
        // cannot draw outside of their bounds
        const win = self.vx.window();

        // Clear the entire space because we are drawing in immediate mode.
        // vaxis double buffers the screen. This new frame will be compared to
        // the old and only updated cells will be drawn
        win.clear();
        // Create a style
        const style: vaxis.Style = .{
            .fg = .{ .index = color_idx },
        };

        // Create a bordered child window
        const child = win.child(.{
            .x_off = win.width / 3 - 20,
            .y_off = win.height / 2 - 3,
            .width = 40,
            .height = 3,
            .border = .{
                .where = .all,
                .style = style,
            },
        });

        // Draw the text_input in the child window
        self.input.draw(child);
        // Render the screen. Using a buffered writer will offer much better
        // performance, but is not required
        try self.vx.render(tty.anyWriter());
    }
};
