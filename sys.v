module main

// Platform-independent parts of the sys layer: file identity and the
// incomplete-UTF-8-tail scanner shared by the per-platform read_stdin()
// implementations (sys_nix.c.v / sys_windows.c.v).

// FileId uniquely identifies a file by device and inode.
pub struct FileId {
	st_dev u64
	st_ino u64
}

pub fn (a FileId) == (b FileId) bool {
	return a.st_dev == b.st_dev && a.st_ino == b.st_ino
}


// split_incomplete_utf8_tail finds the length of the trailing, potentially
// incomplete UTF-8 sequence at the end of buf. Returns 0 if the buffer ends
// on a complete boundary (or the lead byte found isn't actually one, in which
// case utf8_lossy will replace it with U+FFFD).
// Factored out of read_stdin() for testability.
fn incomplete_utf8_tail_len(buf []u8) int {
	if buf.len == 0 {
		return 0
	}
	// We only need to check the last 3 bytes for UTF-8 continuation bytes,
	// because we can assume that any 4 byte sequence is complete.
	lim := if buf.len >= 3 { buf.len - 3 } else { 0 }
	mut off := buf.len - 1

	// Find the start of the last potentially incomplete UTF-8 sequence.
	for off > lim && buf[off] & 0b1100_0000 == 0b1000_0000 {
		off--
	}

	b := buf[off]
	mut seq_len := 0
	if b & 0b1000_0000 == 0 {
		seq_len = 1
	} else if b & 0b1110_0000 == 0b1100_0000 {
		seq_len = 2
	} else if b & 0b1111_0000 == 0b1110_0000 {
		seq_len = 3
	} else if b & 0b1111_1000 == 0b1111_0000 {
		seq_len = 4
	}
	// If the lead byte we found isn't actually one, we don't cache it
	// (seq_len stays 0); utf8_lossy will replace it with U+FFFD.

	if seq_len > 0 && off + seq_len > buf.len {
		return buf.len - off
	}
	return 0
}

