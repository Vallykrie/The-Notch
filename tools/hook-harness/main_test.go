package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestLoadScenarioRejectsStepWithoutExactlyOneInput(t *testing.T) {
	t.Parallel()

	for _, body := range []string{
		`{"name":"missing","steps":[{"label":"bad","source":"claude","expect":{"exit_code":0}}]}`,
		`{"name":"both","steps":[{"label":"bad","source":"claude","input":{},"raw_input":"junk","expect":{"exit_code":0}}]}`,
	} {
		if _, err := decodeScenario(strings.NewReader(body)); err == nil {
			t.Fatalf("decodeScenario(%s) succeeded; want validation error", body)
		}
	}
}

func TestServeRepliesAndRecordsPermissionEnvelope(t *testing.T) {
	t.Parallel()

	temp, err := os.MkdirTemp("/tmp", "notch-harness-test-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(temp)
	socketPath := filepath.Join(temp, "fake.sock")
	reportPath := filepath.Join(temp, "received.jsonl")
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	ready := make(chan struct{})
	var output bytes.Buffer
	errCh := make(chan error, 1)
	go func() {
		errCh <- serve(ctx, serveOptions{
			socketPath: socketPath,
			reportPath: reportPath,
			decision:   "allow_always",
			ready:      ready,
		}, &output)
	}()

	select {
	case <-ready:
	case err := <-errCh:
		if errors.Is(err, syscall.EPERM) {
			t.Skip("sandbox does not permit binding Unix sockets")
		}
		t.Fatalf("serve failed before readiness: %v", err)
	case <-ctx.Done():
		t.Fatal("server did not become ready before timeout")
	}

	connection, err := net.DialTimeout("unix", socketPath, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	request := `{"id":"11111111-1111-4111-8111-111111111111","event_name":"PermissionRequest","source":"claude","cwd":"/work/a","timeout":2,"payload":{"tool_name":"Bash"}}` + "\n"
	if _, err := connection.Write([]byte(request)); err != nil {
		t.Fatal(err)
	}
	if err := connection.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	line, err := bufio.NewReader(connection).ReadBytes('\n')
	_ = connection.Close()
	if err != nil {
		t.Fatal(err)
	}
	var response responseEnvelope
	if err := json.Unmarshal(line, &response); err != nil {
		t.Fatal(err)
	}
	if response.ID != "11111111-1111-4111-8111-111111111111" || response.Decision != "allow_always" {
		t.Fatalf("response = %#v", response)
	}

	cancel()
	select {
	case err := <-errCh:
		if err != nil {
			t.Fatalf("serve returned %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("serve did not stop after cancellation")
	}

	report, err := os.ReadFile(reportPath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(strings.TrimSpace(string(report)), "\n") != 0 || !bytes.Contains(report, []byte(`"event_name":"PermissionRequest"`)) {
		t.Fatalf("report = %q", report)
	}
	if !strings.Contains(output.String(), `"event_name": "PermissionRequest"`) {
		t.Fatalf("readable output missing envelope: %s", output.String())
	}
}

func TestRunChildTimesOutAndReaps(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell fixture is Unix-only")
	}
	t.Parallel()

	started := time.Now()
	result := runChild(context.Background(), childSpec{
		command: "sh",
		args:    []string{"-c", "sleep 5"},
		stdin:   []byte("{}"),
		timeout: 75 * time.Millisecond,
		environ: os.Environ(),
	})
	if !result.timedOut {
		t.Fatalf("result = %#v; want timedOut", result)
	}
	if time.Since(started) > 2*time.Second {
		t.Fatalf("timed-out child took %s to reap", time.Since(started))
	}
}
