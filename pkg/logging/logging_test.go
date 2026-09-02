package logging

import (
	"os"
	"path/filepath"
	"strings"
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
