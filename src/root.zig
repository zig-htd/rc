const std = @import("std");
const generics = @import("generics.zig");
const presets = @import("presets.zig");

pub const AtomicShared = generics.AtomicShared;
pub const AnyAtomicShared = presets.AnyAtomicShared;
pub const Interface = @import("Interface.zig");

pub const super_flag = "__super__";

/// 判断任意输入（类型或值，如数字）是否为 AtomicShared。
pub fn isAtomicShared(comptime input: anytype) bool {
    // 输入本身是类型就直接使用，否则取值的类型（数字等值会落到非 struct 分支）
    const T = if (@TypeOf(input) == type) input else @TypeOf(input);

    // 只有 struct 才可能是 AtomicShared
    // 其余一律返回 false（@hasDecl 对数字等类型会编译报错）
    if (@typeInfo(T) != .@"struct") return false;

    return @hasDecl(T, super_flag) and @field(T, super_flag) == .atomic_shared;
}

const testing = std.testing;

test {
    try testing.expect(isAtomicShared(struct {
        pub const __super__ = .atomic_shared;
    }));
    try testing.expect(!isAtomicShared(enum {}));
    try testing.expect(!isAtomicShared(union {}));
    try testing.expect(!isAtomicShared(union(enum) {}));
    try testing.expect(!isAtomicShared(struct {}));
    try testing.expect(!isAtomicShared(1));
    try testing.expect(!isAtomicShared(u32));
    try testing.expect(!isAtomicShared(@as(f32, 1.5)));

    _ = generics;
    _ = presets;
}
