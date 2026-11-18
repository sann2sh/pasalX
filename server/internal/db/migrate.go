package db

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"regexp"
	"strconv"
	"strings"

	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/pgx/v5"
	"github.com/golang-migrate/migrate/v4/source/iofs"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"pasalx/server/migrations"
)

var upMigrationFilePattern = regexp.MustCompile(`^(\d+)_.*\.up\.sql$`)

// ExpectedMigrationVersion returns the highest migration version embedded in
// server/migrations/*.up.sql.
func ExpectedMigrationVersion() (uint, error) {
	entries, err := fs.ReadDir(migrations.FS, ".")
	if err != nil {
		return 0, fmt.Errorf("read embedded migrations: %w", err)
	}
	var maxVer uint
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		m := upMigrationFilePattern.FindStringSubmatch(entry.Name())
		if m == nil {
			continue
		}
		v, err := strconv.ParseUint(m[1], 10, 32)
		if err != nil {
			return 0, fmt.Errorf("parse migration version %q: %w", entry.Name(), err)
		}
		if uint(v) > maxVer {
			maxVer = uint(v)
		}
	}
	if maxVer == 0 {
		return 0, errors.New("no embedded up migrations found")
	}
	return maxVer, nil
}

// CheckSchemaVersion verifies that PostgreSQL's schema_migrations table exists,
// is not dirty, and matches ExpectedMigrationVersion(). The API refuses to start
// if the database schema is missing or out of sync with the binary.
func CheckSchemaVersion(ctx context.Context, pool *pgxpool.Pool) (uint, error) {
	expected, err := ExpectedMigrationVersion()
	if err != nil {
		return 0, err
	}

	var version uint
	var dirty bool
	err = pool.QueryRow(ctx, `SELECT version, dirty FROM schema_migrations LIMIT 1`).Scan(&version, &dirty)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, fmt.Errorf("schema_migrations is empty (expected version %d); run 'pasalx-admin migrate up'", expected)
		}
		return 0, fmt.Errorf("schema_migrations check failed (expected version %d; run 'pasalx-admin migrate up'): %w", expected, err)
	}
	if dirty {
		return version, fmt.Errorf("database schema_migrations is dirty at version %d; manual intervention required", version)
	}
	if version != expected {
		return version, fmt.Errorf("database schema version %d does not match binary expected version %d; run 'pasalx-admin migrate up'", version, expected)
	}
	return version, nil
}

func newMigrator(dbURL string) (*migrate.Migrate, error) {
	if strings.TrimSpace(dbURL) == "" {
		return nil, errors.New("database URL is required for migration")
	}
	srcDriver, err := iofs.New(migrations.FS, ".")
	if err != nil {
		return nil, fmt.Errorf("init embedded migration source: %w", err)
	}
	// golang-migrate's pgx/v5 driver expects the "pgx5://" scheme.
	pgxURL := dbURL
	switch {
	case strings.HasPrefix(pgxURL, "postgres://"):
		pgxURL = "pgx5://" + strings.TrimPrefix(pgxURL, "postgres://")
	case strings.HasPrefix(pgxURL, "postgresql://"):
		pgxURL = "pgx5://" + strings.TrimPrefix(pgxURL, "postgresql://")
	}
	m, err := migrate.NewWithSourceInstance("iofs", srcDriver, pgxURL)
	if err != nil {
		return nil, fmt.Errorf("init migrator: %w", err)
	}
	return m, nil
}

// MigrateUp applies all pending embedded migrations.
func MigrateUp(dbURL string) (version uint, changed bool, err error) {
	m, err := newMigrator(dbURL)
	if err != nil {
		return 0, false, err
	}
	defer m.Close()

	if err := m.Up(); err != nil {
		if errors.Is(err, migrate.ErrNoChange) {
			v, _, verr := m.Version()
			return v, false, verr
		}
		return 0, false, err
	}
	v, _, verr := m.Version()
	return v, true, verr
}

// MigrateDown rolls back steps migrations (or all if steps <= 0).
func MigrateDown(dbURL string, steps int) (version uint, dirty bool, err error) {
	m, err := newMigrator(dbURL)
	if err != nil {
		return 0, false, err
	}
	defer m.Close()

	if steps <= 0 {
		err = m.Down()
	} else {
		err = m.Steps(-steps)
	}
	if err != nil && !errors.Is(err, migrate.ErrNoChange) {
		return 0, false, err
	}
	v, d, verr := m.Version()
	if errors.Is(verr, migrate.ErrNilVersion) {
		return 0, false, nil
	}
	return v, d, verr
}

// MigrateVersion returns the current applied migration version and dirty flag.
func MigrateVersion(dbURL string) (version uint, dirty bool, err error) {
	m, err := newMigrator(dbURL)
	if err != nil {
		return 0, false, err
	}
	defer m.Close()

	v, d, verr := m.Version()
	if errors.Is(verr, migrate.ErrNilVersion) {
		return 0, false, nil
	}
	return v, d, verr
}

