const std = @import("std");
const Allocator = std.mem.Allocator;
const rc = @import("zig_rc");

const Person = struct {
    name: []u8,

    pub fn init(allocator: Allocator, name: []const u8) !Person {
        return .{ .name = try allocator.dupe(u8, name) };
    }

    pub fn deinit(self: *Person, allocator: Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }

    /// 实现 `rc.Interface.clone`
    pub fn clone(self: *const Person, allocator: Allocator) Allocator.Error!Person { // 返回一个深克隆的副本
        return Person.init(allocator, self.name);
    }

    /// 实现 `rc.Interface.release`
    pub fn release(self: *Person, allocator: Allocator) void { // 通常，让 release 调用 deinit 即可
        self.deinit(allocator);
    }
};

const Student = struct {
    name: []u8,

    pub fn init(allocator: Allocator, name: []const u8) !Student {
        return .{ .name = try allocator.dupe(u8, name) };
    }

    pub fn deinit(self: *Student, allocator: Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }

    /// 实现 `rc.Interface.clone`
    pub fn clone(self: *const Student, allocator: Allocator) Allocator.Error!Student { // 返回一个深克隆的副本
        return Student.init(allocator, self.name);
    }

    /// 实现 `rc.Interface.release`
    pub fn release(self: *Student, allocator: Allocator) void { // 通常，让 release 调用 deinit 即可
        self.deinit(allocator);
    }
};

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;

    // -- AtomicShared 的基本用法 --
    const AtomicSharedPerson = rc.AtomicShared(Person);
    // 用 new 创建 AtomicShared 实例
    var src1 = try Person.init(a, "Alice");
    defer src1.deinit(a); // new 会在 AtomicShared 内部深拷贝一份，所以原始数据仍要释放
    var shared_p1 = try AtomicSharedPerson.new(a, &src1);
    defer shared_p1.release(a);
    shared_p1.retain(); // 引用 +1
    defer shared_p1.release(a); // 再次释放，最终计数回到 0

    // 用 fromOwned 创建 AtomicShared 实例
    var src2 = try Person.init(a, "Bob");
    // defer src2.deinit(a); // fromOwned 接管了释放责任，不需要再手动释放
    var shared_p2 = try AtomicSharedPerson.fromOwned(a, &src2);
    defer shared_p2.release(a);

    // -- AnyAtomicShared 的基本用法 --
    var src3 = try Person.init(a, "Charlie");
    defer src3.deinit(a);
    var src4 = try Student.init(a, "Dave");
    defer src4.deinit(a);
    const shared_p3 = try rc.AnyAtomicShared.new(a, &src3);
    const shared_s1 = try rc.AnyAtomicShared.new(a, &src4);
    // 放到一个容器中
    const list: [2]rc.AnyAtomicShared = .{ shared_p3, shared_s1 };
    for (list) |item| {
        // 即使 item 的原始数据类型不同，但 AnyAtomicShared
        // 容器提供了统一的原语和类型兼容
        item.release(a);
    }
}
