package logging

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func fixed(t time.Time) func() time.Time { return func() time.Time { return t } }

func TestWriteFormatsLinesInTheConvention(t *testing.T) {
	dir := t.TempDir()
	now := time.Date(2026, 9, 2, 13, 15, 14, 0, time.Local)
	w, err := Open(dir, "crypt.log", fixed(now))
	if err != nil {
		t.Fatal(err)
	}
	w.echo = false
	if _, err := w.Write([]byte("Attempting to Escrow Key...\nKey escrow successful.\n")); err != nil {
		t.Fatal(err)
	}
	w.Log("ERROR", "Recovery Key could not be validated: %s", "boom")
	_ = w.Close()
	got, _ := os.ReadFile(filepath.Join(dir, "crypt.log"))
	want := "[2026-09-02 13:15:14] INFO  Attempting to Escrow Key...\n" +
		"[2026-09-02 13:15:14] INFO  Key escrow successful.\n" +
		"[2026-09-02 13:15:14] ERROR Recovery Key could not be validated: boom\n"
	if string(got) != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestRollMovesYesterdaysFileAndPrunes(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "crypt.log")
	if err := os.WriteFile(path, []byte("old\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	yesterday := time.Date(2026, 9, 1, 23, 59, 0, 0, time.Local)
	if err := os.Chtimes(path, yesterday, yesterday); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < Keep+3; i++ {
		day := yesterday.AddDate(0, 0, -(i + 1))
		name := filepath.Join(dir, "crypt-"+day.Format("2006-01-02")+".log")
		if err := os.WriteFile(name, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	today := time.Date(2026, 9, 2, 8, 0, 0, 0, time.Local)
	Roll(dir, "crypt.log", today)
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("current file should have been rolled away, stat err=%v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "crypt-2026-09-01.log")); err != nil {
		t.Fatalf("rolled file missing: %v", err)
	}
	rolled, _ := filepath.Glob(filepath.Join(dir, "crypt-*.log"))
	if len(rolled) != Keep {
		t.Fatalf("expected %d rolled files after prune, got %d", Keep, len(rolled))
	}
	for _, r := range rolled {
		if strings.HasSuffix(r, "crypt-2026-09-01.log") {
			return
		}
	}
	t.Fatal("prune removed the newest rolled file")
}

func TestRollLeavesTodaysFileAlone(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "crypt.log")
	_ = os.WriteFile(path, []byte("today\n"), 0o644)
	Roll(dir, "crypt.log", time.Now())
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("today's file was rolled: %v", err)
	}
}

func readOrEmpty(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	return string(b)
}

func assertNoPending(t *testing.T, dir string) {
	t.Helper()
	left, _ := filepath.Glob(filepath.Join(dir, ".crypt.log.roll-*"))
	if len(left) != 0 {
		t.Fatalf("pending roll files left behind: %v", left)
	}
}

func TestRollFilesRecordsUnderTheDayTheyWereWritten(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "crypt.log")
	content := "[2026-09-01 23:58:00] INFO  Core: late\n" +
		"continuation without a stamp\n" +
		"[2026-09-02 00:01:00] ERROR Keychain: after midnight\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	// The plugin's appends keep the mtime current; it must not decide the day.
	today := time.Date(2026, 9, 3, 8, 0, 0, 0, time.Local)
	if err := os.Chtimes(path, today, today); err != nil {
		t.Fatal(err)
	}
	Roll(dir, "crypt.log", today)
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("crypt.log should have been rolled, stat err=%v", err)
	}
	if got := readOrEmpty(t, filepath.Join(dir, "crypt-2026-09-01.log")); got !=
		"[2026-09-01 23:58:00] INFO  Core: late\ncontinuation without a stamp\n" {
		t.Fatalf("2026-09-01 file: %q", got)
	}
	if got := readOrEmpty(t, filepath.Join(dir, "crypt-2026-09-02.log")); got !=
		"[2026-09-02 00:01:00] ERROR Keychain: after midnight\n" {
		t.Fatalf("2026-09-02 file: %q", got)
	}
	assertNoPending(t, dir)
}

func TestRollKeepsAFileWhoseFirstRecordIsToday(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "crypt.log")
	today := time.Date(2026, 9, 3, 8, 0, 0, 0, time.Local)
	_ = os.WriteFile(path, []byte("[2026-09-03 07:00:00] INFO  x\n"), 0o644)
	yesterday := today.AddDate(0, 0, -1)
	_ = os.Chtimes(path, yesterday, yesterday)
	Roll(dir, "crypt.log", today)
	if got := readOrEmpty(t, path); got != "[2026-09-03 07:00:00] INFO  x\n" {
		t.Fatalf("today's file changed: %q", got)
	}
}

