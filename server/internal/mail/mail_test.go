package mail

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestLogMailerAndTemplates(t *testing.T) {
	m := NewLogMailer()
	defer m.Close()

	msg := VerificationMessage("user@example.com", "<script>alert(1)</script>", "123456")
	if strings.Contains(msg.HTMLBody, "<script>") {
		t.Fatal("expected HTML escaping in VerificationMessage")
	}
	if !strings.Contains(msg.TextBody, "123456") {
		t.Fatal("expected code in TextBody")
	}
	if err := m.Send(context.Background(), msg); err != nil {
		t.Fatalf("Send: %v", err)
	}

	m.Enqueue(PasswordResetMessage("user@example.com", "Alice", "654321"))
	m.Enqueue(InvitationMessage("staff@example.com", "Pasal A", "Owner", "STAFF", "PSX-23456-789AB", time.Now().Add(48*time.Hour)))
	m.Enqueue(DeviceApprovalMessage("staff@example.com", "Bob", "Pasal A", "Pixel 8", "02", true))

	sent := m.Sent()
	if len(sent) != 4 {
		t.Fatalf("expected 4 sent messages, got %d", len(sent))
	}
}

func TestSanitizeHeaderStripsCRLF(t *testing.T) {
	got := sanitizeHeader("user@example.com\r\nBcc: evil@attacker.com")
	if strings.ContainsAny(got, "\r\n") {
		t.Fatalf("expected CRLF stripped, got %q", got)
	}
}

