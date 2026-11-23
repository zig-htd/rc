const std = @import("std");
const Allocator = std.mem.Allocator;
const AtomicShared = @import("generics.zig").AtomicShared;
pub const Interface = @import("Interface.zig");
pub const VTable = Interface.VTable;

pub const AnyAtomicShared = struct {
    shared: AtomicShared(Interface),

    /// 深克隆 `src`，内部 AtomicShared 拥有数据拷贝。初始计数为 `1`。
    pub fn new(allocator: Allocator, ptr: anytype) Allocator.Error!AnyAtomicShared {
        const P = @TypeOf(ptr);
        const info = @typeInfo(P);

        comptime {
            if (info != .pointer or info.pointer.size != .one) {
                @compileError("AnyAtomicShared.new expects a single-item pointer, found '" ++ @typeName(P) ++ "'");
            }
        }

        const T = info.pointer.child;
        const interface: Interface = .{
            .ptr = ptr,
            .vtable = VTable.from(T),
        };
        return .{
            .shared = try AtomicShared(Interface).new(allocator, &interface),
        };
    }

    /// 增加共享引用计数；如需多个句柄，调用方可以自行复制。
    pub fn retain(self: *const AnyAtomicShared) void {
        self.shared.retain();
    }

    /// 将引用释放操作委托给内部通用 Rc。
    pub fn release(self: *const AnyAtomicShared, allocator: Allocator) void {
        self.shared.release(allocator);
    }

    /// 查询内部 AtomicShared 的共享引用数。
    pub fn strongCount(self: *const AnyAtomicShared) usize {
        return self.shared.strongCount();
    }

    /// 查询内部 AtomicShared 是否拥有克隆后的接口值。
    pub fn isOwned(self: *const AnyAtomicShared) bool {
        return self.shared.isOwned();
    }

    /// 按创建接口值时对应的具体类型取回只读指针。
    pub fn get(self: *const AnyAtomicShared, comptime T: type) *const T {
        return @ptrCast(@alignCast(self.shared.get().ptr));
    }
};

// -- tests --
const testing = std.testing;

/// 持有堆内存的示例类型，用来验证深克隆与释放。
const Person = struct {
    name: []u8,
    age: u32,

    fn init(allocator: Allocator, name: []const u8, age: u32) !Person {
        return .{ .name = try allocator.dupe(u8, name), .age = age };
    }

    pub fn clone(self: *const Person, allocator: Allocator) Allocator.Error!Person {
        return .{ .name = try allocator.dupe(u8, self.name), .age = self.age };
    }

    pub fn release(self: *Person, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

test "AnyAtomicShared delegates ownership and reference counting to AtomicShared" {
    const allocator = testing.allocator;
    var p1 = try Person.init(allocator, "Eve", 28);
    const shared_p1 = try AnyAtomicShared.new(allocator, &p1);
    try testing.expectEqual(@as(usize, 1), shared_p1.strongCount());
    // retain 只增加计数，复制后的结构体共享同一块内部数据。
    shared_p1.retain();
    const shared_p2 = shared_p1;

    p1.release(allocator);

    try testing.expectEqualStrings("Eve", shared_p2.get(Person).name);
    try testing.expectEqual(@as(usize, 2), shared_p1.strongCount());
    shared_p1.release(allocator);
    try testing.expectEqual(@as(usize, 1), shared_p2.strongCount());
    try testing.expectEqualStrings("Eve", shared_p2.get(Person).name);
    shared_p2.release(allocator);
}
