package db

import "testing"

func TestExpectedMigrationVersion(t *testing.T) {
	v, err := ExpectedMigrationVersion()
	if err != nil {
		t.Fatalf("ExpectedMigrationVersion failed: %v", err)
	}
	if v < 4 {
		t.Fatalf("expected embedded migration version >= 4, got %d", v)
	}
}

func TestNewMigratorRejectsEmptyURL(t *testing.T) {
	if _, err := newMigrator("   "); err == nil {
		t.Fatal("expected error for empty database URL")
	}
}

