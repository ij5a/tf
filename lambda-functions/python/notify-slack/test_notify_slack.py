# Covers the local changes that the vendored upstream tests did not include.
import json
import os
import sys
import types

b = types.ModuleType("boto3")
b.client = lambda *a, **k: None
sys.modules["boto3"] = b

from notify_slack import format_cloudwatch_alarm, get_slack_message_payload, parse_notification

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

# Failed sign-ins carry no arn, and many API calls send a null responseElements.
for detail_type, detail, title, text in [
    (
        "AWS Console Sign In via CloudTrail",
        {"eventName": "ConsoleLogin", "awsRegion": "eu-north-1", "eventID": "e1", "sourceIPAddress": "203.0.113.5",
         "userIdentity": {"type": "IAMUser", "principalId": "AIDAEXAMPLE", "userName": "alice"},
         "responseElements": {"ConsoleLogin": "Failure"}},
        "ConsoleLogin Failure", "A console sign-in attempt failed.\nalice from 203.0.113.5 in eu-north-1",
    ),
    (
        "AWS API Call via CloudTrail",
        {"eventName": "AuthorizeSecurityGroupIngress", "awsRegion": "sa-east-1", "eventID": "e2", "sourceIPAddress": "203.0.113.5",
         "userIdentity": {"type": "IAMUser", "arn": "arn:aws:iam::111122223333:user/alice", "userName": "alice"},
         "responseElements": None},
        "AuthorizeSecurityGroupIngress", "A security group was opened to the internet.\nalice from 203.0.113.5 in sa-east-1",
    ),
    (
        "AWS API Call via CloudTrail",
        {"eventName": "CreateUser", "awsRegion": "us-east-1", "eventID": "e3", "errorCode": "AccessDenied", "sourceIPAddress": "203.0.113.5",
         "userIdentity": {"type": "AssumedRole", "arn": "arn:aws:sts::111122223333:assumed-role/Dev/x"}},
        "CreateUser AccessDenied", "A sensitive API call was made.\nassumed-role/Dev/x from 203.0.113.5 in us-east-1",
    ),
    (
        "AWS Console Sign In via CloudTrail",
        {"eventName": "ConsoleLogin", "awsRegion": "us-east-2", "eventID": "e4", "sourceIPAddress": "203.0.113.5",
         "userIdentity": {"type": "Root", "arn": "arn:aws:iam::111122223333:root"},
         "responseElements": {"ConsoleLogin": "Success"}},
        "ConsoleLogin", "The root user was used.\nroot from 203.0.113.5 in us-east-2",
    ),
]:
    card = parse_notification({"detail-type": detail_type, "account": "111122223333", "detail": detail}, None, "us-east-1")
    for label, got, expected in [
        ("title", card["title"], f":rotating_light: {title}"),
        ("text", card["text"], text),
        ("color", card["color"], "danger"),
        ("footer", card["footer"], "AWS CloudTrail"),
        ("no fields", "fields" in card, False),
        ("link", card["title_link"].endswith(f"region={detail['awsRegion']}#/events/{detail['eventID']}"), True),
    ]:
        if got != expected:
            raise SystemExit(f"FAIL {detail['eventName']} {label}: got {got!r}, want {expected!r}")

# Each route sets its own footer, so each route gets a case.
# A null detail-type must still fall through to the default card.
os.environ.update(SLACK_CHANNEL="alerts", SLACK_USERNAME="aws", SLACK_EMOJI=":aws:")
for message, subject, footer in [
    ({"AlarmName": "a", "NewStateValue": "ALARM", "OldStateValue": "OK", "AlarmDescription": "d"}, None, "AWS CloudWatch"),
    ({"detail-type": "GuardDuty Finding", "region": "us-east-1", "detail": {
        "severity": 8, "title": "t", "description": "d", "type": "t", "accountId": "1", "id": "i",
        "service": {"eventFirstSeen": "f", "eventLastSeen": "l", "count": 1}}}, None, "Amazon GuardDuty"),
    ({"detail-type": "GuardDuty Malware Protection Object Scan Result", "region": "us-east-1", "detail": {
        "scanResultDetails": {"scanResultStatus": "NO_THREATS_FOUND"}, "s3ObjectDetails": {"bucketName": "b", "objectKey": "k"}}},
     None, "Amazon GuardDuty"),
    ({"detail-type": "Security Hub Findings - Imported", "region": "us-east-1", "detail": {"findings": [
        {"ProductName": "Other", "Compliance": {"Status": "PASSED"}, "Workflow": {"Status": "NEW"}}]}}, None, "AWS Security Hub"),
    ({"detail-type": "AWS Health Event", "region": "us-east-1", "resources": [], "detail": {
        "eventTypeCategory": "issue", "eventDescription": [{"latestDescription": "d"}]}}, None, "AWS Health"),
    ({"detail-type": "AWS API Call via CloudTrail", "detail": {"eventName": "StopLogging", "awsRegion": "us-east-1"}}, None, "AWS CloudTrail"),
    ("Backup job 1 completed.", "Notification from AWS Backup", "AWS Backup"),
    ({"foo": "bar"}, "Hello", "AWS"),
    ({"detail-type": None}, "Hello", "AWS"),
]:
    body = message if isinstance(message, str) else json.dumps(message)
    card = get_slack_message_payload(message=body, region="us-east-1", subject=subject)["attachments"][0]
    icon = card.get("footer_icon", "").endswith("/aws_logo_smile_1200x630.png")
    if (card.get("footer"), icon) != (footer, True):
        raise SystemExit(f"FAIL footer {footer}: got {card.get('footer')!r}, icon {card.get('footer_icon')!r}")

# AWS rates 9.0-10.0 as Critical; the upstream card called it High.
for score, label in [(8.9, "High"), (9.0, "Critical")]:
    card = parse_notification({"detail-type": "GuardDuty Finding", "region": "us-east-1", "detail": {
        "severity": score, "title": "t", "description": "d", "type": "t", "accountId": "1", "id": "i",
        "service": {"eventFirstSeen": "f", "eventLastSeen": "l", "count": 1}}}, None, "us-east-1")
    severity = {field["title"]: field["value"] for field in card["fields"]}["Severity"]
    if severity != f"`{label}`":
        raise SystemExit(f"FAIL GuardDuty severity {score}: got {severity!r}, want {label!r}")

print("PASS")