func TestRollAppendsToAnExistingRolledFile(t *testing.T) {
	dir := t.TempDir()
	rolled := filepath.Join(dir, "crypt-2026-09-02.log")
	_ = os.WriteFile(rolled, []byte("[2026-09-02 01:00:00] INFO  earlier\n"), 0o644)
	_ = os.WriteFile(filepath.Join(dir, "crypt.log"), []byte("[2026-09-02 22:00:00] INFO  later\n"), 0o644)
	Roll(dir, "crypt.log", time.Date(2026, 9, 3, 8, 0, 0, 0, time.Local))
	want := "[2026-09-02 01:00:00] INFO  earlier\n[2026-09-02 22:00:00] INFO  later\n"
	if got := readOrEmpty(t, rolled); got != want {
		t.Fatalf("got %q want %q", got, want)
	}
	assertNoPending(t, dir)
}

func TestRollKeepsTheDataWhenTheAppendFails(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "crypt.log")
	content := "[2026-09-02 22:00:00] INFO  must survive\n"
	_ = os.WriteFile(path, []byte(content), 0o644)
	// A directory where the rolled file should be makes the append fail.
	if err := os.Mkdir(filepath.Join(dir, "crypt-2026-09-02.log"), 0o755); err != nil {
		t.Fatal(err)
	}
	Roll(dir, "crypt.log", time.Date(2026, 9, 3, 8, 0, 0, 0, time.Local))
	if got := readOrEmpty(t, path); got != content {
		t.Fatalf("log not restored after a failed roll: %q", got)
	}
	assertNoPending(t, dir)
}

func TestRollFinishesAPendingCopyLeftByAnEarlierRoll(t *testing.T) {
	dir := t.TempDir()
	cmd := exec.Command("/usr/bin/true")
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	dead := cmd.Process.Pid
	pending := filepath.Join(dir, fmt.Sprintf(".crypt.log.roll-%d", dead))
	_ = os.WriteFile(pending, []byte("[2026-09-01 10:00:00] INFO  stranded\n"), 0o644)
	today := time.Date(2026, 9, 3, 8, 0, 0, 0, time.Local)
	_ = os.WriteFile(filepath.Join(dir, "crypt.log"), []byte("[2026-09-03 07:00:00] INFO  today\n"), 0o644)
	Roll(dir, "crypt.log", today)
	if got := readOrEmpty(t, filepath.Join(dir, "crypt-2026-09-01.log")); got != "[2026-09-01 10:00:00] INFO  stranded\n" {
		t.Fatalf("stranded records not recovered: %q", got)
	}
	assertNoPending(t, dir)
}

// Writers append the way the plugin does (open with O_APPEND per record)
// while Roll runs; no record may be lost or duplicated.
func TestRollLosesNothingWhileOthersAppend(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "crypt.log")
	var seed strings.Builder
	for i := 0; i < 200; i++ {
		fmt.Fprintf(&seed, "[2026-09-02 12:00:00] INFO  seed %d\n", i)
	}
	_ = os.WriteFile(path, []byte(seed.String()), 0o644)
	today := time.Date(2026, 9, 3, 8, 0, 0, 0, time.Local)

	const writers, each = 8, 150
	var wg sync.WaitGroup
	start := make(chan struct{})
	for w := 0; w < writers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			<-start
			for i := 0; i < each; i++ {
				f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
				if err != nil {
					t.Error(err)
					return
				}
				_, _ = fmt.Fprintf(f, "[2026-09-03 08:00:00] INFO  w%d r%d\n", w, i)
				_ = f.Close()
			}
		}(w)
	}
	close(start)
	for i := 0; i < 20; i++ {
		Roll(dir, "crypt.log", today)
	}
	wg.Wait()

	all := readOrEmpty(t, path) +
		readOrEmpty(t, filepath.Join(dir, "crypt-2026-09-02.log")) +
		readOrEmpty(t, filepath.Join(dir, "crypt-2026-09-03.log"))
	lines := strings.Split(strings.TrimSuffix(all, "\n"), "\n")
	if len(lines) != 200+writers*each {
		t.Fatalf("got %d records, want %d", len(lines), 200+writers*each)
	}
	seen := map[string]bool{}
	for _, l := range lines {
		if seen[l] {
			t.Fatalf("duplicate record %q", l)
		}
		seen[l] = true
	}
	if got := readOrEmpty(t, filepath.Join(dir, "crypt-2026-09-02.log")); strings.Count(got, "\n") != 200 {
		t.Fatalf("seed day file has %d records", strings.Count(got, "\n"))
	}
	assertNoPending(t, dir)
}
