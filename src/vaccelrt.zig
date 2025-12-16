const log = @import("log.zig");
const virtio_vaccel = @import("drivers/virtio/vaccel.zig");

pub fn vaccel_session_init() u32 {
    const out_args = [_]virtio_vaccel.AccelArg{};
    const in_args = [_]virtio_vaccel.AccelArg{};
    const result = virtio_vaccel.virtio_vaccel.createSession(&out_args, &in_args);
    log.info.printf("virtio-vaccel: create session result: status={}, session_id={}\n", .{result.status, result.session_id});
    return result.session_id;
}