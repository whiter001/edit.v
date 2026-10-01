module main

// Windows platform layer for the sys module; compiled only on Windows via
// the _windows.c.v suffix. API-for-API counterpart of sys_nix.c.v (which
// doubles as the semantic reference for this file).
//
// Differences from the nix implementation forced by the platform:
// * Console handles live in SysState. GetStdHandle() alone is not enough:
//   after reopen_stdin_if_redirected() has re-pointed the CRT fd at CONIN$,
//   the process-wide STD_INPUT_HANDLE can still refer to the original
//   redirected (pipe) handle, so handles are validated with GetConsoleMode()
//   and fall back to _get_osfhandle(fd).
// * There is no SIGWINCH: read_stdin() polls the console size on every call
//   and prepends the same VT resize report the nix build injects on signal.
// * msvcrt fds are switched to binary mode in sys_init() so redirected
//   pipes carry raw bytes (no CRLF/^Z translation).
//
// C constants that V cannot pass through as macros are hardcoded below from
// the Microsoft docs (wincon.h / winbase.h / fileapi.h).

#include <windows.h>
#include <io.h>
#include <errno.h>

// ---- C API not already declared by vlib's builtin ------------------------
// (C.GetStdHandle, C.GetConsoleMode, C.SetConsoleMode, C.WaitForSingleObject,
// C.CloseHandle, C.read, C.write, C.open, C.close, C.isatty, C._setmode,
// C._get_osfhandle and C.memcpy come from builtin's cfns declarations.)
fn C.GetConsoleCP() u32
fn C.SetConsoleCP(code_page u32) bool
fn C.GetConsoleOutputCP() u32
fn C.SetConsoleOutputCP(code_page u32) bool
fn C.GetConsoleScreenBufferInfo(handle C.HANDLE, info &C.CONSOLE_SCREEN_BUFFER_INFO) bool
fn C.CreateFileW(file_name &u16, desired_access u32, share_mode u32, security voidptr, disposition u32, flags u32, template voidptr) voidptr
fn C.GetFileInformationByHandle(handle voidptr, info &C.BY_HANDLE_FILE_INFORMATION) bool
fn C._errno() &int

// ---- Win32 structures, ABI-matching ---------------------------------------
// windows.h provides the real definitions; @[typedef] tells V they already
// exist on the C side, so only field layout is recorded here.

// https://learn.microsoft.com/en-us/windows/console/coord-str
@[typedef]
struct C.COORD {
mut:
	X i16
	Y i16
}

// https://learn.microsoft.com/en-us/windows/console/small-rect-str
@[typedef]
struct C.SMALL_RECT {
mut:
	Left   i16
	Top    i16
	Right  i16
	Bottom i16
}

// https://learn.microsoft.com/en-us/windows/console/console-screen-buffer-info-str
@[typedef]
struct C.CONSOLE_SCREEN_BUFFER_INFO {
mut:
	dwSize              C.COORD
	dwCursorPosition    C.COORD
	wAttributes         u16
	srWindow            C.SMALL_RECT
	dwMaximumWindowSize C.COORD
}

// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/ns-fileapi-by_handle_file_information
// FILETIME is two DWORDs (low, high); flattened to keep the layout literal.
@[typedef]
struct C.BY_HANDLE_FILE_INFORMATION {
mut:
	dwFileAttributes      u32
	ftCreationTime_low    u32
	ftCreationTime_high   u32
	ftLastAccessTime_low  u32
	ftLastAccessTime_high u32
	ftLastWriteTime_low   u32
	ftLastWriteTime_high  u32
	dwVolumeSerialNumber  u32
	nFileSizeHigh         u32
	nFileSizeLow          u32
	nNumberOfLinks        u32
	nFileIndexHigh        u32
	nFileIndexLow         u32
}

struct SysState {
mut:
	stdin_fd              int
	stdout_fd             int
	stdin_console_handle  voidptr
	stdout_console_handle voidptr
	stdin_initial_mode    u32
	stdout_initial_mode   u32
	has_initial_modes     bool
	initial_input_cp      u32
	initial_output_cp     u32
	inject_resize         bool
	stdin_eof             bool
	// Last seen window size (0 = not seen yet). Windows has no SIGWINCH, so
	// read_stdin() reports a resize whenever these change.
	last_cols u16
	last_rows u16
	// Buffer for incomplete UTF-8 sequences (max 3 bytes can be pending:
	// a 4-byte sequence splits at most into 1+3).
	utf8_buf [4]u8
	utf8_len int
}

