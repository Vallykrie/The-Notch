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
