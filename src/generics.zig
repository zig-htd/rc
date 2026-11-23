const std = @import("std");
const Allocator = std.mem.Allocator;
const helper = @import("helper.zig");

pub fn AtomicShared(comptime T: type) type {
    helper.requireCloneable(T);

    return struct {
        pub const __super__ = .atomic_shared; // 让外部可以判断它是 AtomicShared
        const Self = @This();

        const Storage = union(enum) {
            /// from 创建：值嵌在控制块里，由 AtomicShared 拥有。
            owned: T,
            /// fromOwned 创建：只是外部数据的指针。
            borrowed: *T,
        };

        const Inner = struct {
            count: std.atomic.Value(usize),
            storage: Storage,
        };

        inner: *Inner, // 所有副本都将指向一个 inner 实例

        /// 深克隆 `src`，AtomicShared 拥有数据拷贝。初始计数为 `1`。
        pub fn new(allocator: Allocator, src: *const T) Allocator.Error!Self {
            const inner = try allocator.create(Inner);
            errdefer allocator.destroy(inner);
            inner.* = .{
                .count = .init(1),
                .storage = .{ .owned = try src.clone(allocator) },
            };
            return .{ .inner = inner };
        }

        /// 借用外部数据，不克隆、但接管释放。初始计数为 `1`。
        pub fn fromOwned(allocator: Allocator, data: *T) Allocator.Error!Self {
            const inner = try allocator.create(Inner);
            inner.* = .{
                .count = .init(1),
                .storage = .{ .borrowed = data },
            };
            return .{ .inner = inner };
        }

        /// 用原子加法增加共享引用。
        pub fn retain(self: Self) void {
            const previous = self.inner.count.fetchAdd(1, .monotonic);
            std.debug.assert(previous > 0);
        }

        /// 用 release/acquire 顺序同步最后一次释放后，再销毁共享数据。
        pub fn release(self: Self, allocator: Allocator) void {
            const inner = self.inner;
            const previous = inner.count.fetchSub(1, .release);
            std.debug.assert(previous > 0);
            if (previous != 1) return;

            _ = inner.count.load(.acquire);
            switch (inner.storage) {
                .owned => |*value| value.release(allocator),
                .borrowed => |value| value.release(allocator), // 借用也释放，因为所有权被接管了
            }
            allocator.destroy(inner);
        }

        /// 只读访问。
        pub fn get(self: Self) *const T {
            return switch (self.inner.storage) {
                .owned => |*value| value,
                .borrowed => |ptr| ptr,
            };
        }

        /// 可变访问。
        pub fn getMut(self: Self) *T {
            return switch (self.inner.storage) {
                .owned => |*value| value,
                .borrowed => |ptr| ptr,
            };
        }

        pub fn strongCount(self: Self) usize {
            return self.inner.count.load(.monotonic);
        }

        pub fn isOwned(self: Self) bool {
            return self.inner.storage == .owned;
        }
    };
}

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

const ArcPerson = AtomicShared(Person);

test "__super__ is generated" {
    try testing.expect(ArcPerson.__super__ == .atomic_shared);
}

test "new deep-clones the value and outlives the source" {
    const a = testing.allocator;

    var p1 = try Person.init(a, "Alice", 30);
    const shared_p = try ArcPerson.new(a, &p1);

    // 原数据销毁后，Rc 里的克隆体依然有效
    p1.release(a);

    try testing.expectEqualStrings("Alice", shared_p.get().name);
    try testing.expectEqual(@as(u32, 30), shared_p.get().age);
    try testing.expect(shared_p.isOwned());

    shared_p.release(a); // 计数 1 -> 0；testing.allocator 会检查泄漏
}

test "retain and release track the count" {
    const a = testing.allocator;

    var p1 = try Person.init(a, "Bob", 20);
    defer p1.release(a);

    const shared_p1 = try ArcPerson.new(a, &p1);
    try testing.expectEqual(@as(usize, 1), shared_p1.strongCount());
    // retain 只增加计数；复制句柄后，每份引用各自负责一次释放。
    shared_p1.retain();
    try testing.expectEqual(@as(usize, 2), shared_p1.strongCount());
    const shared_p2 = shared_p1;
    shared_p2.retain();
    try testing.expectEqual(@as(usize, 3), shared_p2.strongCount());

    // 共享同一份数据
    try testing.expect(shared_p1.get() == shared_p2.get());

    shared_p1.release(a);
    try testing.expectEqual(@as(usize, 2), shared_p1.strongCount());
    shared_p1.release(a);
    try testing.expectEqual(@as(usize, 1), shared_p1.strongCount());
    shared_p1.release(a); // 真正释放
}

test "atomic reference counting is safe across threads" {
    const a = testing.allocator;
    var person = try Person.init(a, "Threads", 1);
    defer person.release(a);

    const rc = try ArcPerson.new(a, &person);
    defer rc.release(a);

    const Worker = struct {
        fn run(shared: ArcPerson, allocator: Allocator) void {
            defer shared.release(allocator);

            var i: usize = 0;
            while (i < 100_000) : (i += 1) {
                shared.retain();
                _ = shared.strongCount();
                shared.release(allocator);
            }
        }
    };

    // 在线程启动前为它保留引用，确保工作期间控制块始终存活。
    rc.retain();
    const thread = std.Thread.spawn(.{}, Worker.run, .{ rc, a }) catch |err| {
        rc.release(a);
        return err;
    };

    var i: usize = 0;
    while (i < 100_000) : (i += 1) {
        rc.retain();
        _ = rc.strongCount();
        rc.release(a);
    }

    thread.join();
    try testing.expectEqual(@as(usize, 1), rc.strongCount());
}

test "fromOwned borrows the data and takes responsibility for release" {
    const a = testing.allocator;

    var person = try Person.init(a, "Carol", 41);

    const rc = try ArcPerson.fromOwned(a, &person);
    rc.retain();
    const rc2 = rc;

    try testing.expect(!rc.isOwned());
    try testing.expect(rc.get() == &person); // 同一地址：没有发生克隆
    try testing.expectEqual(@as(usize, 2), rc.strongCount());

    rc.release(a);
    defer rc2.release(a);
    try testing.expectEqual(@as(usize, 1), rc2.strongCount());
    try testing.expectEqualStrings("Carol", person.name);
}

test "plain-data type with trivial clone and release" {
    const Point = struct {
        const Self = @This();

        x: i32,
        y: i32,

        pub fn clone(self: *const Self, _: Allocator) Allocator.Error!Self {
            return self.*;
        }
        pub fn release(_: *Self, _: Allocator) void {}
    };

    const a = testing.allocator;
    const point: Point = .{ .x = 3, .y = 4 };
    const rc = try AtomicShared(Point).new(a, &point);
    defer rc.release(a);

    try testing.expectEqual(@as(i32, 4), rc.get().y);
}

test "new does not leak when an allocation fails" {
    var person = try Person.init(testing.allocator, "Dave", 50);
    defer person.release(testing.allocator);

    // 依次让第 0..3 次分配失败，覆盖各个失败点
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var fa = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        const a = fa.allocator();
        if (ArcPerson.new(a, &person)) |rc| {
            rc.release(a);
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        }
    }
}
