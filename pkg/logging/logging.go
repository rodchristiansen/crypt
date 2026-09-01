// Package logging appends plain text log lines to a file that survives
// beyond the unified log's retention.
//
// Lines are written as "[yyyy-MM-dd HH:mm:ss] LEVEL  message" in local time.
// The file rolls to crypt-yyyy-MM-dd.log on the first write of a new day and
// the newest thirty rolled files are kept. The system location is
// /Library/Managed Encryption/logs/crypt.log; when that directory cannot be
// written the logger falls back to ~/Library/Logs/crypt.log with the same
// rules. The authorization plugin writes the same file with the same format,
// so one file tells the whole story of a device.
//
// Callers must never log a recovery key, escrow payload, password or any
// other secret. Log that an action happened and its outcome, not its inputs.
package logging

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	// SystemDirectory is the preferred log directory.
	SystemDirectory = "/Library/Managed Encryption/logs"
	// FileName is the name of the live log file.
	FileName = "crypt.log"
	// Keep is how many rolled daily files are retained.
	Keep = 30

	lineStamp = "2006-01-02 15:04:05"
	dayStamp  = "2006-01-02"
)

// Level is the severity written into each line.
type Level int

const (
	LevelDebug Level = iota
	LevelInfo
	LevelWarn
	LevelError
)

func (l Level) String() string {
	switch l {
	case LevelDebug:
		return "DEBUG"
	case LevelWarn:
		return "WARN"
	case LevelError:
		return "ERROR"
	default:
		return "INFO"
	}
}

// Logger writes to one directory. It is safe for concurrent use.
type Logger struct {
	mu  sync.Mutex
	dir string
	now func() time.Time
}

// New returns a logger writing into dir, creating it when missing.
func New(dir string) *Logger {
	ensureDirectory(dir)
	return &Logger{dir: dir, now: time.Now}
}

// Default returns a logger for the system directory, or the user's
// ~/Library/Logs when the system directory is not writable.
func Default() *Logger {
	return New(resolveDirectory())
}

var (
	std     *Logger
	stdOnce sync.Once
)

func defaultLogger() *Logger {
	stdOnce.Do(func() { std = Default() })
	return std
}

// Dir is the directory the logger writes into.
func (l *Logger) Dir() string { return l.dir }

// Path is the live log file.
func (l *Logger) Path() string { return filepath.Join(l.dir, FileName) }

// Log writes one line at the given level.
func (l *Logger) Log(level Level, format string, args ...any) {
	msg := format
	if len(args) > 0 {
		msg = fmt.Sprintf(format, args...)
	}
	now := l.now()
	line := FormatLine(now, level, msg)

	l.mu.Lock()
	defer l.mu.Unlock()
	l.rotateIfNeeded(now)
	l.append(line)
}

func (l *Logger) Debug(format string, args ...any) { l.Log(LevelDebug, format, args...) }
func (l *Logger) Info(format string, args ...any)  { l.Log(LevelInfo, format, args...) }
func (l *Logger) Warn(format string, args ...any)  { l.Log(LevelWarn, format, args...) }
func (l *Logger) Error(format string, args ...any) { l.Log(LevelError, format, args...) }

// Package-level helpers write through the default logger.
func Debug(format string, args ...any) { defaultLogger().Debug(format, args...) }
func Info(format string, args ...any)  { defaultLogger().Info(format, args...) }
func Warn(format string, args ...any)  { defaultLogger().Warn(format, args...) }
func Error(format string, args ...any) { defaultLogger().Error(format, args...) }

// FormatLine renders one record. Embedded newlines are flattened so every
// record stays on a single line.
func FormatLine(t time.Time, level Level, msg string) string {
	flat := strings.NewReplacer("\r\n", " ", "\n", " ", "\r", " ").Replace(msg)
	return fmt.Sprintf("[%s] %5s  %s\n", t.Format(lineStamp), level.String(), flat)
}

