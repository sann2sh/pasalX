// Package mail provides transactional email delivery (Gmail SMTP with STARTTLS
// and an in-memory LogMailer for tests and local development).
package mail

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"html"
	"log/slog"
	"net"
	"net/smtp"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Message represents a single outbound email.
type Message struct {
	To       string
	Subject  string
	TextBody string
	HTMLBody string
}

// Mailer sends transactional emails.
type Mailer interface {
	Send(ctx context.Context, msg Message) error
	Enqueue(msg Message)
	Close()
}

// Config configures the SMTPMailer.
type Config struct {
	Host               string
	Port               int
	Username           string
	Password           string
	From               string
	Timeout            time.Duration
	MaxPerRecipientWin int
	RecipientWindow    time.Duration
}

// ConfigFromEnv reads SMTP_* environment variables. Returns ok=false when
// SMTP_HOST or SMTP_PASS are not configured.
func ConfigFromEnv() (Config, bool) {
	host := strings.TrimSpace(os.Getenv("SMTP_HOST"))
	user := strings.TrimSpace(os.Getenv("SMTP_USER"))
	pass := strings.TrimSpace(os.Getenv("SMTP_PASS"))
	from := strings.TrimSpace(os.Getenv("SMTP_FROM"))
	if host == "" {
		host = "smtp.gmail.com"
	}
	port := 587
	if raw := strings.TrimSpace(os.Getenv("SMTP_PORT")); raw != "" {
		if p, err := strconv.Atoi(raw); err == nil && p > 0 {
			port = p
		}
	}
	if from == "" || !strings.Contains(from, "@") {
		from = user
	}
	if user == "" || pass == "" {
		return Config{}, false
	}
	return Config{
		Host:               host,
		Port:               port,
		Username:           user,
		Password:           pass,
		From:               from,
		Timeout:            10 * time.Second,
		MaxPerRecipientWin: 8,
		RecipientWindow:    15 * time.Minute,
	}, true
}

// ---------------------------------------------------------------- LogMailer

// LogMailer records sent emails in memory and logs metadata (never secrets in
// production logs, though tests inspect Sent()).
type LogMailer struct {
	mu   sync.Mutex
	sent []Message
}

func NewLogMailer() *LogMailer { return &LogMailer{} }

func (m *LogMailer) Send(_ context.Context, msg Message) error {
	m.mu.Lock()
	m.sent = append(m.sent, msg)
	m.mu.Unlock()
	slog.Info("mail_logged", "to", msg.To, "subject", msg.Subject)
	return nil
}

func (m *LogMailer) Enqueue(msg Message) {
	_ = m.Send(context.Background(), msg)
}

func (m *LogMailer) Close() {}

// Sent returns a copy of all recorded messages (for tests).
func (m *LogMailer) Sent() []Message {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Message, len(m.sent))
	copy(out, m.sent)
	return out
}

// ---------------------------------------------------------------- SMTPMailer

// SMTPMailer sends mail over SMTP with mandatory STARTTLS, per-recipient
// rate limiting, and a bounded background retry queue.
type SMTPMailer struct {
	cfg    Config
	queue  chan Message
	wg     sync.WaitGroup
	stopCh chan struct{}
	once   sync.Once

	mu        sync.Mutex
	recipient map[string][]time.Time
}

// NewSMTPMailer creates and starts an SMTPMailer worker.
func NewSMTPMailer(cfg Config) (*SMTPMailer, error) {
	if cfg.Host == "" || cfg.Port <= 0 || cfg.Username == "" || cfg.Password == "" {
		return nil, errors.New("incomplete SMTP configuration")
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 10 * time.Second
	}
	if cfg.MaxPerRecipientWin <= 0 {
		cfg.MaxPerRecipientWin = 8
	}
	if cfg.RecipientWindow <= 0 {
		cfg.RecipientWindow = 15 * time.Minute
	}
	if cfg.From == "" {
		cfg.From = cfg.Username
	}
	m := &SMTPMailer{
		cfg:       cfg,
		queue:     make(chan Message, 128),
		stopCh:    make(chan struct{}),
		recipient: make(map[string][]time.Time),
	}
	m.wg.Add(1)
	go m.worker()
	return m, nil
}