__global (
	g_sys SysState
)

// ---- Constants (Microsoft docs; V cannot pass these macros through) ------

// GetStdHandle takes DWORDs: STD_INPUT_HANDLE is ((DWORD)-10) and
// STD_OUTPUT_HANDLE is ((DWORD)-11) (winbase.h / console handles).
const win_std_input_handle = u32(0xfffffff6)
const win_std_output_handle = u32(0xfffffff5)

// wincon.h console mode flags.
const win_enable_processed_input = u32(0x0001)
const win_enable_line_input = u32(0x0002)
const win_enable_echo_input = u32(0x0004)
const win_enable_virtual_terminal_input = u32(0x0200)
const win_enable_virtual_terminal_processing = u32(0x0004)
const win_disable_newline_auto_return = u32(0x0008)

// WaitForSingleObject timeout result (synchapi.h WAIT_TIMEOUT). A WAIT_FAILED
// (((DWORD)-1), i.e. -1 through the i32 the builtin declaration returns) is
// not checked explicitly: the non-waitable-handle case just falls through to
// the blocking read below.
const win_wait_timeout = 0x0000_0102

// fileapi.h CreateFileA constants.
const win_generic_read = u32(0x8000_0000) // GENERIC_READ
const win_file_share_rw_delete = u32(0x0000_0007) // FILE_SHARE_READ|WRITE|DELETE
const win_open_existing = u32(0x0000_0003) // OPEN_EXISTING
const win_file_flag_backup_semantics = u32(0x0200_0000) // FILE_FLAG_BACKUP_SEMANTICS

// CP_UTF8 (winnls.h): both console code pages are switched to UTF-8.
const cp_utf8 = u32(65001)

// fcntl.h _O_BINARY for msvcrt _setmode.
const win_o_binary = 0x8000

// errno_value returns the current errno.
fn errno_value() int {
	return unsafe { *C._errno() }
}

// sys_init initializes the global state with the standard fds and switches
// the msvcrt streams to binary mode.
// Rust: sys::init() (which returns the Deinit guard).
pub fn sys_init() {
	g_sys.stdin_fd = 0
	g_sys.stdout_fd = 1
	// msvcrt opens stdin/stdout in text mode: CRLF would be translated and a
	// ^Z byte would end the stream. Binary mode keeps redirected pipes
	// byte-exact (and matches the nix build's raw, OPOST-less output).
	C._setmode(g_sys.stdin_fd, win_o_binary)
	C._setmode(g_sys.stdout_fd, win_o_binary)
}

// fd_console_handle returns a handle usable for GetConsoleMode() and friends
// for the given fd: the GetStdHandle() handle while that still is a console,
// otherwise the OS handle backing the CRT fd (GetStdHandle can be stale after
// reopen_stdin_if_redirected() re-pointed the fd at CONIN$).
fn fd_console_handle(fd int, std_handle u32) voidptr {
	h := C.GetStdHandle(std_handle)
	mut mode := u32(0)
	if C.GetConsoleMode(h, &mode) {
		return h
	}
	return C._get_osfhandle(fd)
}

// reopen_stdin_if_redirected reopens stdin via the console input device
// (CONIN$) if it was redirected (= piped input). Returns true if stdin was
// reopened.
pub fn reopen_stdin_if_redirected() !bool {
	if C.isatty(g_sys.stdin_fd) == 0 {
		old_fd := g_sys.stdin_fd
		// msvcrt open() supports the CONIN$ device; O_RDONLY is 0.
		fd := C.open(c'CONIN$', 0)
		if fd < 0 {
			return error('open(CONIN$) failed')
		}
		if old_fd != fd {
			C.close(old_fd)
		}
		g_sys.stdin_fd = fd
		// _open() defaults to text mode; keep console input byte-exact like
		// sys_init() does for the redirected fds.
		C._setmode(fd, win_o_binary)
		g_sys.stdin_eof = false
		g_sys.utf8_len = 0
		return true
	}
	return false
}

// stdin_is_redirected reports whether stdin is not attached to a tty.
pub fn stdin_is_redirected() bool {
	return C.isatty(g_sys.stdin_fd) == 0
}

