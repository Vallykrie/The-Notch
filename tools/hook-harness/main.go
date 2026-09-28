package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	defaultHookBinary = "tools/notch-hook/dist/notch-hook-darwin-arm64"
	maxLineBytes      = 1 << 20
	maxSocketPath     = 103
)

type requestEnvelope struct {
	ID         string          `json:"id"`
	EventName  string          `json:"event_name"`
	Source     string          `json:"source"`
	CWD        string          `json:"cwd"`
	ThreadName string          `json:"thread_name,omitempty"`
	Timeout    float64         `json:"timeout"`
	Payload    json.RawMessage `json:"payload"`
}

type responseEnvelope struct {
	ID       string `json:"id"`
	Decision string `json:"decision"`
	Reason   string `json:"reason,omitempty"`
}

type serveOptions struct {
	socketPath    string
	reportPath    string
	decision      string
	decisionDelay time.Duration
	noReply       bool
	reason        string
	ready         chan<- struct{}
}

type scenario struct {
	Name  string `json:"name"`
	Steps []step `json:"steps"`
}

type step struct {
	Label          string               `json:"label"`
	Source         string               `json:"source"`
	Event          string               `json:"event,omitempty"`
	Input          json.RawMessage      `json:"input,omitempty"`
	RawInput       *string              `json:"raw_input,omitempty"`
	ProcessTimeout string               `json:"process_timeout"`
	Expect         stepExpectation      `json:"expect"`
	Envelope       *envelopeExpectation `json:"envelope,omitempty"`
}

type stepExpectation struct {
	ExitCode *int   `json:"exit_code"`
	TimedOut bool   `json:"timed_out"`
	Stdout   string `json:"stdout"`
}

type envelopeExpectation struct {
	EventName  string   `json:"event_name"`
	Source     string   `json:"source"`
	CWD        string   `json:"cwd"`
	ThreadName *string  `json:"thread_name,omitempty"`
	Timeout    *float64 `json:"timeout,omitempty"`
}

type childSpec struct {
	command string
	args    []string
	stdin   []byte
	timeout time.Duration
	environ []string
	dir     string
}

type childResult struct {
	exitCode int
	timedOut bool
	stdout   string
	stderr   string
	err      error
}

func main() {
	if len(os.Args) < 2 {
		usage(os.Stderr)
		os.Exit(2)
	}

	var err error
	switch os.Args[1] {
	case "serve":
		err = serveCommand(os.Args[2:])
	case "drive":
		err = driveCommand(os.Args[2:])
	case "help", "-h", "--help":
		usage(os.Stdout)
		return
	default:
		err = fmt.Errorf("unknown command %q", os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "hook-harness:", err)
		os.Exit(1)
	}
}

func usage(writer io.Writer) {
	fmt.Fprintln(writer, "usage: hook-harness serve [options]")
	fmt.Fprintln(writer, "       hook-harness drive --scenario FILE --socket PATH --report FILE [options]")
}

