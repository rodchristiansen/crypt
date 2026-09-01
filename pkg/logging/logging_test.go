package logging

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestFormatLine(t *testing.T) {
	at := time.Date(2025, 3, 9, 14, 5, 7, 0, time.Local)

	assert.Equal(t, "[2025-03-09 14:05:07]  INFO  hello\n", FormatLine(at, LevelInfo, "hello"))
	assert.Equal(t, "[2025-03-09 14:05:07] DEBUG  hello\n", FormatLine(at, LevelDebug, "hello"))
	assert.Equal(t, "[2025-03-09 14:05:07]  WARN  hello\n", FormatLine(at, LevelWarn, "hello"))
	assert.Equal(t, "[2025-03-09 14:05:07] ERROR  hello\n", FormatLine(at, LevelError, "hello"))
	assert.Equal(t, "[2025-03-09 14:05:07]  INFO  two lines\n", FormatLine(at, LevelInfo, "two\nlines"))
}

func TestWriteAppendsToLiveFile(t *testing.T) {
	dir := t.TempDir()
	l := New(dir)
	l.now = func() time.Time { return time.Date(2025, 3, 9, 14, 5, 7, 0, time.Local) }

	l.Info("first")
	l.Error("second %d", 2)

	data, err := os.ReadFile(filepath.Join(dir, FileName))
	require.NoError(t, err)
	assert.Equal(t, "[2025-03-09 14:05:07]  INFO  first\n[2025-03-09 14:05:07] ERROR  second 2\n", string(data))
	assert.Empty(t, l.RolledFiles())
}

func TestRollsOnFirstWriteOfNewDay(t *testing.T) {
	dir := t.TempDir()
	l := New(dir)

	day1 := time.Date(2025, 3, 9, 23, 59, 0, 0, time.Local)
	l.now = func() time.Time { return day1 }
	l.Info("yesterday")
	require.NoError(t, os.Chtimes(l.Path(), day1, day1))

	day2 := day1.Add(2 * time.Minute)
	l.now = func() time.Time { return day2 }
	l.Info("today")

	rolled, err := os.ReadFile(filepath.Join(dir, "crypt-2025-03-09.log"))
	require.NoError(t, err)
	assert.Equal(t, "[2025-03-09 23:59:00]  INFO  yesterday\n", string(rolled))

	live, err := os.ReadFile(l.Path())
	require.NoError(t, err)
	assert.Equal(t, "[2025-03-10 00:01:00]  INFO  today\n", string(live))
	assert.Equal(t, []string{"crypt-2025-03-09.log"}, l.RolledFiles())
}

func TestDoesNotRollWithinTheSameDay(t *testing.T) {
	dir := t.TempDir()
	l := New(dir)

	morning := time.Date(2025, 3, 9, 8, 0, 0, 0, time.Local)
	l.now = func() time.Time { return morning }
	l.Info("morning")
	require.NoError(t, os.Chtimes(l.Path(), morning, morning))

	l.now = func() time.Time { return morning.Add(10 * time.Hour) }
	l.Info("evening")

	live, err := os.ReadFile(l.Path())
	require.NoError(t, err)
	assert.Equal(t, 2, strings.Count(string(live), "\n"))
	assert.Empty(t, l.RolledFiles())
}

func TestPrunesRolledFilesBeyondKeep(t *testing.T) {
	dir := t.TempDir()
	l := New(dir)

	base := time.Date(2025, 1, 1, 12, 0, 0, 0, time.Local)
	for i := 0; i < Keep+5; i++ {
		day := base.AddDate(0, 0, i)
		name := filepath.Join(dir, "crypt-"+day.Format(dayStamp)+".log")
		require.NoError(t, os.WriteFile(name, []byte("old\n"), 0o644))
	}

	last := base.AddDate(0, 0, Keep+5)
	l.now = func() time.Time { return last }
	l.Info("older live file")
	require.NoError(t, os.Chtimes(l.Path(), last, last))

	l.now = func() time.Time { return last.AddDate(0, 0, 1) }
	l.Info("new day")

	rolled := l.RolledFiles()
	assert.Len(t, rolled, Keep)
	assert.Equal(t, "crypt-"+last.Format(dayStamp)+".log", rolled[0])
	_, err := os.Stat(filepath.Join(dir, "crypt-"+base.Format(dayStamp)+".log"))
	assert.True(t, os.IsNotExist(err))
}

func TestTeeWriterStripsStdlogStamp(t *testing.T) {
	dir := t.TempDir()
	l := New(dir)
	l.now = func() time.Time { return time.Date(2025, 3, 9, 14, 5, 7, 0, time.Local) }
	w := &teeWriter{logger: l, level: LevelInfo}

	_, err := w.Write([]byte("2025/03/09 14:05:07 Escrow not required\n"))
	require.NoError(t, err)

	live, err := os.ReadFile(l.Path())
	require.NoError(t, err)
	assert.Equal(t, "[2025-03-09 14:05:07]  INFO  Escrow not required\n", string(live))
}
