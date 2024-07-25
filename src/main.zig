const std: type = @import("std");
const print: fn (comptime []const u8, anytype) void = std.debug.print;
const panic: fn (comptime []const u8, anytype) noreturn = std.debug.panic;
const log = std.log;

const STDIN_FILENO = std.posix.STDIN_FILENO;
const STDOUT_FILENO = std.posix.STDOUT_FILENO;
const STDERR_FILENO = std.posix.STDERR_FILENO;

pub const std_options = .{
	.log_level = .info,
};

/// Not to be confused with null.
const NUL: u8 = 0;

fn eprintln(comptime fmt: []const u8, args: anytype) void
{
	std.debug.print(fmt, args);
	std.debug.print("\n", .{});
}

/// Errors writing to stdout are silently discarded, like std.debug.print.
fn println(comptime fmt: []const u8, args: anytype) void
{
	const stdout = std.io.getStdOut();
	const writer = stdout.writer();
	writer.print(fmt, args) catch return;
	writer.print("\n", .{}) catch return;
}

const Type = std.builtin.Type;

fn typeInfoOf(comptime value: anytype) Type
{
	return @typeInfo(@TypeOf(value));
}

const fcntl = @cImport({
	@cDefine("_ISO_C11_SOURCE", "1");
	@cDefine("_POSIX_SOURCE", "200809L");
	@cDefine("_XOPEN_SOURCE", "700");
	@cInclude("fcntl.h");
	@cInclude("stdlib.h");
});

const termios = @cImport({
	@cDefine("_ISO_C11_SOURCE", "1");
	@cDefine("_POSIX_SOURCE", "200809L");
	@cDefine("_XOPEN_SOURCE", "700");
	@cInclude("termios.h");
	@cInclude("unistd.h");
	@cInclude("sys/ioctl.h");
});

const errno = @cImport({
	@cDefine("_ISO_C11_SOURCE", "1");
	@cDefine("_POSIX_SOURCE", "200809L");
	@cDefine("_XOPEN_SOURCE", "700");
	@cInclude("errno.h");
});

const OpenptError = error{
	ExhaustedFileDescriptors,
	ExhaustedFiles,
	ExhaustedPtys,
	ExhaustedStreams,
} || std.posix.UnexpectedError;

const OpenptControl = enum{
	BecomeControllingTerminal,
	BecomeNonControllingTerminal,
};

fn openpt(control_type: OpenptControl) OpenptError!std.posix.fd_t
{
	const flags = switch (control_type) {
		.BecomeControllingTerminal => fcntl.O_RDWR,
		.BecomeNonControllingTerminal => fcntl.O_RDWR | fcntl.O_NOCTTY,
	};
	const fd = fcntl.posix_openpt(flags);
	switch (std.posix.errno(fd)) {
		.SUCCESS => return fd,
		.MFILE => return error.ExhaustedFileDescriptors,
		.NFILE => return error.ExhaustedFiles,
		.AGAIN => return error.ExhaustedPtys,
		.NOSR => return error.ExhaustedStreams,
		else => |e| {
			eprintln("posix_openpt() gave supposedly impossible error code {}", .{ e });
			return error.Unexpected;
		},
	}
}

const PtyError = error{
	NotAFileDescriptor,
	NotAPty,
} || std.posix.UnexpectedError;

fn unlockpt(fd: std.posix.fd_t) PtyError!void
{
	const ret = fcntl.unlockpt(fd);
	switch (std.posix.errno(ret)) {
		.SUCCESS => return {},
		.BADF => return error.NotAFileDescriptor,
		.INVAL => return error.NotAPty,
		else => |e| {
			eprintln("unlockpt() gave supposedly impossible error code {}", .{ e });
			return error.Unexpected;
		}
	}
}

fn ptsname(allocator: std.mem.Allocator, fd: std.posix.fd_t) ![]const u8
{
	const name: [*:0]const u8 = fcntl.ptsname(fd) orelse {
		return switch (std.posix.errno(-1)) {
			.SUCCESS => unreachable,
			.BADF => error.NotAFileDescriptor,
			.NOTTY => error.NotAPty,
			else => |e| std.posix.unexpectedErrno(e),
		};
	};


	const len = std.mem.len(name);
	const cstring: []const u8 = name[0..len :0];
	const memory: []u8 = try allocator.alloc(u8, cstring.len);
	@memcpy(memory, cstring[0..cstring.len]);
	return memory;
}

