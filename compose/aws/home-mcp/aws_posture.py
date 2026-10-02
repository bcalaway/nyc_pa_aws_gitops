"""aws_posture: AWS account security findings (Milestone 19, ADR-0024).

Read-only, using the hub's instance role through IMDS (the same way
cost-exporter and Traefik get credentials). The role's
home-platform-hub-security-read policy (terraform/aws/tls.tf) allows only
the List/Describe/Get calls below.

Checks:
- GuardDuty: active findings of medium severity or worse (threat detection:
  crypto-mining, credential misuse, unusual API calls, port probing)
- IAM Access Analyzer: resources shared outside the account (S3 buckets,
  roles trusting outside principals, KMS keys, ...)
- Security groups: anything open to the whole internet beyond the expected
  hub ports (80/443 TCP, WireGuard 51820 UDP)
- Root account sign-ins and console sign-ins without MFA (CloudTrail event
  history, free, 90 days)
- IAM users: access keys older than 90 days, console access without MFA
- The hub's IMDS guard (compose/aws/host/imds-guard.sh): whether app
  containers are blocked from the instance role's credentials, from the
  hub_imds_guard_active metric in Prometheus
"""

import asyncio
import datetime
import json
import os
import time
import urllib.parse
import urllib.request

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

REGION = os.environ.get("AWS_REGION", "us-east-1")
# (protocol, port) open to 0.0.0.0/0 on purpose. Overridable without a code change.
EXPECTED_OPEN = {
    (port, proto)
    for proto, _, port in (x.strip().partition("/") for x in os.environ.get("AWS_EXPECTED_OPEN", "tcp/80,tcp/443,udp/51820").split(","))
    if port
}
KEY_MAX_AGE_DAYS = 90
LOOKBACK_DAYS = 7
CFG = Config(region_name=REGION, retries={"max_attempts": 3, "mode": "standard"}, connect_timeout=5, read_timeout=15)


def _client(name: str):
    return boto3.client(name, config=CFG)


def _guardduty() -> tuple[list[str], list[str]]:
    gd = _client("guardduty")
    detectors = gd.list_detectors().get("DetectorIds", [])
    if not detectors:
        return [], ["GuardDuty isn't enabled"]
    det = detectors[0]
    ids = gd.list_findings(
        DetectorId=det,
        FindingCriteria={"Criterion": {"service.archived": {"Eq": ["false"]}, "severity": {"Gte": 4}}},
        MaxResults=50,
    ).get("FindingIds", [])
    if not ids:
        return [], []
    findings = gd.get_findings(DetectorId=det, FindingIds=ids).get("Findings", [])
    findings.sort(key=lambda f: -f.get("Severity", 0))
    lines = []
    for f in findings[:5]:
        sev = f.get("Severity", 0)
        level = "high" if sev >= 7 else "medium"
        lines.append(f"GuardDuty {level}: {f.get('Title', f.get('Type', 'finding'))}")
    if len(findings) > 5:
        lines.append(f"... and {len(findings) - 5} more GuardDuty findings")
    return lines, []


def _access_analyzer() -> tuple[list[str], list[str]]:
    aa = _client("accessanalyzer")
    analyzers = [a for a in aa.list_analyzers(type="ACCOUNT").get("analyzers", []) if a.get("status") == "ACTIVE"]
    if not analyzers:
        return [], ["IAM Access Analyzer isn't enabled"]
    found = aa.list_findings_v2(
        analyzerArn=analyzers[0]["arn"], filter={"status": {"eq": ["ACTIVE"]}}, maxResults=50
    ).get("findings", [])
    lines = []
    for f in found[:5]:
        res = f.get("resource", "").split(":::")[-1].split("/")[-1] or f.get("resourceType", "resource")
        lines.append(f"Access Analyzer: {f.get('resourceType', 'resource')} {res} is accessible from outside the account")
    if len(found) > 5:
        lines.append(f"... and {len(found) - 5} more Access Analyzer findings")
    return lines, []


def _security_groups() -> tuple[list[str], list[str]]:
    ec2 = _client("ec2")
    lines = []
    for page in ec2.get_paginator("describe_security_groups").paginate():
        for sg in page["SecurityGroups"]:
            for perm in sg.get("IpPermissions", []):
                world = any(r.get("CidrIp") == "0.0.0.0/0" for r in perm.get("IpRanges", [])) or any(
                    r.get("CidrIpv6") == "::/0" for r in perm.get("Ipv6Ranges", [])
                )
                if not world:
                    continue
                proto = perm.get("IpProtocol", "-1")
                lo, hi = perm.get("FromPort"), perm.get("ToPort")
                if proto == "-1" or lo is None:
                    lines.append(f"Security group {sg.get('GroupName')}: ALL traffic open to the internet")
                    continue
                for port in range(lo, min(hi, lo + 64) + 1):
                    if (str(port), proto) not in EXPECTED_OPEN:
                        span = f"{lo}-{hi}" if hi != lo else str(lo)
                        lines.append(f"Security group {sg.get('GroupName')}: {proto}/{span} open to the internet")
                        break
    return lines, []


