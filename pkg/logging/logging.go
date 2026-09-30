// Package logging writes the checkin's log in the management-tool convention:
// one line per event as "[yyyy-MM-dd HH:mm:ss] LEVEL  message" appended to
// /Library/Managed Encryption/logs/crypt.log, rolled daily with thirty kept
// generations, owned by the tool rather than by a launchd redirect. The
// authorization plugin appends to the same file beside its unified-log entries.
package logging

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	// Dir is the logs directory of the Managed Encryption root.
	Dir = "/Library/Managed Encryption/logs"
	// File is the current log file inside Dir.
	File = "crypt.log"
	// Keep is how many rolled daily files are retained.
	Keep = 30
)

// Writer formats every line it receives with a timestamp and level and appends
// it to the log file, opening it with O_APPEND for each record as the plugin
// does, so a Roll in another process never leaves it writing to a file that
// is about to be removed; when stdout is a terminal the plain line is echoed there
// as well so an administrator running checkin by hand still sees the output.
type Writer struct {
	mu    sync.Mutex
	path  string
	echo  bool
	level string
	now   func() time.Time
}

var std *Writer // nolint:gochecknoglobals

// Setup prepares the log directory, rolls yesterday's file, and routes the
// standard log package through the convention writer. It never fails the
// caller: a log that cannot be opened falls back to stderr.
func Setup() {
	w, err := Open(Dir, File, time.Now)
	if err != nil {
		fmt.Fprintf(os.Stderr, "crypt: cannot open %s: %v\n", filepath.Join(Dir, File), err)
		log.SetFlags(0)
		return
	}
	std = w
	log.SetFlags(0)
	log.SetOutput(w)
}

// Open creates dir, rolls the current file when its first record is from an
// earlier day, prunes rolled files beyond Keep, and opens the file for append.
func Open(dir, name string, now func() time.Time) (*Writer, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	path := filepath.Join(dir, name)
	Roll(dir, name, now())
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, err
	}
	_ = f.Close()
	echo := false
	if fi, statErr := os.Stdout.Stat(); statErr == nil && fi.Mode()&os.ModeCharDevice != 0 {
		echo = true
	}
	return &Writer{path: path, echo: echo, level: "INFO", now: now}, nil
}

// Roll moves dir/name aside once its first record is from an earlier day,
// appending each record to dir/<base>-<yyyy-MM-dd>.log for the day it was
// written, then removes the oldest rolled files beyond Keep. The day is read
// from the leading "[yyyy-MM-dd HH:mm:ss]" of each line rather than from the
// file's mtime, which the plugin's appends keep moving; lines without a
// timestamp follow the line before them, or the mtime when none precedes.
//
// The file is renamed to a private name before it is read, so a plugin or
// checkin that appends meanwhile recreates dir/name instead of writing into
// data about to be removed. The renamed copy is removed only after every
// record reached its rolled file; on any failure it is renamed back, or left
// for the next Roll to finish, and never deleted.
func Roll(dir, name string, today time.Time) {
	path := filepath.Join(dir, name)
	base := strings.TrimSuffix(name, filepath.Ext(name))
	finishPendingRolls(dir, name, base)
	fi, err := os.Stat(path)
	if err != nil || fi.Size() == 0 {
		return
	}
	day, ok := firstRecordDay(path)
	if !ok {
		day = fi.ModTime()
	}
	if sameDay(day, today) {
		return
	}
	pending := filepath.Join(dir, fmt.Sprintf(".%s.roll-%d", name, os.Getpid()))
	if err := os.Rename(path, pending); err != nil {
		return
	}
	if err := drain(pending, dir, base, fi.ModTime()); err != nil {
		// Put the data back unless a writer has already recreated the file,
		// in which case the pending copy waits for the next Roll.
		if os.Link(pending, path) == nil {
			_ = os.Remove(pending)
		}
		return
	}
	prune(dir, base)
}

// finishPendingRolls drains copies left by a Roll that failed or was killed.
// A copy whose process is still running belongs to a Roll in progress.
func finishPendingRolls(dir, name, base string) {
	matches, err := filepath.Glob(filepath.Join(dir, "."+name+".roll-*"))
	if err != nil {
		return
	}
	for _, m := range matches {
		fi, err := os.Stat(m)
		if err != nil {
			continue
		}
		pid, err := strconv.Atoi(strings.TrimPrefix(filepath.Base(m), "."+name+".roll-"))
		if err == nil && pid != os.Getpid() && processAlive(pid) {
			continue
		}
		_ = drain(m, dir, base, fi.ModTime())
	}
}

func processAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// firstRecordDay parses the timestamp that opens the file's first line.
func firstRecordDay(path string) (time.Time, bool) {
	f, err := os.Open(path)
	if err != nil {
		return time.Time{}, false
	}
	defer f.Close()
	head := make([]byte, len(stampLayout)+2)
	n, _ := io.ReadFull(f, head)
	return parseStamp(head[:n])
}

const stampLayout = "2006-01-02 15:04:05"

// parseStamp reads a leading "[yyyy-MM-dd HH:mm:ss]" in local time.
func parseStamp(line []byte) (time.Time, bool) {
	if len(line) < len(stampLayout)+2 || line[0] != '[' || line[len(stampLayout)+1] != ']' {
		return time.Time{}, false
	}
	t, err := time.ParseInLocation(stampLayout, string(line[1:len(stampLayout)+1]), time.Local)
	if err != nil {
		return time.Time{}, false
	}
	return t, true
}

