// Command pasalx-admin performs server bootstrap tasks that must not be
// exposed over HTTP: generating the master key and creating the first OWNER.
//
//	go run ./cmd/pasalx-admin gen-master-key
//	PASALX_ADMIN_PASSWORD=... go run ./cmd/pasalx-admin create-user \
//	    -name "Shop Owner" -username owner -role OWNER [-pin 123456]
package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/base64"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

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
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: pasalx-admin <gen-master-key | create-user -name N -username U -role OWNER|MANAGER|STAFF [-pin 6digits]>")
	fmt.Fprintln(os.Stderr, "create-user reads the password from $PASALX_ADMIN_PASSWORD or stdin (never a CLI flag, to keep it out of shell history).")
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
	username := fs.String("username", "", "login username (lowercase)")
	role := fs.String("role", auth.RoleStaff, "OWNER | MANAGER | STAFF")
	pin := fs.String("pin", "", "optional 6-digit PIN")
	fs.Parse(args)

	password := os.Getenv("PASALX_ADMIN_PASSWORD")
	if password == "" {
		fmt.Fprint(os.Stderr, "Password: ")
		password = readPasswordNoEcho()
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	pool, err := db.ConnectPool(ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer pool.Close()

	// CreateUser only hashes secrets (Argon2id); no key material is needed.
	u, err := auth.NewService(pool, nil).CreateUser(ctx, *name, *username, password, *pin, strings.ToUpper(*role))
	if err != nil {
		fmt.Fprintln(os.Stderr, "create-user failed:", err)
		os.Exit(1)
	}
	fmt.Printf("created %s user %q (id=%s)\n", u.Role, u.Username, u.ID)
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