fn getwinsz(fd: std.posix.fd_t) !std.posix.winsize
{
	var winsize = termios.winsize{
		.ws_row = 0,
		.ws_col = 0,
		.ws_xpixel = 0,
		.ws_ypixel = 0,
	};
	const res = std.os.linux.ioctl(fd, termios.TIOCGWINSZ, @intFromPtr(&winsize));
	return switch (std.posix.errno(res)) {
		.SUCCESS => std.posix.winsize{
			.ws_row = winsize.ws_row,
			.ws_col = winsize.ws_col,
			.ws_xpixel = winsize.ws_xpixel,
			.ws_ypixel = winsize.ws_ypixel,
		},
		else => |e| std.posix.unexpectedErrno(e),
	};
}

fn setsid() error{ CantBecomeLeader, Unexpected }!std.posix.fd_t
{
	const ret = std.os.linux.setsid();
	return switch (std.posix.errno(ret)) {
		.SUCCESS => ret,
		.PERM => error.CantBecomeLeader,
		else => |e| std.posix.unexpectedErrno(e),
	};
}

fn csctty(fd: std.posix.fd_t) error{ PermissionDenied, Unexpected }!void
{
	const ret = std.os.linux.ioctl(fd, termios.TIOCSCTTY, 0);
	return switch (std.posix.errno(ret)) {
		.SUCCESS => {},
		.PERM => error.PermissionDenied,
		else => |e| std.posix.unexpectedErrno(e),
	};
}