// read_all_stdin drains redirected stdin into a UTF-8 string.
pub fn read_all_stdin() !string {
	mut buf := []u8{cap: 64 * kibi}
	mut tmp := [64 * kibi]u8{}
	for {
		ret := C.read(g_sys.stdin_fd, &tmp[0], usize(tmp.len))
		if ret > 0 {
			buf << tmp[..int(ret)]
			continue
		}
		if ret == 0 {
			g_sys.stdin_eof = true
			break
		}
		if errno_value() == C.EINTR {
			continue
		}
		return error('read(stdin) failed')
	}
	return utf8_lossy(buf)
}

// switch_modes saves the current console modes and switches to raw mode.
// Call restore_terminal() on exit to undo this.
pub fn switch_modes() ! {
	g_sys.stdin_console_handle = fd_console_handle(g_sys.stdin_fd, win_std_input_handle)
	g_sys.stdout_console_handle = fd_console_handle(g_sys.stdout_fd, win_std_output_handle)

	// Get the original console modes so we can restore them on exit. A
	// failure here means we are not attached to a real Windows console (e.g.
	// mintty's MSYS pipes or a redirected stdout).
	mut in_mode := u32(0)
	if !C.GetConsoleMode(g_sys.stdin_console_handle, &in_mode) {
		return error('GetConsoleMode(stdin) failed: the Windows build needs a real console (run edit from cmd, PowerShell or Windows Terminal)')
	}
	mut out_mode := u32(0)
	if !C.GetConsoleMode(g_sys.stdout_console_handle, &out_mode) {
		return error('GetConsoleMode(stdout) failed: the Windows build needs a real console (run edit from cmd, PowerShell or Windows Terminal)')
	}
	g_sys.stdin_initial_mode = in_mode
	g_sys.stdout_initial_mode = out_mode
	g_sys.has_initial_modes = true

	// stdin: drop cooked input, echo and processed input; ask for VT-encoded
	// input instead of console input records.
	in_mode &= ~(win_enable_line_input | win_enable_echo_input | win_enable_processed_input)
	in_mode |= win_enable_virtual_terminal_input
	if !C.SetConsoleMode(g_sys.stdin_console_handle, in_mode) {
		return error('SetConsoleMode(stdin) failed')
	}

	// stdout: enable VT processing and stop the console from turning our LF
	// into CRLF (the editor emits explicit CRs).
	out_mode |= win_enable_virtual_terminal_processing | win_disable_newline_auto_return
	if !C.SetConsoleMode(g_sys.stdout_console_handle, out_mode) {
		return error('SetConsoleMode(stdout) failed')
	}

	// Both code pages: UTF-8, so console I/O speaks the same bytes the
	// editor works with internally.
	g_sys.initial_input_cp = C.GetConsoleCP()
	g_sys.initial_output_cp = C.GetConsoleOutputCP()
	C.SetConsoleCP(cp_utf8)
	C.SetConsoleOutputCP(cp_utf8)
}

// restore_terminal restores the console modes and code pages saved by
// switch_modes(). Idempotent; the caller must invoke it on every exit path
// (normal or error), like the nix build.
pub fn restore_terminal() {
	if g_sys.has_initial_modes {
		C.SetConsoleMode(g_sys.stdin_console_handle, g_sys.stdin_initial_mode)
		C.SetConsoleMode(g_sys.stdout_console_handle, g_sys.stdout_initial_mode)
		C.SetConsoleCP(g_sys.initial_input_cp)
		C.SetConsoleOutputCP(g_sys.initial_output_cp)
		g_sys.has_initial_modes = false
	}
}

// inject_window_size_into_stdin makes the next read_stdin() prepend a fake
// window size report sequence, as if the terminal had answered a query.
pub fn inject_window_size_into_stdin() {
	g_sys.inject_resize = true
}

// get_window_size queries the visible console window size via
// GetConsoleScreenBufferInfo. Falls back to 80x24.
fn get_window_size() (u16, u16) {
	mut info := C.CONSOLE_SCREEN_BUFFER_INFO{}
	if C.GetConsoleScreenBufferInfo(g_sys.stdout_console_handle, &info) {
		w := u16(info.srWindow.Right - info.srWindow.Left + 1)
		h := u16(info.srWindow.Bottom - info.srWindow.Top + 1)
		if w > 0 && h > 0 {
			return w, h
		}
	}
	return u16(80), u16(24)
}

