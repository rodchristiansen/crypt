// Package logging writes the checkin's log in the management-tool convention:
// one line per event as "[yyyy-MM-dd HH:mm:ss] LEVEL  message" appended to
// /Library/Managed Encryption/logs/crypt.log, rolled daily with thirty kept
// generations, owned by the tool rather than by a launchd redirect. The
// authorization plugin appends to the same file beside its unified-log entries.
package logging

import (
	"bytes"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
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
// it to the log file; when stdout is a terminal the plain line is echoed there
// as well so an administrator running checkin by hand still sees the output.
type Writer struct {
	mu    sync.Mutex
	file  *os.File
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

// Open creates dir, rolls the current file when it was last written on an
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
	echo := false
	if fi, statErr := os.Stdout.Stat(); statErr == nil && fi.Mode()&os.ModeCharDevice != 0 {
		echo = true
	}
	return &Writer{file: f, echo: echo, level: "INFO", now: now}, nil
}

// Roll renames dir/name to dir/<base>-<yyyy-MM-dd>.log when its last write
// happened before today, then removes the oldest rolled files beyond Keep.
func Roll(dir, name string, today time.Time) {
	path := filepath.Join(dir, name)
	fi, err := os.Stat(path)
	if err != nil {
		return
	}
	last := fi.ModTime()
	if sameDay(last, today) {
		return
	}
	base := strings.TrimSuffix(name, filepath.Ext(name))
	rolled := filepath.Join(dir, fmt.Sprintf("%s-%s.log", base, last.Format("2006-01-02")))
	if _, err := os.Stat(rolled); err == nil {
		// Two rolls on one day: keep the earlier file, append today's to it.
		if old, err := os.ReadFile(path); err == nil {
			if f, err := os.OpenFile(rolled, os.O_WRONLY|os.O_APPEND, 0o644); err == nil {
				_, _ = f.Write(old)
				_ = f.Close()
			}
		}
		_ = os.Remove(path)
	} else {
		_ = os.Rename(path, rolled)
	}
	prune(dir, base)
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
	if w.file != nil {
		_, _ = w.file.WriteString(record)
	}
	if w.echo {
		fmt.Fprintln(os.Stdout, text)
	}
}

// Close releases the log file.
func (w *Writer) Close() error {
	if w.file == nil {
		return nil
	}
	return w.file.Close()
}

// Errorf records an ERROR line through the shared writer, or stderr before Setup.
func Errorf(format string, args ...interface{}) {
	if std == nil {
		fmt.Fprintf(os.Stderr, format+"\n", args...)
		return
	}
	std.Log("ERROR", format, args...)
}

// Warnf records a WARN line through the shared writer, or stderr before Setup.
func Warnf(format string, args ...interface{}) {
	if std == nil {
		fmt.Fprintf(os.Stderr, format+"\n", args...)
		return
	}
	std.Log("WARN", format, args...)
}
