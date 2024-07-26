const std = @import("std");

/// Not to be confused with null.
pub const NUL: u8 = 0;

pub const CString = [*:NUL]const u8;

pub fn TerminatedArrayList(comptime T: type, comptime sentinel_value: ?T) type
{
	return struct{
		const Self = @This();
		const Item = T;
		const InnerList = std.ArrayList(?Item);
		const sentinel = sentinel_value;

		inner: InnerList,

		pub fn init(allocator: std.mem.Allocator) !Self
		{
			var list = InnerList.init(allocator);
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
			// If we set the last item before doing the append, and the append failed,
			// then we'd have an arraylist where the last element isn't the sentinel
			// terminator.
			try self.inner.append(null);
			last.* = item;
		}

		/// The number of *items* in this arraylist -- so NOT including the sentinel.
		pub fn count(self: Self) usize
		{
			return self.inner.items.len - 1;
		}

		/// The number of slots this arraylist is using -- so INCLUDING the sentinel.
		///
		/// Not to be confused with the capacity of the inner ArrayList.
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

		/// Helper type constructed with [Self.formatter], to allow formatting this type
		/// as an array, using `itemfmt` as the format specifier for each item.
		pub fn Formatter(comptime itemfmt: []const u8) type
		{
			return struct{
				const FmtSelf = @This();
				const Inner = Self;

				inner: *const Inner,

				pub fn format(self: FmtSelf, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void
				{
					if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
					if (self.inner.count() < 1) {
							return;
					}

					try std.fmt.format(writer, "{s}", .{ "{ " });

					const slice: []Inner.Item = self.inner.asSlice();
					std.debug.assert(slice.len == self.inner.count());

					for (slice, 0..) |arg, idx| {
							try std.fmt.format(writer, itemfmt, .{ arg });
							if (idx < slice.len - 1) {
									try std.fmt.format(writer, "{s}", .{ ", "});
							}
					}
					try std.fmt.format(writer, "{s}", .{ " }" });
				}
			};
		}

		/// Construct a type which can be passed to [std.fmt.format] and other Zig
		/// formatting functions, to format this arraylist like an array, using
		/// `itemfmt` as the format specifier for each item in the list.
		///
		/// e.g., to format a TerminatedArrayList of C-strings:
		/// ```zig
		/// std.debug.print("{}", someList.formatter("{s}"));
		/// ```
		pub fn formatter(self: *Self, comptime itemfmt: []const u8) Formatter(itemfmt)
		{
			return Formatter(itemfmt){
				.inner = self,
			};
		}
	};
}

pub const CStringCArray = TerminatedArrayList(CString, null);
