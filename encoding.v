module main

import encoding.iconv

// EncodingInfo is the deliberately small, portable encoding set exposed by
// the first-version picker. iconv supplies the conversion backend on macOS and
// Linux; the editor core continues to store only valid UTF-8.
struct EncodingInfo {
	label     string
	canonical string
}

const editor_encodings = [
	EncodingInfo{ label: 'UTF-8', canonical: 'UTF-8' },
	EncodingInfo{ label: 'UTF-8 BOM', canonical: 'UTF-8 BOM' },
	EncodingInfo{ label: 'UTF-16 LE', canonical: 'UTF-16LE' },
	EncodingInfo{ label: 'UTF-16 BE', canonical: 'UTF-16BE' },
	EncodingInfo{ label: 'UTF-32 LE', canonical: 'UTF-32LE' },
	EncodingInfo{ label: 'UTF-32 BE', canonical: 'UTF-32BE' },
	EncodingInfo{ label: 'GB18030', canonical: 'GB18030' },
]!

fn encoding_is_supported(name string) bool {
	for enc in editor_encodings {
		if enc.canonical == name {
			return true
		}
	}
	return false
}

// detect_file_encoding returns the BOM-selected encoding, or UTF-8 when no
// supported BOM is present. UTF-16/32 and GB18030 are only auto-detected by
// BOM; files without one can still be opened explicitly through Reopen.
fn detect_file_encoding(bytes []u8) string {
	if bytes.len >= 4 {
		if bytes[0] == 0xff && bytes[1] == 0xfe && bytes[2] == 0 && bytes[3] == 0 {
			return 'UTF-32LE'
		}
		if bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0xfe && bytes[3] == 0xff {
			return 'UTF-32BE'
		}
		if bytes[0] == 0x84 && bytes[1] == 0x31 && bytes[2] == 0x95 && bytes[3] == 0x33 {
			return 'GB18030'
		}
	}
	if bytes.len >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf {
		return 'UTF-8 BOM'
	}
	if bytes.len >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe {
		return 'UTF-16LE'
	}
	if bytes.len >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff {
		return 'UTF-16BE'
	}
	return 'UTF-8'
}

fn encoding_payload(bytes []u8, encoding string) []u8 {
	mut skip := 0
	match encoding {
		'UTF-8 BOM' {
			if bytes.len >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf {
				skip = 3
			}
		}
		'UTF-16LE' {
			if bytes.len >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe {
				skip = 2
			}
		}
		'UTF-16BE' {
			if bytes.len >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff {
				skip = 2
			}
		}
		'UTF-32LE' {
			if bytes.len >= 4 && bytes[0] == 0xff && bytes[1] == 0xfe && bytes[2] == 0
				&& bytes[3] == 0 {
				skip = 4
			}
		}
		'UTF-32BE' {
			if bytes.len >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0xfe
				&& bytes[3] == 0xff {
				skip = 4
			}
		}
		'GB18030' {
			if bytes.len >= 4 && bytes[0] == 0x84 && bytes[1] == 0x31 && bytes[2] == 0x95
				&& bytes[3] == 0x33 {
				skip = 4
			}
		}
		else {}
	}
	return bytes[skip..].clone()
}

// decode_file converts file bytes to strict UTF-8 and removes a recognized
// BOM. Conversion errors are returned to the caller; lossy decoding is never
// used for disk input.
fn decode_file(bytes []u8, encoding string) !string {
	if !encoding_is_supported(encoding) {
		return error('unsupported encoding: ${encoding}')
	}
	payload := encoding_payload(bytes, encoding)
	source := if encoding == 'UTF-8 BOM' { 'UTF-8' } else { encoding }
	// vlib's iconv Windows backend converts invalid UTF-8 leniently (its
	// MultiByteToWideChar path replaces malformed sequences instead of
	// failing), so 'UTF-8' and 'UTF-8 BOM' inputs are validated here first.
	// Every other encoding keeps its previous iconv-driven behavior.
	if source == 'UTF-8' && !utf8_validate_strict(payload) {
		return error('invalid ${encoding} input: malformed UTF-8')
	}
	return iconv.encoding_to_vstring(payload, source) or {
		return error('invalid ${encoding} input: ${err}')
	}
}

// utf8_validate_strict reports whether bytes are well-formed UTF-8 per RFC
// 3629: correct lead/continuation structure, no overlong encodings, no UTF-16
// surrogates, and no code points above U+10FFFF. See decode_file for why this
// check lives outside iconv.
fn utf8_validate_strict(bytes []u8) bool {
	mut i := 0
	for i < bytes.len {
		b := bytes[i]
		if b < 0x80 {
			i++
			continue
		}
		mut seq_len := 0
		mut lead_mask := u8(0)
		mut min_cp := u32(0)
		mut max_cp := u32(0)
		if (b & 0xE0) == 0xC0 {
			seq_len = 2
			lead_mask = 0x1F
			min_cp = 0x80
			max_cp = 0x7FF
		} else if (b & 0xF0) == 0xE0 {
			seq_len = 3
			lead_mask = 0x0F
			min_cp = 0x800
			max_cp = 0xFFFF
		} else if (b & 0xF8) == 0xF0 {
			seq_len = 4
			lead_mask = 0x07
			min_cp = 0x1_0000
			max_cp = 0x10_FFFF
		} else {
			// Continuation bytes (0x80-0xBF), overlong 2-byte leads
			// (0xC0-0xC1) and anything above 4-byte leads are never valid.
			return false
		}
		if i + seq_len > bytes.len {
			return false
		}
		mut cp := u32(b & lead_mask)
		for k := 1; k < seq_len; k++ {
			cb := bytes[i + k]
			if (cb & 0xC0) != 0x80 {
				return false
			}
			cp = (cp << 6) | u32(cb & 0x3F)
		}
		// Surrogates only ever appear in 3-byte sequences, but checking the
		// decoded value keeps the rule in one place.
		if cp >= 0xD800 && cp <= 0xDFFF {
			return false
		}
		if cp < min_cp || cp > max_cp {
			return false
		}
		i += seq_len
	}
	return true
}

fn encoding_bom(encoding string) []u8 {
	return match encoding {
		'UTF-8 BOM' { [u8(0xef), 0xbb, 0xbf] }
		'UTF-16LE' { [u8(0xff), 0xfe] }
		'UTF-16BE' { [u8(0xfe), 0xff] }
		'UTF-32LE' { [u8(0xff), 0xfe, 0, 0] }
		'UTF-32BE' { [u8(0), 0, 0xfe, 0xff] }
		'GB18030' { [u8(0x84), 0x31, 0x95, 0x33] }
		else { []u8{} }
	}
}

// encode_text converts valid editor UTF-8 to the selected on-disk encoding.
// The non-UTF-8 formats include their conventional BOM, matching the Rust
// implementation's write policy and making subsequent auto-detection safe.
fn encode_text(text string, encoding string) ![]u8 {
	if !encoding_is_supported(encoding) {
		return error('unsupported encoding: ${encoding}')
	}
	mut payload := if encoding.starts_with('UTF-8') {
		text.bytes()
	} else {
		iconv.vstring_to_encoding(text, encoding) or {
			return error('cannot encode as ${encoding}: ${err}')
		}
	}
	mut out := encoding_bom(encoding)
	out << payload
	return out
}