// Close drains pending queued emails (up to 5s) and stops the worker.
func (m *SMTPMailer) Close() {
	m.once.Do(func() {
		close(m.stopCh)
		done := make(chan struct{})
		go func() {
			m.wg.Wait()
			close(done)
		}()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
		}
	})
}

// Enqueue queues a message for asynchronous delivery with retries.
func (m *SMTPMailer) Enqueue(msg Message) {
	select {
	case <-m.stopCh:
		return
	default:
	}
	select {
	case m.queue <- msg:
	default:
		slog.Warn("mail_queue_full", "to", msg.To, "subject", msg.Subject)
	}
}

func (m *SMTPMailer) worker() {
	defer m.wg.Done()
	for {
		select {
		case <-m.stopCh:
			return
		case msg := <-m.queue:
			m.deliverWithRetry(msg)
		}
	}
}

func (m *SMTPMailer) deliverWithRetry(msg Message) {
	backoffs := []time.Duration{0, 2 * time.Second, 5 * time.Second}
	for i, wait := range backoffs {
		if wait > 0 {
			select {
			case <-m.stopCh:
				return
			case <-time.After(wait):
			}
		}
		ctx, cancel := context.WithTimeout(context.Background(), m.cfg.Timeout)
		err := m.Send(ctx, msg)
		cancel()
		if err == nil {
			return
		}
		slog.Warn("mail_send_attempt_failed", "attempt", i+1, "to", msg.To, "err", err)
	}
}

func (m *SMTPMailer) allowRecipient(to string, now time.Time) bool {
	key := strings.ToLower(strings.TrimSpace(to))
	cutoff := now.Add(-m.cfg.RecipientWindow)
	m.mu.Lock()
	defer m.mu.Unlock()
	times := m.recipient[key]
	kept := times[:0]
	for _, t := range times {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	if len(kept) >= m.cfg.MaxPerRecipientWin {
		m.recipient[key] = kept
		return false
	}
	kept = append(kept, now)
	m.recipient[key] = kept
	return true
}

// Send delivers msg synchronously over SMTP with mandatory STARTTLS.
func (m *SMTPMailer) Send(ctx context.Context, msg Message) error {
	to := sanitizeHeader(msg.To)
	subject := sanitizeHeader(msg.Subject)
	from := sanitizeHeader(m.cfg.From)
	if to == "" || !strings.Contains(to, "@") {
		return errors.New("invalid recipient address")
	}
	if !m.allowRecipient(to, time.Now().UTC()) {
		return errors.New("recipient email rate limit exceeded")
	}

	addr := net.JoinHostPort(m.cfg.Host, strconv.Itoa(m.cfg.Port))
	dialer := &net.Dialer{Timeout: m.cfg.Timeout}
	conn, err := dialer.DialContext(ctx, "tcp", addr)
	if err != nil {
		return fmt.Errorf("smtp dial: %w", err)
	}
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	} else {
		_ = conn.SetDeadline(time.Now().Add(m.cfg.Timeout))
	}

	c, err := smtp.NewClient(conn, m.cfg.Host)
	if err != nil {
		_ = conn.Close()
		return fmt.Errorf("smtp client: %w", err)
	}
	defer c.Close()

	if ok, _ := c.Extension("STARTTLS"); !ok {
		return errors.New("smtp server does not support STARTTLS")
	}
	tlsCfg := &tls.Config{
		ServerName: m.cfg.Host,
		MinVersion: tls.VersionTLS12,
	}
	if err := c.StartTLS(tlsCfg); err != nil {
		return fmt.Errorf("smtp starttls: %w", err)
	}
	auth := smtp.PlainAuth("", m.cfg.Username, m.cfg.Password, m.cfg.Host)
	if err := c.Auth(auth); err != nil {
		return fmt.Errorf("smtp auth: %w", err)
	}
	if err := c.Mail(from); err != nil {
		return fmt.Errorf("smtp mail from: %w", err)
	}
	if err := c.Rcpt(to); err != nil {
		return fmt.Errorf("smtp rcpt to: %w", err)
	}
	w, err := c.Data()
	if err != nil {
		return fmt.Errorf("smtp data: %w", err)
	}
	raw := buildMIME(from, to, subject, msg.TextBody, msg.HTMLBody)
	if _, err := w.Write(raw); err != nil {
		_ = w.Close()
		return fmt.Errorf("smtp write: %w", err)
	}
	if err := w.Close(); err != nil {
		return fmt.Errorf("smtp data close: %w", err)
	}
	return c.Quit()
}

