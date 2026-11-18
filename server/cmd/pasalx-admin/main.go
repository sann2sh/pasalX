// Command pasalx-admin performs server administration and bootstrap tasks that
// must not be exposed over HTTP: migrations, master key generation, user
// recovery, and store lifecycle management.
//
//	go run ./cmd/pasalx-admin gen-master-key
//	PASALX_ADMIN_PASSWORD=... go run ./cmd/pasalx-admin create-user \
//	    -name "Shop Owner" -email owner@example.com -username owner -store "My Shop" [-pin 123456]
package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/base64"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/sys/unix"

	"pasalx/server/internal/auth"
	"pasalx/server/internal/db"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "gen-master-key":
		genMasterKey()
	case "create-user":
		createUser(os.Args[2:])
	case "migrate":
		runMigrate(os.Args[2:])
	case "reset-password":
		adminResetPassword(os.Args[2:])
	case "verify-email":
		adminVerifyEmail(os.Args[2:])
	case "list-stores":
		adminListStores()
	case "close-store":
		adminCloseStore(os.Args[2:])
	case "purge-closed-stores":
		adminPurgeClosedStores()
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: pasalx-admin <gen-master-key | migrate <up|down [N]|version> | create-user | reset-password | verify-email | list-stores | close-store | purge-closed-stores>")
	fmt.Fprintln(os.Stderr, "passwords are read from $PASALX_ADMIN_PASSWORD or stdin (never a CLI flag, to keep them out of shell history).")
	os.Exit(2)
}

func genMasterKey() {
	k := make([]byte, 32)
	if _, err := rand.Read(k); err != nil {
		fmt.Fprintln(os.Stderr, "rand:", err)
		os.Exit(1)
	}
	fmt.Println(base64.StdEncoding.EncodeToString(k))
}

