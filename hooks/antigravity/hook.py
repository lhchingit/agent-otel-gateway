#!/usr/bin/env python3
"""Antigravity CLI hook -> OpenTelemetry (spans + counters) for agent-otel-gateway.

Registered per event in ~/.gemini/config/hooks.json; the event name is argv[1]
because Antigravity's hook payloads carry no event-type field. Only passive
events are used: PostToolUse, PostInvocation, Stop.

Portable port of the SigNoz reference hook:
  * no os.fork() -- the parent re-launches itself detached (works on Windows),
    the child does the OTLP export so the agent loop never waits;
  * no `agy -p /usage` quota sampling -- on agy 1.2.7 that command starts a real
    agent turn (tokens + ~30s) instead of printing quota;
  * emits counters the gateway can unify: agy.tool.call.count{tool_name},
    agy.invocation.count{model}, agy.turn.count. Antigravity exposes no
    token/cost data to hooks.

Settings come from ~/.config/agy-otel/env (KEY=VALUE lines); real environment
variables win. Interactive `agy` sessions inherit an arbitrary shell, so the
file is the reliable place for OTEL_EXPORTER_OTLP_ENDPOINT etc.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

PASSIVE_OUTPUT = {"PostToolUse": {}, "PostInvocation": {}, "Stop": {}}
CONFIG_PATH = os.path.expanduser("~/.config/agy-otel/env")
CHILD_FLAG = "--emit-from-file"


def load_config():
    try:
        with open(CONFIG_PATH, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, val = line.split("=", 1)
                os.environ.setdefault(key.strip(), val.strip())
    except FileNotFoundError:
        pass


def emit(event, payload):
    # Imported here: the SDK costs ~200ms to import and only the child needs it.
    import hashlib

    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.metrics import MeterProvider
    from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    from opentelemetry.trace import (NonRecordingSpan, SpanContext, SpanKind,
                                     TraceFlags, set_span_in_context)

    # Each hook run is a fresh process, so every counter is a delta of 1; the
    # gateway's delta_to_cumulative processor sums them into a counter.
    os.environ.setdefault("OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE", "delta")

    conv = payload.get("conversationId") or "unknown"
    model = payload.get("modelName")
    tool = payload.get("toolName") or (payload.get("toolCall") or {}).get("name")
    # Pin service.instance.id: the SDK would otherwise generate a fresh UUID per
    # hook process, turning every event into its own Prometheus series.
    import socket
    resource = Resource.create({
        "service.name": os.environ.get("OTEL_SERVICE_NAME", "antigravity-cli"),
        "service.instance.id": socket.gethostname(),
    })

    # --- span -------------------------------------------------------------
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    tracer = provider.get_tracer("antigravity-cli-hooks")

    # Group a conversation's spans under one trace id derived from conversationId.
    # The root span is never emitted, so Tempo shows a missing-root placeholder.
    digest = hashlib.sha256(conv.encode()).hexdigest()
    ctx = set_span_in_context(NonRecordingSpan(SpanContext(
        trace_id=int(digest[:32], 16),
        span_id=int(digest[32:48], 16),
        is_remote=True,
        trace_flags=TraceFlags(TraceFlags.SAMPLED),
    )))

    if event == "PostToolUse":
        name, op = f"execute_tool {tool or 'unknown'}", "execute_tool"
    elif event == "Stop":
        name, op = "agy stop", "invoke_agent"
    else:
        name, op = "agy invocation", "invoke_agent"

    now_ns = int(time.time() * 1e9)
    span = tracer.start_span(name, context=ctx, kind=SpanKind.INTERNAL, start_time=now_ns)
    span.set_attribute("gen_ai.operation.name", op)
    span.set_attribute("gen_ai.provider.name", "gcp.gemini")
    span.set_attribute("gen_ai.conversation.id", conv)
    span.set_attribute("agy.hook.event", event)
    if model:
        span.set_attribute("gen_ai.request.model", model)
    for key, attr in (("stepIdx", "agy.step.index"),
                      ("invocationNum", "agy.invocation.num"),
                      ("initialNumSteps", "agy.initial_num_steps"),
                      ("executionNum", "agy.execution.num"),
                      ("terminationReason", "agy.termination_reason"),
                      ("fullyIdle", "agy.fully_idle")):
        if payload.get(key) is not None:
            span.set_attribute(attr, payload[key])
    if tool:
        span.set_attribute("gen_ai.tool.name", tool)
    err = payload.get("error")
    if err:
        span.set_attribute("error.type", str(err)[:200])
        span.set_status(trace.Status(trace.StatusCode.ERROR, str(err)[:200]))
    span.end(end_time=now_ns)
    provider.force_flush(2000)
    provider.shutdown()

    # --- counters ---------------------------------------------------------
    mp = MeterProvider(resource=resource, metric_readers=[
        PeriodicExportingMetricReader(OTLPMetricExporter(), export_interval_millis=60000)])
    meter = mp.get_meter("antigravity-cli-hooks")
    attrs = {"session.id": conv}
    if model:
        attrs["model"] = model
    if event == "PostToolUse":
        meter.create_counter("agy.tool.call.count", unit="{call}",
                             description="Tool executions").add(1, {**attrs, "tool_name": tool or "unknown"})
    elif event == "PostInvocation":
        meter.create_counter("agy.invocation.count", unit="{invocation}",
                             description="Agent loop invocations").add(1, attrs)
    elif event == "Stop":
        meter.create_counter("agy.turn.count", unit="{turn}",
                             description="Completed turns").add(1, attrs)
    mp.force_flush(5000)
    mp.shutdown()


def spawn_detached(event, payload):
    """Re-run this script detached so the hook returns immediately."""
    fd, path = tempfile.mkstemp(prefix="agy-otel-", suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(payload, fh)
    args = [sys.executable, os.path.abspath(__file__), event, CHILD_FLAG, path]
    kwargs = dict(stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                  stderr=subprocess.DEVNULL, close_fds=True)
    if os.name == "nt":
        kwargs["creationflags"] = (subprocess.DETACHED_PROCESS
                                   | subprocess.CREATE_NEW_PROCESS_GROUP
                                   | getattr(subprocess, "CREATE_NO_WINDOW", 0))
    else:
        kwargs["start_new_session"] = True
    subprocess.Popen(args, **kwargs)


def main():
    load_config()
    event = sys.argv[1] if len(sys.argv) > 1 else "PostInvocation"

    if len(sys.argv) > 3 and sys.argv[2] == CHILD_FLAG:
        path = sys.argv[3]
        try:
            with open(path, encoding="utf-8") as fh:
                payload = json.load(fh)
        except Exception:
            payload = {}
        finally:
            try:
                os.remove(path)
            except OSError:
                pass
        try:
            emit(event, payload)
        except Exception:
            pass  # telemetry must never surface as an agent error
        return

    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        payload = {}
    try:
        spawn_detached(event, payload)
    except Exception:
        pass  # never break the agent loop on a telemetry failure
    # Passive response: valid JSON that does not alter agent behaviour.
    print(json.dumps(PASSIVE_OUTPUT.get(event, {})))


if __name__ == "__main__":
    main()
