import os
import uuid
import logging
from datetime import datetime, timezone
from urllib.parse import quote_plus

from flask import Flask, jsonify, request, abort
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy import text
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST

from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.resources import Resource, SERVICE_NAME
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(name)s %(message)s')
log = logging.getLogger(__name__)

# ─── OpenTelemetry Tracing ──────────────────────────────────────────────────────

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

app = Flask(__name__)

if OTEL_ENDPOINT:
    FlaskInstrumentor().instrument_app(app)
    SQLAlchemyInstrumentor().instrument()

# ─── Database ─────────────────────────────────────────────────────────────────

DB_HOST = os.environ.get("DB_HOST", "postgres")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ.get("DB_NAME", "financeflow")
DB_USER = os.environ["DB_USER"]
DB_PASS = os.environ["DB_PASSWORD"]

app.config["SQLALCHEMY_DATABASE_URI"] = (
    f"postgresql://{quote_plus(DB_USER)}:{quote_plus(DB_PASS)}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
)
app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False

db = SQLAlchemy(app)

# ─── Prometheus Metrics ───────────────────────────────────────────────────────

REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status"],
)
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency",
    ["endpoint"],
)
ACCOUNT_BALANCE = Gauge(
    "account_balance_dollars",
    "Current account balance in USD",
    ["account_id", "account_type"],
)

# ─── Model ────────────────────────────────────────────────────────────────────

class Account(db.Model):
    __tablename__ = "accounts"

    id             = db.Column(db.String(36),    primary_key=True, default=lambda: str(uuid.uuid4()))
    owner_name     = db.Column(db.String(255),   nullable=False)
    email          = db.Column(db.String(255),   unique=True, nullable=False)
    account_number = db.Column(db.String(20),    unique=True, nullable=False)
    account_type   = db.Column(db.String(20),    nullable=False, default="checking")
    balance        = db.Column(db.Numeric(15, 2), nullable=False, default=0.00)
    currency       = db.Column(db.String(3),     nullable=False, default="USD")
    status         = db.Column(db.String(20),    nullable=False, default="active")
    created_at     = db.Column(db.DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    updated_at     = db.Column(db.DateTime(timezone=True), default=lambda: datetime.now(timezone.utc),
                               onupdate=lambda: datetime.now(timezone.utc))

    def to_dict(self):
        return {
            "id":             self.id,
            "owner_name":     self.owner_name,
            "email":          self.email,
            "account_number": self.account_number,
            "account_type":   self.account_type,
            "balance":        float(self.balance),
            "currency":       self.currency,
            "status":         self.status,
            "created_at":     self.created_at.isoformat() if self.created_at else None,
            "updated_at":     self.updated_at.isoformat() if self.updated_at else None,
        }

# ─── Health ───────────────────────────────────────────────────────────────────

@app.route("/health/live")
def liveness():
    return jsonify({"status": "ok", "service": "account-service"}), 200

@app.route("/health/ready")
def readiness():
    try:
        db.session.execute(text("SELECT 1"))
        return jsonify({"status": "ready", "database": "connected"}), 200
    except Exception as e:
        log.error("Readiness check failed: %s", e)
        return jsonify({"status": "not ready", "database": "disconnected"}), 503

# ─── Prometheus ───────────────────────────────────────────────────────────────

@app.route("/metrics")
def metrics():
    # Refresh balance gauges
    try:
        for acct in Account.query.filter_by(status="active").all():
            ACCOUNT_BALANCE.labels(
                account_id=acct.id,
                account_type=acct.account_type,
            ).set(float(acct.balance))
    except Exception:
        pass
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}

# ─── Accounts API ─────────────────────────────────────────────────────────────

@app.route("/api/accounts", methods=["GET"])
def list_accounts():
    with REQUEST_LATENCY.labels(endpoint="/api/accounts").time():
        accounts = Account.query.filter_by(status="active").order_by(Account.created_at).all()
        REQUEST_COUNT.labels(method="GET", endpoint="/api/accounts", status="200").inc()
        return jsonify([a.to_dict() for a in accounts]), 200


