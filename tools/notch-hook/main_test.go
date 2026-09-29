package main

import (
    "bufio"
    "bytes"
    "encoding/json"
    "net"
    "strings"
    "testing"
    "time"
)

func capture(t *testing.T, args []string, payload string) envelope {
    t.Helper()
    client, server := net.Pipe()
    defer server.Close()
    received := make(chan envelope, 1)
    go func() {
        _ = server.SetReadDeadline(time.Now().Add(time.Second))
        line, _ := bufio.NewReader(server).ReadBytes('\n')
        var event envelope
        _ = json.Unmarshal(line, &event)
        received <- event
    }()
    var out bytes.Buffer
    runWithDial(args, strings.NewReader(payload), &out, func(string, string, time.Duration) (net.Conn, error) { return client, nil })
    if out.Len() != 0 { t.Fatalf("telemetry emitted control output: %s", out.String()) }
    e := <-received
    if e.ID == "" { t.Fatal("no envelope received") }
    return e
}

func TestProviderEvents(t *testing.T) {
    cases := []struct{ source, event, canonical string }{
        {"cursor", "beforeSubmitPrompt", "UserPromptSubmit"},
        {"cursor", "afterAgentThought", "AgentThought"},
        {"gemini", "BeforeTool", "PreToolUse"},
        {"gemini", "AfterAgent", "Stop"},
        {"kiro", "AgentSpawn", "SessionStart"},
        {"kiro", "PromptSubmit", "UserPromptSubmit"},
        {"antigravity", "PreInvocation", "AgentThought"},
        {"codex", "Interrupt", "Stop"},
        {"my-new-agent", "pre_tool_use", "PreToolUse"},
        {"my-new-agent", "FutureEvent", "FutureEvent"},
        {"opencode", "AttentionRequired", "Elicitation"},
        {"my-new-agent", "PermissionRequest", "Elicitation"},
    }
    for _, c := range cases { t.Run(c.source+"/"+c.event, func(t *testing.T) {
        e := capture(t, []string{"--source",c.source,"--event",c.event}, `{"session_id":"one","cwd":"/workspace"}`)
        if e.EventName != c.canonical || e.Source != c.source || e.ThreadName != "one" { t.Fatalf("unexpected envelope: %+v",e) }
    }) }
}

func TestAntigravityPayload(t *testing.T) {
    e := capture(t, []string{"--source","antigravity","--event","PreToolUse"}, `{"conversationId":"ag-1","workspacePaths":["/project"],"transcriptPath":"/log.jsonl","toolCall":{"name":"run_command","args":{"CommandLine":"pwd"}}}`)
    fields := payloadFields(e.Payload)
    if e.ThreadName != "ag-1" || e.CWD != "/project" || firstString(fields,"tool_name") != "run_command" || firstString(fields,"transcript_path") != "/log.jsonl" { t.Fatalf("bad normalization: %+v",e) }
}

func TestCustomBridgeAndObserve(t *testing.T) {
    e := capture(t, []string{"--source","custom","--event","Stop","--session","s1","--cwd","/project"}, "")
    if e.ThreadName != "s1" || e.CWD != "/project" { t.Fatalf("bad flags: %+v",e) }
    e = capture(t, []string{"--source","codex","--event","PermissionRequest","--observe"}, `{"session_id":"s1"}`)
    if e.EventName != "Elicitation" || e.Timeout != defaultEventTTL { t.Fatalf("observe must not block: %+v",e) }
}

func TestMalformedPayloadDoesNotDial(t *testing.T) {
    for _, input := range []string{"null", "[]", "invalid", "42"} {
        runWithDial([]string{"--source","custom","--event","Stop"},strings.NewReader(input), &bytes.Buffer{},func(string,string,time.Duration)(net.Conn,error){ t.Fatalf("dialed for invalid input %s",input);return nil,nil })
    }
}

func decide(t *testing.T, source, reply string) string {
    t.Helper()
    client, server := net.Pipe()
    go func() {
        defer server.Close()
        line, _ := bufio.NewReader(server).ReadBytes('\n')
        var e envelope
        _ = json.Unmarshal(line, &e)
        _, _ = server.Write([]byte(strings.Replace(reply, "ID", e.ID, 1) + "\n"))
    }()
    var out bytes.Buffer
    runWithDial([]string{"--source", source, "--event", "PermissionRequest"}, strings.NewReader(`{"session_id":"s1","tool_name":"AskUserQuestion"}`), &out, func(string, string, time.Duration) (net.Conn, error) { return client, nil })
    return strings.TrimSpace(out.String())
}

func TestPermissionOutputShape(t *testing.T) {
    answered := `{"id":"ID","decision":"allow","reason":"ok","updated_input":{"answers":{"Ship?":"Yes"}}}`
    cases := []struct{ source, reply, want string }{
        {"claude", answered, `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","message":"ok","updatedInput":{"answers":{"Ship?":"Yes"}}}}}`},
        {"codex", answered, `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","message":"ok"}}}`},
        {"claude", `{"id":"ID","decision":"deny","reason":"no","updated_input":{"a":1}}`, `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"no"}}}`},
        {"claude", `{"id":"ID","decision":"allow_always"}`, `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`},
        {"claude", `{"id":"ID","decision":"defer"}`, ``},
        {"claude", `{"id":"other","decision":"allow"}`, ``},
    }
    for _, c := range cases {
        if got := decide(t, c.source, c.reply); got != c.want { t.Errorf("%s %s\n got %s\nwant %s", c.source, c.reply, got, c.want) }
    }
}
