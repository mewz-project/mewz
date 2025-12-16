const log = @import("log.zig");
const virtio_vaccel = @import("drivers/virtio/vaccel.zig");

pub fn vaccel_session_init() u32 {
    const out_args = [_]virtio_vaccel.AccelArg{};
    const in_args = [_]virtio_vaccel.AccelArg{};
    const result = virtio_vaccel.virtio_vaccel.createSession(&out_args, &in_args);
    log.info.printf("virtio-vaccel: create session result: status={}, session_id={}\n", .{result.status, result.session_id});
    return result.session_id;
}

pub fn vaccel_no_op(session_id: u32) u32 {
    var op_buf: [1]u8 = .{0};
    const out_arg = virtio_vaccel.AccelArg{
        .buf = op_buf[0..].ptr, 
        .len = 1,
    };
    const in_args = [_]virtio_vaccel.AccelArg{};
    const status = virtio_vaccel.virtio_vaccel.doOp(session_id, &.{out_arg}, &in_args);
    log.info.printf("virtio-vaccel: no_op result: status={}\n", .{status});
    return status;
}