fn TerminatedArrayList(comptime T: type, comptime sentinel_value: ?T) type
{
	return struct{
		const Self = @This();
		const Item = T;
		const sentinel = sentinel_value;

		inner: std.ArrayList(?Item),

		pub fn init(allocator: std.mem.Allocator) !Self
		{
			var list = std.ArrayList(?Item).init(allocator);
			try list.append(null);
			return Self{
				.inner = list,
			};
		}

		pub fn deinit(self: Self) void
		{
			for (self.inner.items) |item| {
				if (item) |ptr| {
					switch (@typeInfo(@TypeOf(ptr))) {
						.Pointer => {
							const slice = ptr[0..std.mem.len(ptr)];
							self.inner.allocator.free(slice);
						},
						.Array => {
							self.inner.allocator.free(ptr);
						},
						else => comptime unreachable,
					}
				}
			}
			self.inner.deinit();
		}

		pub fn append(self: *Self, item: Item) !void
		{
			const last: *?Item = &self.inner.items[self.inner.items.len - 1];
			std.debug.assert(last.* == null);
			// These two operations must be in this order.
			// If we set the last item before doing the append, and the append failed, then
			// we'd have an arraylist where the last element isn't the sentinel terminator.
			try self.inner.append(null);
			last.* = item;
		}

		/// The number of *items* in this arraylist -- so not including the sentinel.
		pub fn count(self: Self) usize
		{
			return self.inner.items.len - 1;
		}

		/// The number of slots this arraylist is using -- so including the sentinel.
		pub fn totalLen(self: Self) usize
		{
			return self.inner.items.len;
		}

		pub fn asSlice(self: Self) []Item
		{
			return @ptrCast(self.inner.items[0..self.count()]);
		}

		pub fn asTerminatedSlice(self: Self) [:null]?Item
		{
			return @ptrCast(self.inner.items[0..self.inner.items.len]);
		}

		pub fn format(self: Self, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void
		{
			if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
			if (self.count() < 1) {
				return;
			}

			try std.fmt.format(writer, "{s}", .{ "{ " });

			const slice: []Item = self.asSlice();
			std.debug.assert(slice.len == self.count());

			for (slice, 0..) |arg, idx| {
				try std.fmt.format(writer, if (Item == CString) "\"{s}\"" else "{s}", .{ arg });
				if (idx < slice.len - 1) {
					try std.fmt.format(writer, "{s}", .{ ", "});
				}
			}
			try std.fmt.format(writer, "{s}", .{ " }" });
		}
	};
}

const CString = [*:NUL]const u8;
const CStringCArray = TerminatedArrayList(CString, null);

/// Caller takes ownership of the returned array list, unless an error occurs.
fn collectArgs(allocator: std.mem.Allocator) !CStringCArray
{
	var arglist = try CStringCArray.init(allocator);
	errdefer arglist.deinit();

	var args = try std.process.ArgIterator.initWithAllocator(allocator);
	defer args.deinit();

	while (args.next()) |arg| {
		var copied: [*:NUL]u8 = try allocator.allocSentinel(u8, arg.len, NUL);
		copied[arg.len] = 0;
		@memcpy(copied, arg);
		std.debug.assert(copied[arg.len] == 0);
		try arglist.append(copied);
	}

	return arglist;
}

const BasicPoller = struct{
	const Self = @This();

	fds: []const std.posix.fd_t,

	poller: std.posix.fd_t,

	events: std.ArrayList(std.os.linux.epoll_event),

	pub fn init(allocator: std.mem.Allocator, file_descriptors: []const std.posix.fd_t) !Self
	{
		var self = Self{
			.fds = file_descriptors,
			.poller = try std.posix.epoll_create1(0),
			.events = std.ArrayList(std.os.linux.epoll_event).init(allocator),
		};
		errdefer std.posix.close(self.poller);
		errdefer self.events.deinit();

		for (self.fds) |fd| {
			var poll_event = std.os.linux.epoll_event{
				.events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ERR | std.os.linux.EPOLL.HUP,
				.data = std.os.linux.epoll_data{
					.fd = fd,
				},
			};
			try std.posix.epoll_ctl(self.poller, std.os.linux.EPOLL.CTL_ADD, fd, &poll_event);
			try self.events.append(poll_event);
		}

		return self;
	}

	/// Caller owns the ArrayList returned, unless an error occurs.
	pub fn next(self: Self, timeout: i32) !?std.ArrayList(std.posix.fd_t)
	{
		const nfds = std.posix.epoll_wait(self.poller, self.events.items, timeout);
		if (nfds < 1) {
			return null;
		}

		var fd_list = std.ArrayList(std.posix.fd_t).init(self.events.allocator);
		errdefer fd_list.deinit();

		for (0..nfds) |returned_fd_idx| {
			const event = self.events.items[returned_fd_idx];
			for (self.fds) |known_fd| {
				if (event.data.fd == known_fd) {
					try fd_list.append(event.data.fd);
				}
			}
		}

		return fd_list;
	}

	pub fn deinit(self: Self) void
	{
		std.posix.close(self.poller);
		self.events.deinit();
	}
};

/// Caller is responsible for closing the file descriptor.
pub fn handleSignalAsFile(signals: []const comptime_int) !std.posix.fd_t
{
	var set = std.posix.empty_sigset;
	inline for (signals) |sig| {
		// sigaddset() is posix standard, not sure why it's std.os.linux?
		std.os.linux.sigaddset(&set, sig);
	}

	// We have to block a signal to be able to handle it as a file.
	std.posix.sigprocmask(std.c.SIG.BLOCK, &set, null);
	// And on the other hand, signalfd() is a Linux syscall, and not posix at all.
	const filedes = std.posix.signalfd(-1, &set, std.os.linux.SFD.NONBLOCK);
	return filedes;
}

pub fn streql(lhs: []const u8, rhs: []const u8) bool
{
	return std.mem.eql(u8, lhs, rhs);
}

pub fn printUsage() void
{
	const stdout = std.io.getStdOut();
	stdout.writer().writeAll(
		// This is *the* worst multiline syntax.
		\\Usage: floatty <program> <args...>
		\\
		\\OPTIONS:
		\\  --help     display this help message and exit
		\\  --version  display version information and exit
		\\
	) catch |e| {
		// If we can't write to stdout for even the help message, then we might as well
		// at least let the caller process know *something* went wrong.
		// Writing to stderr probably won't work either, but we'll throw an attempt in anyway.
		eprintln("floatty: error writing help message to stdout: {}", .{ e });
		std.process.exit(254);
	};
}

/// Reads and executes a callback on each buffer read until a read would block.
fn readAndDo(
	reader: anytype,
	handler: type,
) (@TypeOf(reader).Error || handler.Error)!void
{
	var buffer = std.mem.zeroes([4096]u8);
	var count: usize = 1;
	while (count > 0) {
		if (reader.read(&buffer)) |amount_read| {
			count = amount_read;
		} else |err| switch (err) {
			error.WouldBlock => return,
			else => |e| return e,
		}

		try handler.callback(buffer[0..count]);
	}
}

const printHandler = struct{
	const Error = std.fs.File.WriteError;
	fn callback(buffer: []const u8) std.fs.File.WriteError!void
	{
		try std.io.getStdOut().writeAll(buffer);
	}
};

/// Reads and discards until a read would block.
fn readAndDiscard(reader: anytype) !void
{
	var buffer = std.mem.zeroes([4096]u8);
	while (true) {
		_ = reader.read(&buffer) catch |e| switch (e) {
			error.WouldBlock => return,
			else => return e,
		};
	}
}

pub fn main() !void
{
	const allocator = std.heap.c_allocator;

	var arglist = try collectArgs(allocator);
	defer arglist.deinit();

	if (arglist.asSlice().len < 2) {
		eprintln(
			\\floatty: error: the following required arguments were not provided:
			\\  <program>
			\\
			,
			.{}
		);
		printUsage();
		std.process.exit(255);
	}

	// Shitty, shotgun arg parser.
	for (arglist.asSlice()[1..]) |arg| {
		const argSlice: []const u8 = arg[0..std.mem.len(arg)];
		// We can't take any --options after accepting positional arguments, so that
		// we don't interpret things like `floatty ls --help` as `--help` for us.
		if (argSlice[0] != '-') {
			break;
		}

		if (streql(argSlice, "--help")) {
			printUsage();
			std.process.exit(0);
		}

		if (streql(argSlice, "--version")) {
			println("floatty 0.0.1", .{});
			std.process.exit(0);
		}

		eprintln(
			"floatty: unrecognized option '{s}'\nTry 'floatty --help' for more information",
			.{ argSlice },
		);
		std.process.exit(255);

		// Yes this loop can only ever do one iteration, technically.
		// I'll (maybe) add more args later.
	}

	log.debug("args: {}", .{ arglist });

	const pty_fd: c_int = try openpt(.BecomeNonControllingTerminal);
	defer std.posix.close(pty_fd);
	_ = try std.posix.fcntl(pty_fd, std.c.F.SETFL, std.os.linux.IN.NONBLOCK);

	// ioctl TIOCSPTLCK
	try unlockpt(pty_fd);

	// ioctl TIOCGPTN "get pty number"
	// FIXME: use TIOCGPTPEER instead
	const term_name = try ptsname(allocator, pty_fd);
	defer allocator.free(term_name);
	log.debug("Our terminal is {s}", .{ term_name });

	const other_side = try std.posix.open(term_name, .{ .NOCTTY = false, .ACCMODE = .RDWR }, 0);
	defer std.posix.close(other_side);

	log.debug("Got file descriptors {} and {}", .{ pty_fd, other_side });

	const parent_winsize = try getwinsz(std.posix.STDIN_FILENO);
	log.debug("our win size: {}", .{ parent_winsize });

	const child_winsize = try getwinsz(other_side);
	log.debug("winsize: {}", .{ child_winsize });

	// Spawn a new process, and then use setsid() and TIOCSCTTY to make this terminal
	// the controlling terminal for that process.
	const pid = try std.posix.fork();
	if (pid == 0) {
		// Child code...

		std.posix.close(pty_fd);

		// Become a session leader...
		_ = try setsid();

		// ...and take our terminal as this session's terminal.
		try csctty(other_side);

		// Set stdout, and stderr for this child process to the pty.
		// TODO: should this also set stdin?
		inline for (.{ STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO }) |fileno| {
			try std.posix.dup2(other_side, fileno);
		}

		// I totally don't get why this is here but all PTY code we've found does this.
		std.posix.close(other_side);

		const argsSlice: [:null]const ?CString = arglist.asTerminatedSlice();
		const first = argsSlice[1] orelse unreachable;
		const argv: [*:null]const ?CString = argsSlice[1..];
		const envp: [*:null]const ?CString = std.c.environ;
		return std.posix.execvpeZ(first, argv, envp);
	}

	// Parent code...

	log.debug("forked to process {}", .{ pid });

	const pty_file = std.fs.File{ .handle = pty_fd };
	const pty_reader = pty_file.reader();

	// Switch to file descriptor based handling for SIGCHLD.
	const sigchld_fd = try handleSignalAsFile(&.{ std.posix.SIG.CHLD });
	defer std.posix.close(sigchld_fd);
	const sigchld_file = std.fs.File{ .handle = sigchld_fd };

	const sigwinch_fd = try handleSignalAsFile(&.{ std.posix.SIG.WINCH });
	defer std.posix.close(sigwinch_fd);
	const sigwinch_file = std.fs.File{ .handle = sigwinch_fd };

	// Now setup polling for both the pty and the sigchld file descriptors.
	const poller = try BasicPoller.init(allocator, &.{ pty_fd, sigchld_fd, sigwinch_fd });
	defer poller.deinit();

	// And startup our poll-based event loop.
	var keep_going = true;
	while (keep_going) {
		const fd_list: std.ArrayList(std.posix.fd_t) = try poller.next(-1) orelse break;
		defer fd_list.deinit();

		for (fd_list.items) |fd| {
			if (fd == pty_fd) {
				try readAndDo(pty_reader, printHandler);
			} else if (fd == sigwinch_fd) {
				// Read and discard to clear the "event" from our poller.
				try readAndDiscard(sigwinch_file.reader());
			} else if (fd == sigchld_fd) {
				// We don't want to break immediately, because we could still have non-signal
				// events left to handle.
				keep_going = false;
				// Read and discard to clear the "event" from our poller.
				try readAndDiscard(sigchld_file.reader());
			} else unreachable;
		}
	}

	defer {
		const status = std.posix.waitpid(pid, 0);
		log.info("waitpid() returned {}", .{ status });
	}
}
