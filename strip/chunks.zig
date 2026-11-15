//! ike-chunks: the PNG and WebP half of hazard P7's stripping. Reads one
//! image on stdin, writes it to stdout with only the chunks needed to
//! show it, in their order, and nothing after its end. Allowlist, not
//! denylist: whatever is not named here is dropped. Exits 0 with the
//! image, or 2 with a reason on stderr for anything it will not take.
//! It runs as its own process, never in ike's VM (invariant 6).
const std = @import("std");
const linux = std.os.linux;

/// bytes; the driver holds input to less than this
const max_input: usize = 64 << 20;

const Refusal = error{ NotAnImage, Truncated, Malformed, Animated, TooLarge };

fn readAll(buf: []u8) !usize {
    var n: usize = 0;
    while (n < buf.len) {
        const got = try std.posix.read(0, buf[n..]);
        if (got == 0) return n;
        n += got;
    }
    return error.TooLarge;
}

fn writeAll(fd: i32, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

fn be32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}

fn le32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}

/// what is written, appended to a buffer sized for it beforehand
const Out = struct {
    buf: []u8,
    len: usize = 0,

    fn put(self: *Out, bytes: []const u8) void {
        @memcpy(self.buf[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn putLe32(self: *Out, v: u32) void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        self.put(&b);
    }
};

const png_signature = "\x89PNG\r\n\x1a\n";

/// what a still image needs to be shown as its encoder meant it
const png_keep = [_]*const [4]u8{ "IHDR", "PLTE", "IDAT", "IEND", "tRNS", "gAMA", "cHRM", "sRGB" };

fn png(in: []const u8, out: *Out) Refusal!void {
    out.put(png_signature);
    var pos: usize = png_signature.len;
    var first = true;
    var idat = false;
    while (true) {
        if (in.len - pos < 12) return error.Truncated;
        const length = be32(in[pos..]);
        if (length > in.len - pos - 12) return error.Truncated;
        const kind = in[pos + 4 .. pos + 8];
        const total = 12 + @as(usize, length);
        if (first and !(std.mem.eql(u8, kind, "IHDR") and length == 13)) return error.Malformed;
        first = false;
        for (png_keep) |name| {
            if (std.mem.eql(u8, kind, name)) {
                out.put(in[pos .. pos + total]);
                break;
            }
        }
        if (std.mem.eql(u8, kind, "IDAT")) idat = true;
        // the end: whatever follows it is not the image
        if (std.mem.eql(u8, kind, "IEND")) break;
        pos += total;
    }
    if (!idat) return error.Malformed;
}

fn webpChunk(out: *Out, fourcc: []const u8, data: []const u8) void {
    out.put(fourcc);
    out.putLe32(@intCast(data.len));
    out.put(data);
    // a chunk is padded to an even length, with a zero
    if (data.len % 2 == 1) out.put(&[_]u8{0});
}

fn webpSize(data_len: usize) usize {
    return 8 + data_len + data_len % 2;
}

fn webp(in: []const u8, out: *Out) Refusal!void {
    if (in.len < 12) return error.Truncated;
    const riff = le32(in[4..]);
    if (riff < 4 or riff > in.len - 8) return error.Truncated;
    // the riff's own length ends it, whatever comes after
    const end = 8 + @as(usize, riff);
    var pos: usize = 12;
    var bitstream: ?[]const u8 = null;
    var lossless = false;
    var alpha: ?[]const u8 = null;
    var canvas: ?[]const u8 = null;
    while (pos < end) {
        if (end - pos < 8) return error.Truncated;
        const fourcc = in[pos .. pos + 4];
        const size: usize = le32(in[pos + 4 ..]);
        if (size > end - pos - 8) return error.Truncated;
        const data = in[pos + 8 .. pos + 8 + size];
        if (std.mem.eql(u8, fourcc, "VP8X")) {
            if (size < 10) return error.Malformed;
            if (data[0] & 0x02 != 0) return error.Animated;
            canvas = data[4..10];
        } else if (std.mem.eql(u8, fourcc, "ANIM") or std.mem.eql(u8, fourcc, "ANMF")) {
            return error.Animated;
        } else if (std.mem.eql(u8, fourcc, "ALPH")) {
            if (alpha == null) alpha = data;
        } else if (std.mem.eql(u8, fourcc, "VP8 ") or std.mem.eql(u8, fourcc, "VP8L")) {
            if (bitstream == null) {
                bitstream = data;
                lossless = fourcc[3] == 'L';
            }
        }
        pos += 8 + size + size % 2;
        if (pos > end) pos = end;
    }
    const image = bitstream orelse return error.Malformed;
    const fourcc: []const u8 = if (lossless) "VP8L" else "VP8 ";
    out.put("RIFF");
    if (lossless or alpha == null) {
        // the simple format: the bitstream and nothing else
        out.putLe32(@intCast(4 + webpSize(image.len)));
        out.put("WEBP");
        webpChunk(out, fourcc, image);
    } else {
        // lossy with an alpha channel needs the extended header, and it
        // says no more than that
        const size = canvas orelse return error.Malformed;
        const a = alpha.?;
        out.putLe32(@intCast(4 + webpSize(10) + webpSize(a.len) + webpSize(image.len)));
        out.put("WEBP");
        var header = [_]u8{ 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        @memcpy(header[4..10], size);
        webpChunk(out, "VP8X", &header);
        webpChunk(out, "ALPH", a);
        webpChunk(out, fourcc, image);
    }
}

fn refuse(reason: []const u8) noreturn {
    writeAll(2, reason) catch {};
    writeAll(2, "\n") catch {};
    linux.exit(2);
}

pub fn main() void {
    const in_buf = std.heap.page_allocator.alloc(u8, max_input) catch refuse("no memory");
    const n = readAll(in_buf) catch |e| switch (e) {
        error.TooLarge => refuse("too large"),
        else => refuse("unreadable"),
    };
    const in = in_buf[0..n];
    // never longer than what came in, but for a header of 18 bytes
    const out_buf = std.heap.page_allocator.alloc(u8, n + 64) catch refuse("no memory");
    var out = Out{ .buf = out_buf };
    const result = if (n >= 8 and std.mem.eql(u8, in[0..8], png_signature))
        png(in, &out)
    else if (n >= 12 and std.mem.eql(u8, in[0..4], "RIFF") and std.mem.eql(u8, in[8..12], "WEBP"))
        webp(in, &out)
    else
        error.NotAnImage;
    result catch |e| refuse(@errorName(e));
    writeAll(1, out.buf[0..out.len]) catch linux.exit(1);
}
