package main

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"io"
	"net"
	"os"
	"strings"
	"time"
	"unicode"
)

const (
	defaultSocketPath = "/tmp/the-notch.sock"
	defaultEventTTL   = 5
	permissionTTL     = 7200
	maxPayloadBytes   = 16 << 20
)

// The events the client will forward. An event that is not here is dropped silently and the
// hook still exits 0 — the client fails open by construction.
//
// SubagentStart, PostToolUseFailure, PreCompact and PostCompact joined the set when the app
// started drawing subagents as rows and distinguishing a compacting session from a working
// one: the installer had begun subscribing to them, and without them here the client would
// have thrown every one of those events away at the front door.
var supportedEvents = map[string]bool{
	"SessionStart": true, "SessionEnd": true, "UserPromptSubmit": true,
	"PreToolUse": true, "PostToolUse": true, "PostToolUseFailure": true,
	"Notification": true, "Stop": true,
	"SubagentStart": true, "SubagentStop": true,
	"PreCompact": true, "PostCompact": true,
	"PermissionRequest": true, "AgentThought": true, "Elicitation": true, "PermissionDenied": true,
}

type envelope struct {
	ID         string          `json:"id"`
	EventName  string          `json:"event_name"`
	Source     string          `json:"source"`
	CWD        string          `json:"cwd"`
	ThreadName string          `json:"thread_name,omitempty"`
	Timeout    int             `json:"timeout"`
	Payload    json.RawMessage `json:"payload"`
}

type serverResponse struct {
	ID       string `json:"id"`
	Decision string `json:"decision"`
	Reason   string `json:"reason,omitempty"`
	// UpdatedInput carries the tool call to run in place of the proposed one. The notch sets
	// it when the user answered a question in the panel rather than merely allowing the call:
	// the answer belongs in the tool's own input, not in a prose reason the CLI may drop.
	UpdatedInput json.RawMessage `json:"updated_input,omitempty"`
}

type cliResponse struct {
	PermissionDecision       string          `json:"permissionDecision"`
	PermissionDecisionReason string          `json:"permissionDecisionReason,omitempty"`
	UpdatedInput             json.RawMessage `json:"updatedInput,omitempty"`
}

type codexCLIResponse struct {
	HookSpecificOutput codexHookSpecificOutput `json:"hookSpecificOutput"`
}

type codexHookSpecificOutput struct {
	HookEventName string                  `json:"hookEventName"`
	Decision      codexPermissionDecision `json:"decision"`
}

type codexPermissionDecision struct {
	Behavior string `json:"behavior"`
	Message  string `json:"message,omitempty"`
}

func main() {
	run(os.Args[1:], os.Stdin, os.Stdout)
}

func run(arguments []string, stdin io.Reader, stdout io.Writer) {
	runWithDial(arguments, stdin, stdout, net.DialTimeout)
}

