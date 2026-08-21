import logging
import os
import time
from datetime import date, timedelta

import boto3
from prometheus_client import Gauge, start_http_server

POLL_INTERVAL_SECONDS = int(os.environ.get("POLL_INTERVAL_SECONDS", "21600"))

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("cost-exporter")

# Cost Explorer is a global API but only reachable via the us-east-1 endpoint.
ce = boto3.client("ce", region_name="us-east-1")

g_yesterday_total = Gauge(
    "aws_cost_yesterday_usd", "Total unblended AWS cost for the most recent complete day"
)
g_by_service = Gauge(
    "aws_cost_by_service_usd", "Yesterday's unblended AWS cost by service", ["service"]
)
g_mtd_total = Gauge("aws_cost_month_to_date_usd", "Unblended AWS cost so far this month")
g_forecast_total = Gauge(
    "aws_cost_forecast_month_usd", "Forecasted total unblended AWS cost for the current month"
)
# Net cost (aws_cost_month_to_date_usd) alone hid a real signal: confirmed
# 2026-08-21 that this account is drawing down an AWS credit balance that's
# been offsetting real usage almost dollar-for-dollar, service by service
# (Cost Explorer attributes each credit to the specific service it applies
# against, so a per-SERVICE breakdown shows every line item as ~$0 even
# though real usage -- and real gross cost -- is accruing underneath). Split
# out via RECORD_TYPE so the credit being drawn down is actually visible
# before it runs out and net cost jumps with no warning.
g_mtd_gross_usage = Gauge(
    "aws_cost_month_to_date_gross_usage_usd", "Month-to-date gross usage cost, before credits"
)
g_mtd_credits = Gauge(
    "aws_cost_month_to_date_credits_usd",
    "Month-to-date credits applied (negative -- reduces cost, per AWS's own sign convention)",
)
g_last_success = Gauge(
    "aws_cost_exporter_last_success_timestamp_seconds", "Unix timestamp of the last successful poll"
)


def _first_of_next_month(d: date) -> date:
    return (d.replace(day=28) + timedelta(days=4)).replace(day=1)


def poll():
    today = date.today()
    yesterday = today - timedelta(days=1)
    first_of_month = today.replace(day=1)

    # Yesterday's cost, broken down by service.
    resp = ce.get_cost_and_usage(
        TimePeriod={"Start": yesterday.isoformat(), "End": today.isoformat()},
        Granularity="DAILY",
        Metrics=["UnblendedCost"],
        GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
    )
    day_total = 0.0
    seen_services = 0
    if resp["ResultsByTime"]:
        for group in resp["ResultsByTime"][0]["Groups"]:
            service = group["Keys"][0]
            amount = float(group["Metrics"]["UnblendedCost"]["Amount"])
            g_by_service.labels(service=service).set(amount)
            day_total += amount
            seen_services += 1
    g_yesterday_total.set(day_total)

    # Month-to-date total. CE rejects Start == End, which happens on the 1st
    # of the month since "today" hasn't happened yet -- widen the window by
    # a day in that case.
    mtd_end = today if today > first_of_month else first_of_month + timedelta(days=1)
    resp = ce.get_cost_and_usage(
        TimePeriod={"Start": first_of_month.isoformat(), "End": mtd_end.isoformat()},
        Granularity="MONTHLY",
        Metrics=["UnblendedCost"],
    )
    mtd_total = 0.0
    if resp["ResultsByTime"]:
        mtd_total = float(resp["ResultsByTime"][0]["Total"]["UnblendedCost"]["Amount"])
    g_mtd_total.set(mtd_total)

    # Same MTD window, broken down by RECORD_TYPE instead of SERVICE, to
    # recover the gross-usage/credit split that the net total and the
    # per-service breakdown above both hide. Only "Usage" and "Credit" are
    # populated for this account as of 2026-08-21 -- other RECORD_TYPE
    # values (Tax, Refund, RIFee, etc.) exist in AWS's model but aren't
    # mapped here since this account has never shown them; a real value
    # under one just wouldn't show up as gross usage or credits yet.
    resp = ce.get_cost_and_usage(
        TimePeriod={"Start": first_of_month.isoformat(), "End": mtd_end.isoformat()},
        Granularity="MONTHLY",
        Metrics=["UnblendedCost"],
        GroupBy=[{"Type": "DIMENSION", "Key": "RECORD_TYPE"}],
    )
    gross_usage = 0.0
    credits_applied = 0.0
    if resp["ResultsByTime"]:
        for group in resp["ResultsByTime"][0]["Groups"]:
            record_type = group["Keys"][0]
            amount = float(group["Metrics"]["UnblendedCost"]["Amount"])
            if record_type == "Usage":
                gross_usage = amount
            elif record_type == "Credit":
                credits_applied = amount
    g_mtd_gross_usage.set(gross_usage)
    g_mtd_credits.set(credits_applied)

    # Forecast for the rest of the month, added to what's already been spent.
    # Needs a few weeks of billing history to work -- skip quietly until then.
    try:
        next_month = _first_of_next_month(today)
        forecast = ce.get_cost_forecast(
            TimePeriod={"Start": today.isoformat(), "End": next_month.isoformat()},
            Metric="UNBLENDED_COST",
            Granularity="MONTHLY",
        )
        remaining = float(forecast["Total"]["Amount"])
        g_forecast_total.set(mtd_total + remaining)
    except Exception as e:
        log.warning("cost forecast unavailable (often needs more billing history): %s", e)

    g_last_success.set(time.time())
    log.info(
        "poll ok: yesterday=$%.2f mtd=$%.2f (gross=$%.2f credits=$%.2f) services=%d",
        day_total, mtd_total, gross_usage, credits_applied, seen_services,
    )


def main():
    start_http_server(9199)
    log.info("cost-exporter listening on :9199, polling every %ds", POLL_INTERVAL_SECONDS)
    while True:
        try:
            poll()
        except Exception:
            log.exception("poll failed, will retry next interval")
        time.sleep(POLL_INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
