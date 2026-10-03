"""Platform heartbeat (ADR-0027).

A trivial hourly DAG that proves the whole path works end to end: the DAG
processor parses this folder, the scheduler queues a run, the LocalExecutor
runs the task, and the task reports back through the Execution API. Its
success count (airflow_ti_finish{dag_id="platform_heartbeat"}) drives the
"Airflow heartbeat stale" Grafana alert.

Lives in this repo under dags/platform/, the only DAGs the platform repo
ships; app DAGs are delivered by each app's own deploy into dags/<app>/.
"""

from datetime import datetime, timedelta

from airflow.sdk import dag, task


@dag(
    dag_id="platform_heartbeat",
    schedule="@hourly",
    start_date=datetime(2026, 10, 1),
    catchup=False,
    # Unpaused on first parse: dags_are_paused_at_creation is True for app
    # DAGs, but the heartbeat should start beating without a click.
    is_paused_upon_creation=False,
    max_active_runs=1,
    dagrun_timeout=timedelta(minutes=10),
    default_args={"retries": 1, "retry_delay": timedelta(minutes=2)},
    tags=["platform"],
)
def platform_heartbeat():
    @task
    def beat() -> str:
        return "ok"

    beat()


platform_heartbeat()
