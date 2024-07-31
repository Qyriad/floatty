const std = @import("std");

/// Not to be confused with null.
const NUL: u8 = 0;

pub const ContainerDecl = struct{
	const Self = @This();
	const Opaque: type = opaque{};

	name: [:NUL]const u8,
	type: type,
	value: *const Opaque,

	pub fn getFrom(comptime T: type) [std.meta.declarations(T).len]Self
	{
		const raw_decls = std.meta.declarations(T);
		var selves: [raw_decls.len]Self = undefined;
		for (raw_decls, 0..) |decl, idx| {
			const value = &@field(T, decl.name);
			selves[idx] = .{
				.name = decl.name,
				.type = @TypeOf(value.*),
				.value = @ptrCast(value),
			};
		}

		return selves;
	}

	/// Returns the value of this declaration if `T` matches the value's type.
	pub fn valueIfType(self: Self, comptime T: type) ?*const T
	{
		if (self.type != T) {
			return null;
		}

		return @ptrCast(self.value);
	}
};