def _root_and_console() -> tuple[list[str], list[str]]:
    ct = _client("cloudtrail")
    start = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=LOOKBACK_DAYS)
    lines = []
    root, no_mfa = 0, []
    for page in ct.get_paginator("lookup_events").paginate(
        LookupAttributes=[{"AttributeKey": "EventName", "AttributeValue": "ConsoleLogin"}],
        StartTime=start,
        PaginationConfig={"MaxItems": 200},
    ):
        for ev in page.get("Events", []):
            detail = json.loads(ev.get("CloudTrailEvent", "{}"))
            who = detail.get("userIdentity", {})
            if who.get("type") == "Root":
                root += 1
            mfa = detail.get("additionalEventData", {}).get("MFAUsed")
            ok = detail.get("responseElements", {}).get("ConsoleLogin") == "Success"
            if ok and mfa == "No" and who.get("type") != "AssumedRole":
                no_mfa.append(who.get("userName") or who.get("type", "?"))
    if root:
        lines.append(f"The root account signed in {root} time{'s' if root != 1 else ''} in the last {LOOKBACK_DAYS} days")
    if no_mfa:
        lines.append("Console sign-ins without MFA: " + ", ".join(sorted(set(no_mfa))))
    return lines, []


def _iam_users() -> tuple[list[str], list[str]]:
    iam = _client("iam")
    lines = []
    now = datetime.datetime.now(datetime.timezone.utc)
    for page in iam.get_paginator("list_users").paginate():
        for u in page["Users"]:
            name = u["UserName"]
            for k in iam.list_access_keys(UserName=name).get("AccessKeyMetadata", []):
                age = (now - k["CreateDate"]).days
                if k.get("Status") == "Active" and age > KEY_MAX_AGE_DAYS:
                    lines.append(f"IAM user {name}: access key is {age} days old; rotate it")
            try:
                iam.get_login_profile(UserName=name)
                has_console = True
            except ClientError as exc:
                if exc.response.get("Error", {}).get("Code") != "NoSuchEntity":
                    raise
                has_console = False
            if has_console and not iam.list_mfa_devices(UserName=name).get("MFADevices"):
                lines.append(f"IAM user {name}: console access without MFA")
    return lines, []


PROMETHEUS_URL = os.environ.get("PROMETHEUS_URL", "http://prometheus:9090")
GUARD_STALE_SECONDS = 3 * 3600


def _imds_guard() -> tuple[list[str], list[str]]:
    """App containers must not reach the hub role's credentials (ADR-0024)."""

    def q(expr: str) -> list[dict]:
        url = f"{PROMETHEUS_URL}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
        with urllib.request.urlopen(url, timeout=5) as r:
            return json.load(r)["data"]["result"]

    active = q('hub_imds_guard_active{instance="aws-hub"}')
    last = q('hub_imds_guard_last_run_timestamp_seconds{instance="aws-hub"}')
    if not active:
        return ["IMDS guard isn't reporting: app containers may be able to read the hub role's credentials"], []
    lines = []
    if active[0]["value"][1] != "1":
        lines.append(
            "IMDS guard is off or rolled back: app containers can read the hub role's credentials "
            "(journalctl -u imds-guard on the hub says why)"
        )
    if last and time.time() - float(last[0]["value"][1]) > GUARD_STALE_SECONDS:
        lines.append("IMDS guard hasn't run for over 3 hours (it should run hourly)")
    return lines, []


CHECKS = {
    "GuardDuty": _guardduty,
    "Access Analyzer": _access_analyzer,
    "security groups": _security_groups,
    "sign-in history": _root_and_console,
    "IAM users": _iam_users,
    "IMDS guard": _imds_guard,
}


async def aws_posture() -> str:
    names = list(CHECKS)
    results = await asyncio.gather(*(asyncio.to_thread(CHECKS[n]) for n in names), return_exceptions=True)
    findings, notes, couldnt = [], [], []
    for name, res in zip(names, results):
        if isinstance(res, (ClientError, BotoCoreError)):
            code = getattr(res, "response", {}).get("Error", {}).get("Code", type(res).__name__)
            couldnt.append(f"{name} ({code})")
        elif isinstance(res, Exception):
            couldnt.append(f"{name} ({type(res).__name__})")
        else:
            findings += res[0]
            notes += res[1]
    if findings:
        head = f"{len(findings)} AWS finding{'s' if len(findings) != 1 else ''}: " + "; ".join(findings) + "."
    else:
        head = (
            "AWS looks clean: no GuardDuty or Access Analyzer findings, nothing unexpected open to the internet, "
            "no root or no-MFA sign-ins this week, and app containers are blocked from the hub's credentials."
        )
    lines = [head]
    if notes:
        lines.append("Note: " + "; ".join(notes) + ".")
    if couldnt:
        lines.append("Couldn't check: " + "; ".join(couldnt) + ".")
    return "\n".join(lines)
