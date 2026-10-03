"""Calling an app's job API from a DAG (ADR-0031).

App DAGs don't run app code: each task asks the app to do the work, over
HTTP on the home-platform network, and gets a JSON summary back. This module
is the one way to make that call, so token handling, timeouts and error
reporting are the same for every app.

Installed at the DAG root by the hub deploy (scripts/hub/deploy-hub-stack.sh)
and listed in .airflowignore, so it's importable but never parsed as a DAG:

    from home_platform_jobs import call_app_job

    @task
    def capture():
        return call_app_job("mkt-data", "calendars/sifma/capture")

The app's URL and token come from the AIRFLOW_CONN_<APP> environment
variable that the hub deploy writes for every registry app with
airflow: true (http://:<token>@<app>:8000). Read straight from the
environment rather than through Airflow's connection API, so this module
depends only on the standard library and works the same in any Airflow 3
task process. Standard library only, on purpose: it runs inside Airflow.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request

# Long enough for any synchronous job; longer work uses start-then-poll
# (ADR-0031) so a task never holds one of the hub's 4 slots this long.
DEFAULT_TIMEOUT_SECONDS = 300


class AppJobError(RuntimeError):
    """The app answered with an error, or couldn't be reached. Airflow retries."""


def _app_endpoint(app: str) -> tuple[str, str]:
    var = "AIRFLOW_CONN_" + app.upper().replace("-", "_")
    uri = os.environ.get(var)
    if not uri:
        raise AppJobError(
            f"{var} isn't set: is {app} in apps/registry.yml with airflow: true, "
            "and has a hub deploy run since?"
        )
    u = urllib.parse.urlsplit(uri)
    if not u.hostname or not u.password:
        raise AppJobError(f"{var} has no host or token")
    base = f"http://{u.hostname}:{u.port or 8000}"
    return base, urllib.parse.unquote(u.password)


def call_app_job(
    app: str,
    job: str,
    params: dict | None = None,
    *,
    method: str = "POST",
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
) -> dict:
    """Run <app>'s /jobs/<job> and return its JSON summary.

    params are sent as a JSON body (POST) or a query string (GET). Any
    non-2xx answer raises AppJobError with the app's own error text, so
    the Airflow task fails, retries, and shows why.
    """
    base, token = _app_endpoint(app)
    url = f"{base}/jobs/{job.lstrip('/')}"
    data = None
    if method == "GET":
        if params:
            url += "?" + urllib.parse.urlencode(params)
    else:
        data = json.dumps(params or {}).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode() or "{}"
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:2000]
        raise AppJobError(f"{app} {method} /jobs/{job}: HTTP {e.code}: {detail}") from None
    except (urllib.error.URLError, TimeoutError) as e:
        raise AppJobError(f"{app} {method} /jobs/{job}: {e}") from None
    summary = json.loads(body)
    print(f"{app} /jobs/{job}: {json.dumps(summary)[:2000]}")
    return summary
