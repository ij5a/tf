# Covers the state wording that the vendored upstream tests did not include.
import sys
import types

b = types.ModuleType("boto3")
b.client = lambda *a, **k: None
sys.modules["boto3"] = b

from notify_slack import format_cloudwatch_alarm

for new_state, old_state, fallback, description, color in [
    ("ALARM", "OK", "Alarm disk-space triggered", "Disk space is low", "danger"),
    ("ALARM", "INSUFFICIENT_DATA", "Alarm disk-space triggered", "Disk space is low", "danger"),
    ("OK", "ALARM", "Alarm disk-space cleared", "The alert has cleared. It was: Disk space is low", "good"),
    ("OK", "INSUFFICIENT_DATA", "Alarm disk-space is now OK", "Disk space is low", "good"),
]:
    alarm = format_cloudwatch_alarm({
        "AlarmName": "disk-space",
        "NewStateValue": new_state,
        "OldStateValue": old_state,
        "AlarmDescription": "Disk space is low",
    }, "us-east-1")
    for label, got, expected in [
        ("fallback", alarm["fallback"], fallback),
        ("description", alarm["fields"][1]["value"], f"`{description}`"),
        ("color", alarm["color"], color),
        ("Alarm reason field", any(field["title"] == "Alarm reason" for field in alarm["fields"]), False),
    ]:
        if got != expected:
            raise SystemExit(f"FAIL {old_state}->{new_state} {label}: got {got!r}, want {expected!r}")

print("PASS")