func sanitizeHeader(s string) string {
	s = strings.ReplaceAll(s, "\r", "")
	s = strings.ReplaceAll(s, "\n", "")
	return strings.TrimSpace(s)
}

func buildMIME(from, to, subject, textBody, htmlBody string) []byte {
	boundary := "pasalx-boundary-7f3a9c12"
	var buf bytes.Buffer
	fmt.Fprintf(&buf, "From: PasalX <%s>\r\n", from)
	fmt.Fprintf(&buf, "To: %s\r\n", to)
	fmt.Fprintf(&buf, "Subject: %s\r\n", subject)
	fmt.Fprintf(&buf, "MIME-Version: 1.0\r\n")
	if htmlBody == "" {
		fmt.Fprintf(&buf, "Content-Type: text/plain; charset=UTF-8\r\n\r\n")
		buf.WriteString(textBody)
		return buf.Bytes()
	}
	fmt.Fprintf(&buf, "Content-Type: multipart/alternative; boundary=%q\r\n\r\n", boundary)
	fmt.Fprintf(&buf, "--%s\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n%s\r\n", boundary, textBody)
	fmt.Fprintf(&buf, "--%s\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n%s\r\n", boundary, htmlBody)
	fmt.Fprintf(&buf, "--%s--\r\n", boundary)
	return buf.Bytes()
}

// ---------------------------------------------------------------- Templates

// VerificationMessage builds the 6-digit email verification message.
func VerificationMessage(to, name, code string) Message {
	safeName := html.EscapeString(name)
	safeCode := html.EscapeString(code)
	return Message{
		To:      to,
		Subject: "PasalX Email Verification Code",
		TextBody: fmt.Sprintf(
			"Hi %s,\n\nYour PasalX verification code is: %s\n\nThis code expires in 15 minutes. If you did not create a PasalX account, ignore this email.\n",
			name, code,
		),
		HTMLBody: fmt.Sprintf(
			`<div style="font-family:sans-serif;max-width:480px;margin:auto;padding:24px;border:1px solid #e5e7eb;border-radius:12px">`+
				`<h2 style="margin:0 0 12px;color:#111827">Verify your PasalX email</h2>`+
				`<p style="color:#374151">Hi %s, enter this 6-digit code in the PasalX app:</p>`+
				`<div style="font-size:28px;font-weight:700;letter-spacing:6px;padding:16px;background:#f3f4f6;border-radius:8px;text-align:center;color:#0f766e">%s</div>`+
				`<p style="color:#6b7280;font-size:13px;margin-top:16px">Expires in 15 minutes.</p></div>`,
			safeName, safeCode,
		),
	}
}