@app.route("/api/accounts/<account_id>", methods=["GET"])
def get_account(account_id):
    account = Account.query.get_or_404(account_id)
    REQUEST_COUNT.labels(method="GET", endpoint="/api/accounts/<id>", status="200").inc()
    return jsonify(account.to_dict()), 200


@app.route("/api/accounts/<account_id>/balance", methods=["GET"])
def get_balance(account_id):
    account = Account.query.get_or_404(account_id)
    if account.status != "active":
        abort(403, description=f"Account {account_id} is {account.status}")
    REQUEST_COUNT.labels(method="GET", endpoint="/api/accounts/<id>/balance", status="200").inc()
    return jsonify({"account_id": account_id, "balance": float(account.balance), "currency": account.currency}), 200


@app.route("/api/accounts", methods=["POST"])
def create_account():
    data = request.get_json(force=True)
    required = ["owner_name", "email", "account_number", "account_type"]
    if not all(k in data for k in required):
        abort(400, description=f"Missing required fields: {required}")

    account = Account(
        owner_name=data["owner_name"],
        email=data["email"],
        account_number=data["account_number"],
        account_type=data["account_type"],
        balance=data.get("initial_balance", 0.00),
        currency=data.get("currency", "USD"),
    )
    db.session.add(account)
    db.session.commit()
    log.info("Created account %s for %s", account.account_number, account.owner_name)
    REQUEST_COUNT.labels(method="POST", endpoint="/api/accounts", status="201").inc()
    return jsonify(account.to_dict()), 201


@app.route("/api/accounts/<account_id>", methods=["PUT"])
def update_account(account_id):
    account = Account.query.get_or_404(account_id)
    data = request.get_json(force=True)
    for field in ["owner_name", "email", "status"]:
        if field in data:
            setattr(account, field, data[field])
    db.session.commit()
    REQUEST_COUNT.labels(method="PUT", endpoint="/api/accounts/<id>", status="200").inc()
    return jsonify(account.to_dict()), 200


@app.route("/api/accounts/<account_id>/balance", methods=["PATCH"])
def update_balance(account_id):
    """Internal endpoint called by transaction-service to apply balance changes."""
    account = Account.query.get_or_404(account_id)
    if account.status != "active":
        abort(403, description=f"Account {account_id} is {account.status}")

    data = request.get_json(force=True)
    delta = data.get("delta")  # positive = credit, negative = debit
    if delta is None:
        abort(400, description="Field 'delta' is required")

    with tracer.start_as_current_span("validate-account-balance") as span:
        span.set_attribute("account.id", str(account_id))
        span.set_attribute("account.balance", float(account.balance))
        span.set_attribute("account.delta", float(delta))
        new_balance = float(account.balance) + float(delta)
        if new_balance < 0:
            abort(422, description="Insufficient funds")

    account.balance = new_balance
    db.session.commit()
    log.info("Balance update account=%s delta=%s new_balance=%s", account_id, delta, new_balance)
    REQUEST_COUNT.labels(method="PATCH", endpoint="/api/accounts/<id>/balance", status="200").inc()
    return jsonify({"account_id": account_id, "balance": float(account.balance)}), 200


# ─── Summary ──────────────────────────────────────────────────────────────────

@app.route("/api/accounts/summary", methods=["GET"])
def summary():
    """Total balances grouped by account type — used by portal dashboard."""
    rows = db.session.execute(
        text("SELECT account_type, SUM(balance) AS total FROM accounts WHERE status='active' GROUP BY account_type")
    ).fetchall()
    total = sum(float(r.total) for r in rows)
    return jsonify({
        "total_balance": total,
        "by_type": {r.account_type: float(r.total) for r in rows},
        "account_count": Account.query.filter_by(status="active").count(),
    }), 200


# ─── Entry Point ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    with app.app_context():
        db.create_all()
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)), debug=False)