func runWithDial(
	arguments []string,
	stdin io.Reader,
	stdout io.Writer,
	dial func(string, string, time.Duration) (net.Conn, error),
) {
	flags := flag.NewFlagSet("notch-hook", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	source := flags.String("source", "", "agent CLI source")
	eventFlag := flags.String("event", "", "hook event name")
	sessionFlag := flags.String("session", "", "stable session ID for custom integrations")
	cwdFlag := flags.String("cwd", "", "workspace directory")
	observe := flags.Bool("observe", false, "report permission attention without waiting for a decision")
	if flags.Parse(arguments) != nil || *source == "" {
		return
	}

	payload, err := readPayload(stdin)
	if err == nil && len(strings.TrimSpace(string(payload))) == 0 && *eventFlag != "" && *sessionFlag != "" {
		payload = []byte("{}")
	}
	if err != nil || !json.Valid(payload) {
		return
	}

	fields := payloadFields(payload)
	eventName := *eventFlag
	if eventName == "" {
		eventName = firstString(fields, "hook_event_name", "hookEventName", "event", "trigger")
	}
	eventName = normalizeEvent(eventName)
	if eventName == "" || fields == nil || (!supportedEvents[eventName] && *eventFlag == "") {
        return
    }
	// Other providers have different approval contracts. Telemetry must never grant a tool
	// permission or hold the provider open waiting for an unsupported reply format.
	if eventName == "PermissionRequest" && (*observe || (*source != "codex" && *source != "claude")) {
		eventName = "Elicitation"
	}
	normalizePayload(fields)
	payload, err = json.Marshal(fields)
	if err != nil {
		return
	}

	timeout := defaultEventTTL
	if eventName == "PermissionRequest" {
		timeout = permissionTTL
	}

	cwd := *cwdFlag
	if cwd == "" {
		cwd = firstString(fields, "cwd", "workspace_current_dir", "current_dir")
	}
	if cwd == "" {
		for _, key := range []string{"workspacePaths", "workspace_roots"} {
			var paths []string
			if json.Unmarshal(fields[key], &paths) == nil && len(paths) > 0 {
				cwd = paths[0]
				break
			}
		}
	}
	if cwd == "" {
		cwd, _ = os.Getwd()
	}
	id, err := newUUID()
	if err != nil {
		return
	}
	session := *sessionFlag
	if session == "" {
		session = firstString(fields, "thread_name", "session_id", "sessionId", "sessionID", "conversation_id", "conversationId", "thread_id")
	}
	message, err := json.Marshal(envelope{
		ID: id, EventName: eventName, Source: *source, CWD: cwd,
		ThreadName: session,
		Timeout:    timeout, Payload: payload,
	})
	if err != nil {
		return
	}
	message = append(message, '\n')

	socketPath := os.Getenv("THE_NOTCH_SOCKET")
	if socketPath == "" {
		socketPath = defaultSocketPath
	}
	connection, err := dial("unix", socketPath, 250*time.Millisecond)
	if err != nil {
		return
	}
	defer connection.Close()
	_ = connection.SetWriteDeadline(time.Now().Add(500 * time.Millisecond))
	if _, err = connection.Write(message); err != nil || eventName != "PermissionRequest" {
		return
	}

	_ = connection.SetReadDeadline(time.Now().Add(time.Duration(timeout) * time.Second))
	line, err := bufio.NewReader(io.LimitReader(connection, 64<<10)).ReadBytes('\n')
	if err != nil {
		return
	}
	var response serverResponse
	if json.Unmarshal(line, &response) != nil || response.ID != id {
		return
	}

	decision := ""
	switch response.Decision {
	case "allow", "allow_always":
		decision = "allow"
	case "deny":
		decision = "deny"
	case "defer":
		return
	default:
		return
	}
	var encoded []byte
	if *source == "codex" {
		encoded, err = json.Marshal(codexCLIResponse{
			HookSpecificOutput: codexHookSpecificOutput{
				HookEventName: "PermissionRequest",
				Decision: codexPermissionDecision{
					Behavior: decision,
					Message:  response.Reason,
				},
			},
		})
	} else {
		// Codex's schema rejects unknown keys, so an answered input is only ever offered on
		// the Claude/default shape. `updatedInput` is the field the CLI documents for a hook
		// that supplies what an interactive prompt would have collected; a CLI that does not
		// understand it still sees a plain allow and prompts as it always did.
		encoded, err = json.Marshal(cliResponse{
			PermissionDecision:       decision,
			PermissionDecisionReason: response.Reason,
			UpdatedInput:             validJSONObject(response.UpdatedInput),
		})
	}
	if err == nil {
		_, _ = stdout.Write(append(encoded, '\n'))
	}
}

func readPayload(reader io.Reader) ([]byte, error) {
	type result struct {
		payload []byte
		err     error
	}
	resultChannel := make(chan result, 1)
	go func() {
		payload, err := io.ReadAll(io.LimitReader(reader, maxPayloadBytes+1))
		if len(payload) > maxPayloadBytes && err == nil {
			err = io.ErrShortBuffer
		}
		resultChannel <- result{payload: payload, err: err}
	}()
	select {
	case value := <-resultChannel:
		return value.payload, value.err
	case <-time.After(time.Second):
		return nil, os.ErrDeadlineExceeded
	}
}

func payloadFields(payload []byte) map[string]json.RawMessage {
	var fields map[string]json.RawMessage
	if json.Unmarshal(payload, &fields) != nil {
		return nil
	}
	return fields
}

func firstString(fields map[string]json.RawMessage, keys ...string) string {
	for _, key := range keys {
		var value string
		if json.Unmarshal(fields[key], &value) == nil && value != "" {
			return value
		}
	}
	return ""
}

func newUUID() (string, error) {
	bytes := make([]byte, 16)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	encoded := hex.EncodeToString(bytes)
	return strings.Join([]string{encoded[0:8], encoded[8:12], encoded[12:16], encoded[16:20], encoded[20:32]}, "-"), nil
}

// validJSONObject returns the value only when it is a well-formed JSON object, so a malformed
// or unexpected server reply degrades to a plain decision instead of emitting invalid hook
// output — which the CLI would reject wholesale, taking the decision down with it.
func validJSONObject(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 {
		return nil
	}
	var probe map[string]any
	if json.Unmarshal(raw, &probe) != nil {
		return nil
	}
	return raw
}

// Unknown events retain their spelling and are inert in the app, so custom adapters and
// new provider versions do not require rebuilding the bridge just to send telemetry.
func normalizeEvent(event string) string {
	key := strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			return unicode.ToLower(r)
		}
		return -1
	}, event)
	aliases := map[string]string{
		"agentspawn": "SessionStart", "promptsubmit": "UserPromptSubmit", "beforeagent": "UserPromptSubmit",
		"beforesubmitprompt": "UserPromptSubmit", "userpromptexpansion": "UserPromptSubmit",
		"beforetool": "PreToolUse", "beforetooluse": "PreToolUse", "beforeshellexecution": "PreToolUse", "beforemcpexecution": "PreToolUse",
		"aftertool": "PostToolUse", "aftertooluse": "PostToolUse", "aftershellexecution": "PostToolUse", "aftermcpexecution": "PostToolUse", "afterfileedit": "PostToolUse",
		"afteragent": "Stop", "afteragentresponse": "Stop", "stopfailure": "Stop", "interrupt": "Stop",
		"precompress": "PreCompact", "preinvocation": "AgentThought", "postinvocation": "PostToolUse",
		"afteragentthought": "AgentThought", "attentionrequired": "Elicitation",
	}
	if value, ok := aliases[key]; ok {
		return value
	}
	for value := range supportedEvents {
		if strings.ToLower(value) == key {
			return value
		}
	}
	return event
}

func normalizePayload(fields map[string]json.RawMessage) {
	for target, aliases := range map[string][]string{
		"transcript_path": {"transcriptPath"}, "tool_name": {"toolName"}, "tool_input": {"toolInput"},
	} {
		if _, ok := fields[target]; ok {
			continue
		}
		for _, alias := range aliases {
			if value, ok := fields[alias]; ok {
				fields[target] = value
				break
			}
		}
	}
	var tool map[string]json.RawMessage
	if json.Unmarshal(fields["toolCall"], &tool) == nil {
		if v, ok := tool["name"]; ok {
			fields["tool_name"] = v
		}
		if v, ok := tool["args"]; ok {
			fields["tool_input"] = v
		}
	}
}