// PasswordResetMessage builds the 6-digit password reset message.
func PasswordResetMessage(to, name, code string) Message {
	safeName := html.EscapeString(name)
	safeCode := html.EscapeString(code)
	return Message{
		To:      to,
		Subject: "PasalX Password Reset Code",
		TextBody: fmt.Sprintf(
			"Hi %s,\n\nYour PasalX password reset code is: %s\n\nThis code expires in 15 minutes. If you did not request a reset, ignore this email.\n",
			name, code,
		),
		HTMLBody: fmt.Sprintf(
			`<div style="font-family:sans-serif;max-width:480px;margin:auto;padding:24px;border:1px solid #e5e7eb;border-radius:12px">`+
				`<h2 style="margin:0 0 12px;color:#111827">Reset your PasalX password</h2>`+
				`<p style="color:#374151">Hi %s, use this 6-digit code to reset your password:</p>`+
				`<div style="font-size:28px;font-weight:700;letter-spacing:6px;padding:16px;background:#f3f4f6;border-radius:8px;text-align:center;color:#b45309">%s</div>`+
				`<p style="color:#6b7280;font-size:13px;margin-top:16px">Expires in 15 minutes.</p></div>`,
			safeName, safeCode,
		),
	}
}

// InvitationMessage builds the store invitation email.
func InvitationMessage(to, storeName, inviterName, role, code string, expiresAt time.Time) Message {
	safeStore := html.EscapeString(storeName)
	safeInviter := html.EscapeString(inviterName)
	safeRole := html.EscapeString(role)
	safeCode := html.EscapeString(code)
	exp := expiresAt.UTC().Format("2006-01-02 15:04 UTC")
	return Message{
		To:      to,
		Subject: fmt.Sprintf("You're invited to join %s on PasalX", storeName),
		TextBody: fmt.Sprintf(
			"%s invited you to join %s as %s on PasalX.\n\nInvite code: %s\nExpires: %s\n\nOpen PasalX, verify your account, and choose 'Join with Invite Code'.\n",
			inviterName, storeName, role, code, exp,
		),
		HTMLBody: fmt.Sprintf(
			`<div style="font-family:sans-serif;max-width:480px;margin:auto;padding:24px;border:1px solid #e5e7eb;border-radius:12px">`+
				`<h2 style="margin:0 0 12px;color:#111827">Store Invitation</h2>`+
				`<p style="color:#374151">%s invited you to join <strong>%s</strong> as <strong>%s</strong>.</p>`+
				`<div style="font-size:22px;font-weight:700;letter-spacing:2px;padding:16px;background:#f3f4f6;border-radius:8px;text-align:center;color:#0f766e">%s</div>`+
				`<p style="color:#6b7280;font-size:13px;margin-top:16px">Single-use code. Expires %s.</p></div>`,
			safeInviter, safeStore, safeRole, safeCode, exp,
		),
	}
}

// DeviceApprovalMessage notifies a staff member when their phone is approved or rejected.
func DeviceApprovalMessage(to, name, storeName, deviceName, deviceCode string, approved bool) Message {
	statusWord := "Approved"
	detail := fmt.Sprintf("Your device %q has been approved for %s (Device #%s). You can now log in with your username and 6-digit PIN.", deviceName, storeName, deviceCode)
	if !approved {
		statusWord = "Declined"
		detail = fmt.Sprintf("Your device request (%q) for %s was declined by the store owner.", deviceName, storeName)
	}
	return Message{
		To:       to,
		Subject:  fmt.Sprintf("PasalX Device %s — %s", statusWord, storeName),
		TextBody: fmt.Sprintf("Hi %s,\n\n%s\n", name, detail),
		HTMLBody: fmt.Sprintf(
			`<div style="font-family:sans-serif;max-width:480px;margin:auto;padding:24px;border:1px solid #e5e7eb;border-radius:12px">`+
				`<h2 style="margin:0 0 12px;color:#111827">Device %s</h2>`+
				`<p style="color:#374151">Hi %s,</p><p style="color:#374151">%s</p></div>`,
			statusWord, html.EscapeString(name), html.EscapeString(detail),
		),
	}
}

