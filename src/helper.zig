const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn requireCloneable(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => {},
        else => @compileError("AtomicShared(" ++ @typeName(T) ++ "): T must be a struct, union or enum"),
    }
    if (!@hasDecl(T, "clone"))
        @compileError("AtomicShared(" ++ @typeName(T) ++ "): T has no `clone`");
    if (!@hasDecl(T, "release"))
        @compileError("AtomicShared(" ++ @typeName(T) ++ "): T has no `release`");

    // 直接比较函数类型：参数名不影响类型，且不依赖 @typeInfo
    // 的字段布局（各 Zig 版本间有变动）。
    if (@TypeOf(T.clone) != fn (*const T, Allocator) Allocator.Error!T) {
        @compileError("AtomicShared(" ++ @typeName(T) ++ "): `clone` has an incompatible signature: " ++
            @typeName(@TypeOf(T.clone)));
    }
    if (@TypeOf(T.release) != fn (*T, Allocator) void) {
        @compileError("AtomicShared(" ++ @typeName(T) ++ "): `release` has an incompatible signature: " ++
            @typeName(@TypeOf(T.release)));
    }
}