func serveCommand(arguments []string) error {
	flags := flag.NewFlagSet("serve", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	socketPath := flags.String("socket", "", "Unix socket path (default: unique temporary path)")
	reportPath := flags.String("report", "", "optional JSONL file recording valid envelopes")
	decision := flags.String("decision", "allow", "allow, deny, allow_always, or defer")
	delay := flags.Duration("decision-delay", 0, "delay before a permission reply")
	noReply := flags.Bool("no-reply", false, "accept permission requests without replying")
	reason := flags.String("reason", "", "optional decision reason")
	lifetime := flags.Duration("lifetime", 5*time.Minute, "maximum server lifetime")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if *lifetime <= 0 {
		return errors.New("--lifetime must be positive")
	}
	if *delay < 0 {
		return errors.New("--decision-delay cannot be negative")
	}
	if !validDecision(*decision) {
		return fmt.Errorf("invalid --decision %q", *decision)
	}

	var tempDir string
	if *socketPath == "" {
		var err error
		tempDir, err = os.MkdirTemp("/tmp", "notch-hook-harness-")
		if err != nil {
			return err
		}
		defer os.RemoveAll(tempDir)
		*socketPath = filepath.Join(tempDir, "hook.sock")
	}

	signalContext, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithTimeout(signalContext, *lifetime)
	defer cancel()
	return serve(ctx, serveOptions{
		socketPath:    *socketPath,
		reportPath:    *reportPath,
		decision:      *decision,
		decisionDelay: *delay,
		noReply:       *noReply,
		reason:        *reason,
	}, os.Stdout)
}

func validDecision(value string) bool {
	switch value {
	case "allow", "deny", "allow_always", "defer":
		return true
	default:
		return false
	}
}

func serve(ctx context.Context, options serveOptions, stdout io.Writer) error {
	if options.socketPath == "/tmp/the-notch.sock" {
		return errors.New("refusing to use the real app socket /tmp/the-notch.sock")
	}
	if len([]byte(options.socketPath)) > maxSocketPath {
		return fmt.Errorf("Unix socket path is too long: %s", options.socketPath)
	}
	if !validDecision(options.decision) {
		return fmt.Errorf("invalid decision %q", options.decision)
	}
	if err := prepareSocketPath(options.socketPath); err != nil {
		return err
	}

	listener, err := net.Listen("unix", options.socketPath)
	if err != nil {
		return err
	}
	if err := os.Chmod(options.socketPath, 0o600); err != nil {
		_ = listener.Close()
		_ = os.Remove(options.socketPath)
		return err
	}
	ownedInfo, err := os.Lstat(options.socketPath)
	if err != nil {
		_ = listener.Close()
		return err
	}
	defer func() {
		_ = listener.Close()
		if current, statErr := os.Lstat(options.socketPath); statErr == nil && os.SameFile(ownedInfo, current) {
			_ = os.Remove(options.socketPath)
		}
	}()

	var report *os.File
	if options.reportPath != "" {
		report, err = os.OpenFile(options.reportPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
		if err != nil {
			return err
		}
		defer report.Close()
	}

	logger := &serverLogger{stdout: stdout, report: report}
	fmt.Fprintf(stdout, "READY socket=%s\n", options.socketPath)
	if options.ready != nil {
		close(options.ready)
	}

	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()

	var connections sync.WaitGroup
	for {
		connection, acceptErr := listener.Accept()
		if acceptErr != nil {
			if ctx.Err() != nil || errors.Is(acceptErr, net.ErrClosed) {
				break
			}
			return acceptErr
		}
		connections.Add(1)
		go func() {
			defer connections.Done()
			handleConnection(ctx, connection, options, logger)
		}()
	}

	done := make(chan struct{})
	go func() {
		connections.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		return errors.New("timed out waiting for server connections to stop")
	}
	return nil
}

func prepareSocketPath(path string) error {
	if path == "" {
		return errors.New("socket path cannot be empty")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	_, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	connection, dialErr := net.DialTimeout("unix", path, 150*time.Millisecond)
	if dialErr == nil {
		_ = connection.Close()
		return fmt.Errorf("another server is already listening at %s", path)
	}
	return os.Remove(path)
}

type serverLogger struct {
	mu     sync.Mutex
	stdout io.Writer
	report *os.File
	count  int
}

func (logger *serverLogger) record(request requestEnvelope) error {
	logger.mu.Lock()
	defer logger.mu.Unlock()
	logger.count++
	fmt.Fprintf(logger.stdout, "ENVELOPE %d\n", logger.count)
	pretty, _ := json.MarshalIndent(request, "", "  ")
	fmt.Fprintln(logger.stdout, string(pretty))
	if logger.report == nil {
		return nil
	}
	compact, err := json.Marshal(request)
	if err != nil {
		return err
	}
	if _, err := logger.report.Write(append(compact, '\n')); err != nil {
		return err
	}
	return logger.report.Sync()
}

func handleConnection(ctx context.Context, connection net.Conn, options serveOptions, logger *serverLogger) {
	defer connection.Close()
	_ = connection.SetReadDeadline(time.Now().Add(30 * time.Second))
	scanner := bufio.NewScanner(connection)
	scanner.Buffer(make([]byte, 4096), maxLineBytes)
	for scanner.Scan() {
		var request requestEnvelope
		if err := json.Unmarshal(scanner.Bytes(), &request); err != nil {
			fmt.Fprintf(logger.stdout, "INVALID %q: %v\n", scanner.Text(), err)
			continue
		}
		if err := logger.record(request); err != nil {
			fmt.Fprintf(logger.stdout, "REPORT ERROR: %v\n", err)
		}
		if request.EventName != "PermissionRequest" {
			continue
		}
		if options.noReply {
			<-ctx.Done()
			return
		}
		if options.decisionDelay > 0 {
			timer := time.NewTimer(options.decisionDelay)
			select {
			case <-timer.C:
			case <-ctx.Done():
				if !timer.Stop() {
					<-timer.C
				}
				return
			}
		}
		response, err := json.Marshal(responseEnvelope{ID: request.ID, Decision: options.decision, Reason: options.reason})
		if err != nil {
			return
		}
		_ = connection.SetWriteDeadline(time.Now().Add(time.Second))
		_, _ = connection.Write(append(response, '\n'))
	}
}

func driveCommand(arguments []string) error {
	flags := flag.NewFlagSet("drive", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	scenarioPath := flags.String("scenario", "", "scenario JSON path or scenario name")
	socketPath := flags.String("socket", "", "fake server Unix socket path")
	reportPath := flags.String("report", "", "server JSONL report path")
	hookBinary := flags.String("hook-binary", defaultHookBinary, "path to notch-hook binary")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if *scenarioPath == "" || *socketPath == "" || *reportPath == "" {
		return errors.New("--scenario, --socket, and --report are required")
	}
	if *socketPath == "/tmp/the-notch.sock" {
		return errors.New("refusing to use the real app socket /tmp/the-notch.sock")
	}
	resolvedScenario := resolveScenarioPath(*scenarioPath)
	file, err := os.Open(resolvedScenario)
	if err != nil {
		return err
	}
	script, err := decodeScenario(file)
	_ = file.Close()
	if err != nil {
		return err
	}

	isolatedHome, err := os.MkdirTemp("", "notch-hook-drive-home-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(isolatedHome)
	environ := isolatedEnvironment(os.Environ(), isolatedHome, *socketPath)

	command := *hookBinary
	var baseArgs []string
	if _, statErr := os.Stat(command); statErr != nil {
		if command != defaultHookBinary || !errors.Is(statErr, os.ErrNotExist) {
			return fmt.Errorf("hook binary: %w", statErr)
		}
		command = "go"
		baseArgs = []string{"run", "./tools/notch-hook"}
	}

	failures := 0
	for _, current := range script.Steps {
		timeout, parseErr := time.ParseDuration(current.ProcessTimeout)
		if parseErr != nil {
			return fmt.Errorf("step %q process_timeout: %w", current.Label, parseErr)
		}
		input := current.Input
		if current.RawInput != nil {
			input = []byte(*current.RawInput)
		}
		args := append([]string{}, baseArgs...)
		args = append(args, "--source", current.Source)
		if current.Event != "" {
			args = append(args, "--event", current.Event)
		}
		result := runChild(context.Background(), childSpec{
			command: command,
			args:    args,
			stdin:   input,
			timeout: timeout,
			environ: environ,
			dir:     ".",
		})
		stepFailed := false
		if result.timedOut != current.Expect.TimedOut {
			fmt.Printf("FAIL %-24s timed_out: expected %t, got %t\n", current.Label, current.Expect.TimedOut, result.timedOut)
			stepFailed = true
		}
		if current.Expect.ExitCode != nil && result.exitCode != *current.Expect.ExitCode {
			fmt.Printf("FAIL %-24s exit_code: expected %d, got %d\n", current.Label, *current.Expect.ExitCode, result.exitCode)
			stepFailed = true
		}
		if result.stdout != current.Expect.Stdout {
			fmt.Printf("FAIL %-24s stdout:\n  expected: %q\n  got:      %q\n", current.Label, current.Expect.Stdout, result.stdout)
			stepFailed = true
		}
		if result.err != nil && !result.timedOut {
			fmt.Printf("FAIL %-24s process error: %v; stderr=%q\n", current.Label, result.err, result.stderr)
			stepFailed = true
		}
		if stepFailed {
			failures++
		} else {
			fmt.Printf("PASS %s\n", current.Label)
		}
	}

	expected := expectedEnvelopes(script)
	actual, reportErr := waitForReport(*reportPath, len(expected), time.Second)
	if reportErr != nil {
		fmt.Printf("FAIL envelopes: %v\n", reportErr)
		failures++
	} else if mismatch := compareEnvelopes(expected, actual); mismatch != "" {
		fmt.Printf("FAIL envelopes: %s\n", mismatch)
		failures++
	} else {
		fmt.Printf("PASS envelopes (%d received)\n", len(actual))
	}

	if failures > 0 {
		return fmt.Errorf("scenario %s failed with %d mismatch(es)", script.Name, failures)
	}
	fmt.Printf("SCENARIO PASS %s\n", script.Name)
	return nil
}

func resolveScenarioPath(value string) string {
	if strings.ContainsRune(value, os.PathSeparator) || strings.HasSuffix(value, ".json") {
		if _, err := os.Stat(value); err == nil {
			return value
		}
	}
	name := value
	if !strings.HasSuffix(name, ".json") {
		name += ".json"
	}
	return filepath.Join("tools", "hook-harness", "scenarios", name)
}

func decodeScenario(reader io.Reader) (scenario, error) {
	decoder := json.NewDecoder(reader)
	decoder.DisallowUnknownFields()
	var value scenario
	if err := decoder.Decode(&value); err != nil {
		return scenario{}, err
	}
	if value.Name == "" || len(value.Steps) == 0 {
		return scenario{}, errors.New("scenario needs a name and at least one step")
	}
	for index, current := range value.Steps {
		if current.Label == "" || current.Source == "" {
			return scenario{}, fmt.Errorf("step %d needs label and source", index+1)
		}
		hasInput := len(current.Input) > 0
		hasRaw := current.RawInput != nil
		if hasInput == hasRaw {
			return scenario{}, fmt.Errorf("step %q needs exactly one of input or raw_input", current.Label)
		}
		if current.ProcessTimeout == "" {
			return scenario{}, fmt.Errorf("step %q needs process_timeout", current.Label)
		}
		duration, err := time.ParseDuration(current.ProcessTimeout)
		if err != nil || duration <= 0 {
			return scenario{}, fmt.Errorf("step %q has invalid process_timeout", current.Label)
		}
		if current.Envelope != nil && current.Envelope.EventName == "" {
			return scenario{}, fmt.Errorf("step %q envelope needs event_name", current.Label)
		}
	}
	return value, nil
}

func isolatedEnvironment(base []string, home, socketPath string) []string {
	blocked := []string{"HOME=", "CODEX_HOME=", "CLAUDE_CONFIG_DIR=", "XDG_CONFIG_HOME=", "THE_NOTCH_SOCKET="}
	result := make([]string, 0, len(base)+5)
	for _, entry := range base {
		skip := false
		for _, prefix := range blocked {
			if strings.HasPrefix(entry, prefix) {
				skip = true
				break
			}
		}
		if !skip {
			result = append(result, entry)
		}
	}
	return append(result,
		"HOME="+home,
		"CODEX_HOME="+filepath.Join(home, ".codex"),
		"CLAUDE_CONFIG_DIR="+filepath.Join(home, ".claude"),
		"XDG_CONFIG_HOME="+filepath.Join(home, ".config"),
		"THE_NOTCH_SOCKET="+socketPath,
	)
}

func runChild(parent context.Context, spec childSpec) childResult {
	ctx, cancel := context.WithTimeout(parent, spec.timeout)
	defer cancel()
	command := exec.Command(spec.command, spec.args...)
	command.Dir = spec.dir
	command.Env = spec.environ
	command.Stdin = bytes.NewReader(spec.stdin)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Start(); err != nil {
		return childResult{exitCode: -1, stdout: stdout.String(), stderr: stderr.String(), err: err}
	}
	waitCh := make(chan error, 1)
	go func() { waitCh <- command.Wait() }()

	var err error
	timedOut := false
	select {
	case err = <-waitCh:
	case <-ctx.Done():
		timedOut = errors.Is(ctx.Err(), context.DeadlineExceeded)
		_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
		select {
		case err = <-waitCh:
		case <-time.After(2 * time.Second):
			err = errors.New("child did not exit after SIGKILL")
		}
	}
	exitCode := -1
	if command.ProcessState != nil {
		exitCode = command.ProcessState.ExitCode()
	}
	return childResult{exitCode: exitCode, timedOut: timedOut, stdout: stdout.String(), stderr: stderr.String(), err: err}
}

func expectedEnvelopes(script scenario) []envelopeExpectation {
	var result []envelopeExpectation
	for _, current := range script.Steps {
		if current.Envelope != nil {
			result = append(result, *current.Envelope)
		}
	}
	return result
}

func waitForReport(path string, minimum int, timeout time.Duration) ([]requestEnvelope, error) {
	deadline := time.Now().Add(timeout)
	for {
		actual, err := readReport(path)
		if err == nil && len(actual) >= minimum {
			time.Sleep(75 * time.Millisecond)
			return readReport(path)
		}
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
		if time.Now().After(deadline) {
			if err != nil {
				return nil, err
			}
			return actual, nil
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func readReport(path string) ([]requestEnvelope, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var result []requestEnvelope
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		if len(bytes.TrimSpace(scanner.Bytes())) == 0 {
			continue
		}
		var request requestEnvelope
		if err := json.Unmarshal(scanner.Bytes(), &request); err != nil {
			return nil, err
		}
		result = append(result, request)
	}
	return result, scanner.Err()
}

func compareEnvelopes(expected []envelopeExpectation, actual []requestEnvelope) string {
	if len(expected) != len(actual) {
		return fmt.Sprintf("expected %d envelope(s), got %d", len(expected), len(actual))
	}
	for index := range expected {
		want, got := expected[index], actual[index]
		if got.EventName != want.EventName || got.Source != want.Source || got.CWD != want.CWD {
			return fmt.Sprintf("envelope %d expected event/source/cwd %q/%q/%q, got %q/%q/%q", index+1, want.EventName, want.Source, want.CWD, got.EventName, got.Source, got.CWD)
		}
		if want.ThreadName != nil && got.ThreadName != *want.ThreadName {
			return fmt.Sprintf("envelope %d expected thread_name %q, got %q", index+1, *want.ThreadName, got.ThreadName)
		}
		if want.Timeout != nil && got.Timeout != *want.Timeout {
			return fmt.Sprintf("envelope %d expected timeout %s, got %s", index+1, strconv.FormatFloat(*want.Timeout, 'f', -1, 64), strconv.FormatFloat(got.Timeout, 'f', -1, 64))
		}
		if len(got.Payload) == 0 || !json.Valid(got.Payload) {
			return fmt.Sprintf("envelope %d has invalid payload", index+1)
		}
	}
	return ""
}
