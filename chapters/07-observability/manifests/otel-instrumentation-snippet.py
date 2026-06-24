"""
OpenTelemetry instrumentation additions for account-service/app.py
and transaction-service/app.py.

Add the imports block at the top of app.py (after existing imports).
Add the setup block immediately before `app = Flask(__name__)`.
Add the instrument block immediately after `app = Flask(__name__)`.

Required additions to requirements.txt:
  opentelemetry-sdk>=1.20.0
  opentelemetry-exporter-otlp-proto-grpc>=1.20.0
  opentelemetry-instrumentation-flask>=0.41b0
  opentelemetry-instrumentation-sqlalchemy>=0.41b0
  opentelemetry-instrumentation-requests>=0.41b0   # transaction-service only
"""

# ── ADD TO IMPORTS ────────────────────────────────────────────────────────────
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.resources import Resource, SERVICE_NAME
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
# from opentelemetry.instrumentation.requests import RequestsInstrumentor  # transaction-service only


# ── ADD BEFORE app = Flask(__name__) ─────────────────────────────────────────
SERVICE_NAME_VALUE = os.environ.get("OTEL_SERVICE_NAME", "account-service")
OTEL_ENDPOINT      = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "")

if OTEL_ENDPOINT:
    resource = Resource.create({SERVICE_NAME: SERVICE_NAME_VALUE})
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(
        BatchSpanProcessor(
            OTLPSpanExporter(
                endpoint=OTEL_ENDPOINT,
                insecure=True,    # collector uses plain gRPC inside the cluster
            )
        )
    )
    trace.set_tracer_provider(provider)

tracer = trace.get_tracer(SERVICE_NAME_VALUE)


# ── ADD AFTER app = Flask(__name__) ──────────────────────────────────────────
if OTEL_ENDPOINT:
    FlaskInstrumentor().instrument_app(app)
    SQLAlchemyInstrumentor().instrument()
    # RequestsInstrumentor().instrument()   # add for transaction-service


# ── EXAMPLE: MANUAL SPAN (add inside any route handler) ──────────────────────
# with tracer.start_as_current_span("validate-account-balance") as span:
#     span.set_attribute("account.id", str(account_id))
#     span.set_attribute("account.balance", float(account.balance))
#     # ... business logic here


# ── NEW ENVIRONMENT VARIABLES (add to ConfigMap) ──────────────────────────────
# OTEL_EXPORTER_OTLP_ENDPOINT: http://financeflow-collector:4317
# OTEL_SERVICE_NAME: account-service  (or transaction-service)
# OTEL_PROPAGATORS: tracecontext,baggage