// rollSettle is how long drain waits for a writer that opened the file just
// before the rename to finish its record. Writers hold the file open only for
// one record, so this closes the window in practice.
var rollSettle = 200 * time.Millisecond // nolint:gochecknoglobals

// drain appends everything in pending to the rolled files by day and removes
// pending only when all of it was written. It reads until the file has
// stopped growing for rollSettle, to collect a record a writer appended after
// the rename.
func drain(pending, dir, base string, fallback time.Time) error {
	f, err := os.Open(pending)
	if err != nil {
		return err
	}
	day := fallback.Local().Format("2006-01-02")
	var carry []byte
	for {
		chunk, err := io.ReadAll(f)
		if err != nil {
			_ = f.Close()
			return err
		}
		if len(chunk) == 0 {
			time.Sleep(rollSettle)
			if chunk, err = io.ReadAll(f); err != nil || len(chunk) == 0 {
				if err != nil {
					_ = f.Close()
					return err
				}
				break
			}
		}
		data := append(carry, chunk...)
		// Hold back a trailing partial line until the next read or the end.
		cut := bytes.LastIndexByte(data, '\n') + 1
		carry = append([]byte(nil), data[cut:]...)
		if day, err = appendByDay(data[:cut], dir, base, day); err != nil {
			_ = f.Close()
			return err
		}
	}
	if len(carry) > 0 {
		if _, err = appendByDay(append(carry, '\n'), dir, base, day); err != nil {
			_ = f.Close()
			return err
		}
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Remove(pending)
}

// appendByDay writes complete lines to <base>-<day>.log, switching file at
// each line whose timestamp names another day. It returns the day of the last
// line so a following chunk continues in the same file.
func appendByDay(data []byte, dir, base, day string) (string, error) {
	start := 0
	flush := func(end int) error {
		if end <= start {
			return nil
		}
		rolled := filepath.Join(dir, fmt.Sprintf("%s-%s.log", base, day))
		out, err := os.OpenFile(rolled, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			return err
		}
		if _, err := out.Write(data[start:end]); err != nil {
			_ = out.Close()
			return err
		}
		return out.Close()
	}
	for i := 0; i < len(data); {
		next := bytes.IndexByte(data[i:], '\n')
		if next < 0 {
			next = len(data)
		} else {
			next += i + 1
		}
		if t, ok := parseStamp(data[i:next]); ok {
			if d := t.Format("2006-01-02"); d != day {
				if err := flush(i); err != nil {
					return day, err
				}
				start, day = i, d
			}
		}
		i = next
	}
	return day, flush(len(data))
}

func prune(dir, base string) {
	matches, err := filepath.Glob(filepath.Join(dir, base+"-*.log"))
	if err != nil || len(matches) <= Keep {
		return
	}
	sort.Strings(matches) // yyyy-MM-dd names sort chronologically
	for _, stale := range matches[:len(matches)-Keep] {
		_ = os.Remove(stale)
	}
}

func sameDay(a, b time.Time) bool {
	ay, am, ad := a.Local().Date()
	by, bm, bd := b.Local().Date()
	return ay == by && am == bm && ad == bd
}

// Write implements io.Writer for the standard log package: every non-empty
// line becomes one INFO record.
func (w *Writer) Write(p []byte) (int, error) {
	for _, line := range bytes.Split(bytes.TrimRight(p, "\n"), []byte("\n")) {
		text := strings.TrimRight(string(line), "\r")
		if text == "" {
			continue
		}
		w.emit(w.level, text)
	}
	return len(p), nil
}

// Log writes one record at the given level (DEBUG, INFO, WARN, ERROR).
func (w *Writer) Log(level, format string, args ...interface{}) {
	w.emit(level, fmt.Sprintf(format, args...))
}

func (w *Writer) emit(level, text string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	record := fmt.Sprintf("[%s] %-5s %s\n", w.now().Format("2006-01-02 15:04:05"), level, text)
	if w.path != "" {
		if f, err := os.OpenFile(w.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644); err == nil {
			_, _ = f.WriteString(record)
			_ = f.Close()
		}
	}
	if w.echo {
		_, _ = fmt.Fprintln(os.Stdout, text)
	}
}

// Close is kept for callers; the file is not held open between records.
func (w *Writer) Close() error {
	return nil
}

// Errorf records an ERROR line through the shared writer and also writes it to
// stderr, so a failing --install run shows in the installer's log. Before
// Setup it goes to stderr only.
func Errorf(format string, args ...interface{}) {
	if std == nil {
		fmt.Fprintf(os.Stderr, format+"\n", args...)
		return
	}
	std.Log("ERROR", format, args...)
	if !std.echo { // an echoing writer has already shown it on the terminal
		fmt.Fprintf(os.Stderr, "crypt: "+format+"\n", args...)
	}
}

// Warnf records a WARN line through the shared writer, or stderr before Setup.
func Warnf(format string, args ...interface{}) {
	if std == nil {
		fmt.Fprintf(os.Stderr, format+"\n", args...)
		return
	}
	std.Log("WARN", format, args...)
}