func createUser(args []string) {
	fs := flag.NewFlagSet("create-user", flag.ExitOnError)
	name := fs.String("name", "", "full name")
	email := fs.String("email", "", "email address")
	username := fs.String("username", "", "login username (lowercase)")
	storeName := fs.String("store", "", "optional store name to create as OWNER")
	pin := fs.String("pin", "", "optional 6-digit PIN")
	fs.Parse(args)

	password := os.Getenv("PASALX_ADMIN_PASSWORD")
	if password == "" {
		fmt.Fprint(os.Stderr, "Password: ")
		password = readPasswordNoEcho()
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	pool, err := connectAdminPool(ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer pool.Close()

	svc := auth.NewService(pool, nil)
	u, err := svc.CreateUser(ctx, *name, *email, *username, password, *pin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "create-user failed:", err)
		os.Exit(1)
	}
	fmt.Printf("created user %q (id=%s, email=%s)\n", u.Username, u.ID, u.Email)
	if strings.TrimSpace(*storeName) != "" {
		sid, err := svc.CreateStoreWithOwner(ctx, u.ID, *storeName)
		if err != nil {
			fmt.Fprintln(os.Stderr, "create-store failed:", err)
			os.Exit(1)
		}
		fmt.Printf("created store %q (id=%s) with OWNER=%s\n", *storeName, sid, u.Username)
	}
}

func runMigrate(args []string) {
	if len(args) == 0 {
		usage()
	}
	dbURL := os.Getenv("DATABASE_MIGRATE_URL")
	if dbURL == "" {
		dbURL = os.Getenv("DATABASE_URL")
	}
	if dbURL == "" {
		fmt.Fprintln(os.Stderr, "DATABASE_MIGRATE_URL or DATABASE_URL is required for migrate")
		os.Exit(1)
	}

	switch args[0] {
	case "up":
		v, changed, err := db.MigrateUp(dbURL)
		if err != nil {
			fmt.Fprintln(os.Stderr, "migrate up failed:", err)
			os.Exit(1)
		}
		if changed {
			fmt.Printf("migrated up to version %d\n", v)
		} else {
			fmt.Printf("already at latest version %d\n", v)
		}
	case "down":
		steps := 1
		if len(args) >= 2 {
			n, err := strconv.Atoi(args[1])
			if err != nil || n <= 0 {
				fmt.Fprintln(os.Stderr, "migrate down steps must be a positive integer")
				os.Exit(2)
			}
			steps = n
		}
		v, dirty, err := db.MigrateDown(dbURL, steps)
		if err != nil {
			fmt.Fprintln(os.Stderr, "migrate down failed:", err)
			os.Exit(1)
		}
		fmt.Printf("rolled back %d step(s); current version=%d dirty=%v\n", steps, v, dirty)
	case "version":
		v, dirty, err := db.MigrateVersion(dbURL)
		if err != nil {
			fmt.Fprintln(os.Stderr, "migrate version failed:", err)
			os.Exit(1)
		}
		fmt.Printf("version=%d dirty=%v\n", v, dirty)
	default:
		usage()
	}
}

func readPasswordNoEcho() string {
	fd := int(os.Stdin.Fd())
	if old, err := unix.IoctlGetTermios(fd, unix.TCGETS); err == nil {
		noEcho := *old
		noEcho.Lflag &^= unix.ECHO
		_ = unix.IoctlSetTermios(fd, unix.TCSETS, &noEcho)
		defer func() {
			_ = unix.IoctlSetTermios(fd, unix.TCSETS, old)
			fmt.Fprintln(os.Stderr)
		}()
	}
	line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
	return strings.TrimRight(line, "\r\n")
}

func adminResetPassword(args []string) {
	fs := flag.NewFlagSet("reset-password", flag.ExitOnError)
	user := fs.String("user", "", "email or username")
	fs.Parse(args)
	if *user == "" {
		fmt.Fprintln(os.Stderr, "-user is required")
		os.Exit(2)
	}
	password := os.Getenv("PASALX_ADMIN_PASSWORD")
	if password == "" {
		fmt.Fprint(os.Stderr, "New Password: ")
		password = readPasswordNoEcho()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	pool, err := connectAdminPool(ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer pool.Close()
	if err := auth.NewService(pool, nil).AdminResetPassword(ctx, *user, password); err != nil {
		fmt.Fprintln(os.Stderr, "reset-password failed:", err)
		os.Exit(1)
	}
	fmt.Printf("password reset for %q (all active sessions invalidated)\n", *user)
}

func adminVerifyEmail(args []string) {
	fs := flag.NewFlagSet("verify-email", flag.ExitOnError)
	user := fs.String("user", "", "email or username")
	fs.Parse(args)
	if *user == "" {
		fmt.Fprintln(os.Stderr, "-user is required")
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	pool, err := connectAdminPool(ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer pool.Close()
	if err := auth.NewService(pool, nil).AdminVerifyEmail(ctx, *user); err != nil {
		fmt.Fprintln(os.Stderr, "verify-email failed:", err)
		os.Exit(1)
	}
	fmt.Printf("email verified for %q\n", *user)
}

func adminListStores() {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	pool, err := connectAdminPool(ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer pool.Close()
	stores, err := auth.NewService(pool, nil).AdminListStores(ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, "list-stores failed:", err)
		os.Exit(1)
	}
	for _, st := range stores {
		fmt.Printf("%s\t%s\t%s\tcreated=%s\n", st.ID, st.Status, st.Name, st.CreatedAt.Format(time.RFC3339))
	}
}

func adminCloseStore(args []string) {
	fs := flag.NewFlagSet("close-store", flag.ExitOnError)
	storeID := fs.String("store", "", "store ID")
	fs.Parse(args)
	if *storeID == "" {
		fmt.Fprintln(os.Stderr, "-store is required")
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	pool, err := connectAdminPool(ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer pool.Close()
	if err := auth.NewService(pool, nil).AdminCloseStore(ctx, *storeID); err != nil {
		fmt.Fprintln(os.Stderr, "close-store failed:", err)
		os.Exit(1)
	}
	fmt.Printf("closed store %s (purge_after = +30d)\n", *storeID)
}

func adminPurgeClosedStores() {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	pool, err := connectAdminPool(ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer pool.Close()
	n, err := auth.NewService(pool, nil).AdminPurgeClosedStores(ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, "purge-closed-stores failed:", err)
		os.Exit(1)
	}
	fmt.Printf("purged %d expired closed store(s)\n", n)
}

func connectAdminPool(ctx context.Context) (*pgxpool.Pool, error) {
	if migURL := os.Getenv("DATABASE_MIGRATE_URL"); migURL != "" && os.Getenv("DATABASE_URL") != migURL {
		_ = os.Setenv("DATABASE_URL", migURL)
	}
	return db.ConnectPool(ctx)
}