// read_stdin reads from stdin.
//
// timeout_ms follows vt.v's convention: vt_no_timeout (-1) blocks
// indefinitely, 0 returns immediately, >0 waits up to that many ms.
//
// Returns none on error or EOF, '' if the timeout was reached,
// otherwise the read, non-empty string.
pub fn read_stdin(timeout_ms int) ?string {
	mut timeout := timeout_ms
	if g_sys.inject_resize {
		timeout = 0
	}

	mut buf := []u8{cap: 4 * kibi}

	// We got some leftover broken UTF-8 from a previous read? Prepend it.
	if g_sys.utf8_len != 0 {
		buf << g_sys.utf8_buf[..g_sys.utf8_len]
		g_sys.utf8_len = 0
	}

	mut tmp := [4096]u8{}
	for {
		if timeout != vt_no_timeout {
			// WaitForSingleObject on the console input handle reports input
			// availability. WAIT_FAILED means the handle is not waitable
			// (some pipes/devices): fall through to a plain blocking read.
			waited := C.WaitForSingleObject(g_sys.stdin_console_handle, i32(timeout))
			if waited == win_wait_timeout {
				break // Timeout? We can stop reading.
			}
		}

		ret := C.read(g_sys.stdin_fd, &tmp[0], usize(tmp.len))
		if ret > 0 {
			buf << tmp[..int(ret)]
			break
		}
		if ret == 0 {
			g_sys.stdin_eof = true
			return none // EOF
		}
		// ret < 0
		if errno_value() == C.EINTR && g_sys.inject_resize {
			break
		}
		if errno_value() == C.EINTR {
			continue
		}
		return none
	}

	if buf.len > 0 {
		// Cache an incomplete trailing UTF-8 sequence for the next read.
		tail := incomplete_utf8_tail_len(buf)
		if tail > 0 {
			g_sys.utf8_len = tail
			unsafe { C.memcpy(&g_sys.utf8_buf[0], &buf[buf.len - tail], usize(tail)) }
			buf = unsafe { buf[..buf.len - tail] }
		}
	}

	mut result := utf8_lossy(buf)

	// Windows has no SIGWINCH: poll the console size on every read and
	// report a changed size (or an injected request) through the same VT
	// sequence the nix build uses, so input.v's parser stays identical.
	// Prepend it, so that on startup the TUI system gets initialized with a
	// size first.
	w, h := get_window_size()
	if g_sys.inject_resize || w != g_sys.last_cols || h != g_sys.last_rows {
		g_sys.inject_resize = false
		g_sys.last_cols = w
		g_sys.last_rows = h
		result = '\x1b[8;${h};${w}t' + result
	}

	return result
}

// stdin_hit_eof reports whether the last read_stdin() hit end-of-file.
pub fn stdin_hit_eof() bool {
	return g_sys.stdin_eof
}

// write_stdout writes the given text to stdout.
pub fn write_stdout(text string) {
	if text.len == 0 {
		return
	}

	mut written := 0
	for written < text.len {
		chunk := text[written..]
		n := C.write(g_sys.stdout_fd, chunk.str, usize(chunk.len))
		if n >= 0 {
			written += int(n)
			continue
		}
		if errno_value() != C.EINTR {
			return
		}
	}
}

// file_id returns a unique identifier for the file at the given path.
pub fn file_id(path string) !FileId {
	// CreateFileW (not -A) so non-ASCII paths work regardless of the ANSI
	// codepage; string.to_wide() decodes V's WTF-8 path representation.
	handle := C.CreateFileW(path.to_wide(), win_generic_read, win_file_share_rw_delete,
		voidptr(0), win_open_existing, win_file_flag_backup_semantics, voidptr(0))
	// INVALID_HANDLE_VALUE is ((HANDLE)-1).
	if handle == voidptr(-1) {
		return error('CreateFile(${path}) failed')
	}
	defer { C.CloseHandle(handle) }

	mut info := C.BY_HANDLE_FILE_INFORMATION{}
	if !C.GetFileInformationByHandle(handle, &info) {
		return error('GetFileInformationByHandle(${path}) failed')
	}
	return FileId{
		st_dev: u64(info.dwVolumeSerialNumber)
		st_ino: (u64(info.nFileIndexHigh) << 32) | u64(info.nFileIndexLow)
	}
}
