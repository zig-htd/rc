# rc

rc 提供基于引用计数的数据容器，解决数据共享后的释放难题。

## 安装

添加依赖到 `build.zig.zon`：

```sh
zig fetch --save git+https://github.com/zig-htd/rc
```

添加模块到 `build.zig`：

```zig
const rc = b.dependency("rc", .{});
// ...
exe.root_module.addImport("rc", rc.module("rc"));
```

## 使用

需要共享的数据：

```zig
const Data = struct {
    bytes: []u8,

    /// 实现 `rc.Interface.clone`
    pub fn clone(self: *const Data, allocator: Allocator) Allocator.Error!Data {
        // 返回一个深克隆的副本
        return .{
            bytes = try allocator.dupe(u8, self.bytes)
        };
    }

    /// 实现 `rc.Interface.release`
    pub fn release(self: *Data, allocator: Allocator) void {
        // 释放内存（类似于 deinit，或者在这里调用自己的 deinit）
        allocator.free(self.bytes);
        self.* = undefined;
    }
};
```

自增引用并共享：

```zig
// 基于 Data 创建一个共享的数据类型
const AtomicSharedData = rc.AtomicShared(Data);
// 创建共享数据
const data: Data = .{ .bytes = try allocator.dupe(u8, "some_bytes") };
var shared_data: AtomicSharedData = try .fromOwned(&data, allocator);
// var shared_data: AtomicSharedData = try .new(&data, allocator);  // 另一种形式，使用 `.new` 深克隆原数据（容器将拥有数据）
// defer data.release(allocator);                                   // 如果使用 `.new` 创建共享数据，需释放原数据

// 自增引用并发送给多个消费者
for (consumer in consumers) {
    shared_data.retain();                   // 共享前增加引用计数
    consumer.push(shared_data) catch {      // 数据释放将移交给 consumer
        shared_data.release(allocator);     // 共享失败，调用 release 撤销此次共享
    }
}
```

所有消费端一律释放，不用额外考虑（如另一方是否释放过）：

```zig
for (consumer in consumers) {
    const shared_data: AtomicSharedData = try consumer.get();
    shared_data.release(allocator);         // 消费端释放
}
```

当 rc 容器内部的计数器归零时，内存才会被释放（即 `Data.release` 被真正调用）。否则 `AtomicShared.release` 只是减少了引用计数。

## 其它

本库还提供了 `AnyAtomicShared` 这种可以存储任意类型共享数据的容器，要求数据类型实现 `rc.Interface` 即可。用例如下：

```zig
// 创建不同类型的数据
var foo = try Foo.init(a, "FooData");
defer foo.deinit(a);
var bar = try Bar.init(a, "BarData");
defer bar.deinit(a);
// 将它们包装成 AnyAtomicShared
const shared_foo = try rc.AnyAtomicShared.new(a, &foo);
const shared_bar = try rc.AnyAtomicShared.new(a, &bar);
// 放到一个容器中
const list: [2]rc.AnyAtomicShared = .{ shared_foo, shared_bar };
for (list) |item| {
    // 即使 item 的原始数据类型不同，但 AnyAtomicShared
    // 容器提供了统一的原语和类型兼容
    item.release(a);
}
```