func (l *Logger) append(line string) {
	f, err := os.OpenFile(l.Path(), os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.WriteString(line)
}

// rotateIfNeeded rolls the live file to crypt-yyyy-MM-dd.log, dated by its
// last write, when it was last written on an earlier day. Rolled files beyond
// Keep are removed. Caller holds l.mu.
func (l *Logger) rotateIfNeeded(now time.Time) {
	info, err := os.Stat(l.Path())
	if err != nil {
		return
	}
	modified := info.ModTime().In(now.Location())
	if sameDay(modified, now) || modified.After(now) {
		return
	}

	rolled := filepath.Join(l.dir, "crypt-"+modified.Format(dayStamp)+".log")
	if _, err := os.Stat(rolled); err == nil {
		// Another process already rolled this day. Fold our content into it
		// rather than clobbering what it wrote.
		if data, err := os.ReadFile(l.Path()); err == nil {
			if f, err := os.OpenFile(rolled, os.O_WRONLY|os.O_APPEND, 0o644); err == nil {
				_, _ = f.Write(data)
				f.Close()
			}
		}
		_ = os.Remove(l.Path())
	} else if err := os.Rename(l.Path(), rolled); err != nil {
		return
	}
	l.prune()
}

func sameDay(a, b time.Time) bool {
	ay, am, ad := a.Date()
	by, bm, bd := b.Date()
	return ay == by && am == bm && ad == bd
}

var rolledName = regexp.MustCompile(`^crypt-\d{4}-\d{2}-\d{2}\.log$`)

// RolledFiles lists rolled file names in the directory, newest first.
func (l *Logger) RolledFiles() []string {
	entries, err := os.ReadDir(l.dir)
	if err != nil {
		return nil
	}
	names := []string{}
	for _, e := range entries {
		if !e.IsDir() && rolledName.MatchString(e.Name()) {
			names = append(names, e.Name())
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(names)))
	return names
}

func (l *Logger) prune() {
	names := l.RolledFiles()
	for i := Keep; i < len(names); i++ {
		_ = os.Remove(filepath.Join(l.dir, names[i]))
	}
}

// stdPrefix matches the timestamp the standard library log package writes
// with log.LstdFlags, so those records can be re-stamped in this file's format.
var stdPrefix = regexp.MustCompile(`^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}(\.\d+)? `)

type teeWriter struct {
	logger      *Logger
	level       Level
	passthrough io.Writer
}

// TeeWriter returns a writer for log.SetOutput. Each record is passed through
// unchanged to passthrough (normally os.Stderr, which launchd captures) and
// also written to the file at the given level with the standard library
// timestamp replaced by this file's stamp.
func TeeWriter(passthrough io.Writer, level Level) io.Writer {
	return &teeWriter{logger: defaultLogger(), level: level, passthrough: passthrough}
}

func (w *teeWriter) Write(p []byte) (int, error) {
	if w.passthrough != nil {
		_, _ = w.passthrough.Write(p)
	}
	for _, line := range bytes.Split(p, []byte("\n")) {
		text := strings.TrimSpace(string(stdPrefix.ReplaceAll(line, nil)))
		if text == "" {
			continue
		}
		w.logger.Log(w.level, "%s", text)
	}
	return len(p), nil
}

func resolveDirectory() string {
	ensureDirectory(SystemDirectory)
	if writable(SystemDirectory) {
		return SystemDirectory
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return SystemDirectory
	}
	user := filepath.Join(home, "Library", "Logs")
	ensureDirectory(user)
	return user
}

func ensureDirectory(dir string) {
	if info, err := os.Stat(dir); err == nil && info.IsDir() {
		return
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return
	}
	// MkdirAll honours the umask, so set the mode explicitly.
	_ = os.Chmod(dir, 0o755)
	if os.Geteuid() == 0 {
		_ = os.Chown(dir, 0, 0)
	}
}

func writable(dir string) bool {
	f, err := os.CreateTemp(dir, ".crypt-log-probe-*")
	if err != nil {
		return false
	}
	name := f.Name()
	f.Close()
	_ = os.Remove(name)
	return true
}
