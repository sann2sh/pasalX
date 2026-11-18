package migrations

import "embed"

// FS embeds all versioned SQL migration files into the server binaries.
//
//go:embed *.sql
var FS embed.FS

