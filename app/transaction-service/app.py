import os
import uuid
import logging
import requests
from datetime import datetime, timezone
from urllib.parse import quote_plus

from flask import Flask, jsonify, request, abort
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy import text
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(name)s %(message)s')
log = logging.getLogger(__name__)

app = Flask(__name__)

# ─── Config ───────────────────────────────────────────────────────────────────

DB_HOST          = os.environ.get("DB_HOST", "postgres")
DB_PORT          = os.environ.get("DB_PORT", "5432")
DB_NAME          = os.environ.get("DB_NAME", "financeflow")
DB_USER          = os.environ["DB_USER"]
DB_PASS          = os.environ["DB_PASSWORD"]
ACCOUNT_SVC_URL  = os.environ.get("ACCOUNT_SERVICE_URL", "http://account-service:8080")

app.config["SQLALCHEMY_DATABASE_URI"] = (
    f"postgresql://{quote_plus(DB_USER)}:{quote_plus(DB_PASS)}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
)
app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False

db = SQLAlchemy(app)

# ─── Prometheus Metrics ───────────────────────────────────────────────────────

TRANSFER_COUNT = Counter(
    "transfer_requests_total",
    "Total transactions processed",
    ["transaction_type", "status"],
)
TRANSFER_LATENCY = Histogram(
    "transfer_duration_seconds",
    "Transaction processing latency",
    ["transaction_type"],
)
TRANSFER_AMOUNT = Histogram(
    "transfer_amount_dollars",
    "Transfer amounts in USD",
    buckets=[10, 50, 100, 500, 1000, 5000, 10000, 50000],
)

# ─── Model ────────────────────────────────────────────────────────────────────

class Transaction(db.Model):
    __tablename__ = "transactions"

    id               = db.Column(db.String(36),    primary_key=True, default=lambda: str(uuid.uuid4()))
    from_account_id  = db.Column(db.String(36), nullable=True)
    to_account_id    = db.Column(db.String(36), nullable=True)
    amount           = db.Column(db.Numeric(15, 2), nullable=False)
    currency         = db.Column(db.String(3),     nullable=False, default="USD")
    transaction_type = db.Column(db.String(30),    nullable=False)
    status           = db.Column(db.String(20),    nullable=False, default="completed")
    description      = db.Column(db.Text,          nullable=True)
    reference_number = db.Column(db.String(50),    unique=True, nullable=False)
    created_at       = db.Column(db.DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    def to_dict(self):
        return {
            "id":               self.id,
            "from_account_id":  self.from_account_id,
            "to_account_id":    self.to_account_id,
            "amount":           float(self.amount),
            "currency":         self.currency,
            "transaction_type": self.transaction_type,
            "status":           self.status,
            "description":      self.description,
            "reference_number": self.reference_number,
            "created_at":       self.created_at.isoformat() if self.created_at else None,
        }

# ─── Helpers ──────────────────────────────────────────────────────────────────

def _get_balance(account_id: str) -> float:
    """Call account-service to fetch current balance."""
    resp = requests.get(
        f"{ACCOUNT_SVC_URL}/api/accounts/{account_id}/balance",
        timeout=5,
    )
    resp.raise_for_status()
    return resp.json()["balance"]


def _update_balance(account_id: str, delta: float):
    """Call account-service to apply a balance delta."""
    resp = requests.patch(
        f"{ACCOUNT_SVC_URL}/api/accounts/{account_id}/balance",
        json={"delta": delta},
        timeout=5,
    )
    resp.raise_for_status()
    return resp.json()


def _generate_ref() -> str:
    return f"TXN-{datetime.now(timezone.utc).strftime('%Y%m%d')}-{uuid.uuid4().hex[:8].upper()}"

# ─── Health ───────────────────────────────────────────────────────────────────

@app.route("/health/live")
def liveness():
    return jsonify({"status": "ok", "service": "transaction-service"}), 200

@app.route("/health/ready")
def readiness():
    try:
        db.session.execute(text("SELECT 1"))
        # Also check account-service reachability
        resp = requests.get(f"{ACCOUNT_SVC_URL}/health/live", timeout=3)
        resp.raise_for_status()
        return jsonify({"status": "ready", "database": "connected", "account_service": "reachable"}), 200
    except Exception as e:
        log.error("Readiness check failed: %s", e)
        return jsonify({"status": "not ready", "error": str(e)}), 503

# ─── Prometheus ───────────────────────────────────────────────────────────────

@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}

# ─── Transactions API ─────────────────────────────────────────────────────────

@app.route("/api/transactions", methods=["GET"])
def list_transactions():
    limit = min(int(request.args.get("limit", 20)), 100)
    txns = Transaction.query.order_by(Transaction.created_at.desc()).limit(limit).all()
    return jsonify([t.to_dict() for t in txns]), 200


@app.route("/api/transactions/<txn_id>", methods=["GET"])
def get_transaction(txn_id):
    txn = Transaction.query.get_or_404(txn_id)
    return jsonify(txn.to_dict()), 200


@app.route("/api/transactions/history/<account_id>", methods=["GET"])
def account_history(account_id):
    limit = min(int(request.args.get("limit", 20)), 100)
    txns = Transaction.query.filter(
        (Transaction.from_account_id == account_id) |
        (Transaction.to_account_id == account_id)
    ).order_by(Transaction.created_at.desc()).limit(limit).all()
    return jsonify([t.to_dict() for t in txns]), 200


@app.route("/api/transactions/transfer", methods=["POST"])
def transfer():
    """
    Transfer funds between two accounts.
    Calls account-service to validate balances and apply debits/credits.
    """
    data = request.get_json(force=True)
    required = ["from_account_id", "to_account_id", "amount"]
    if not all(k in data for k in required):
        abort(400, description=f"Missing required fields: {required}")

    from_id     = data["from_account_id"]
    to_id       = data["to_account_id"]
    amount      = float(data["amount"])
    description = data.get("description", "Transfer")

    if amount <= 0:
        abort(400, description="Amount must be greater than zero")
    if from_id == to_id:
        abort(400, description="Source and destination accounts must differ")

    with TRANSFER_LATENCY.labels(transaction_type="transfer").time():
        try:
            # Validate source balance via account-service
            balance = _get_balance(from_id)
            if balance < amount:
                TRANSFER_COUNT.labels(transaction_type="transfer", status="failed").inc()
                abort(422, description=f"Insufficient funds: balance {balance:.2f}, requested {amount:.2f}")

            # Apply debit and credit
            _update_balance(from_id, -amount)
            _update_balance(to_id, +amount)

            # Record transaction
            txn = Transaction(
                from_account_id=from_id,
                to_account_id=to_id,
                amount=amount,
                transaction_type="transfer",
                status="completed",
                description=description,
                reference_number=_generate_ref(),
            )
            db.session.add(txn)
            db.session.commit()

            TRANSFER_COUNT.labels(transaction_type="transfer", status="success").inc()
            TRANSFER_AMOUNT.observe(amount)
            log.info("Transfer completed ref=%s from=%s to=%s amount=%.2f", txn.reference_number, from_id, to_id, amount)
            return jsonify(txn.to_dict()), 201

        except requests.HTTPError as e:
            TRANSFER_COUNT.labels(transaction_type="transfer", status="failed").inc()
            log.error("Account service error during transfer: %s", e)
            abort(502, description=f"Account service error: {e.response.text if e.response else str(e)}")
        except requests.RequestException as e:
            TRANSFER_COUNT.labels(transaction_type="transfer", status="failed").inc()
            log.error("Cannot reach account-service: %s", e)
            abort(503, description="Account service unavailable")


@app.route("/api/transactions/deposit", methods=["POST"])
def deposit():
    data = request.get_json(force=True)
    if not all(k in data for k in ["to_account_id", "amount"]):
        abort(400, description="Fields 'to_account_id' and 'amount' are required")

    to_id  = data["to_account_id"]
    amount = float(data["amount"])
    if amount <= 0:
        abort(400, description="Amount must be greater than zero")

    try:
        _update_balance(to_id, +amount)
        txn = Transaction(
            to_account_id=to_id,
            amount=amount,
            transaction_type="deposit",
            status="completed",
            description=data.get("description", "Deposit"),
            reference_number=_generate_ref(),
        )
        db.session.add(txn)
        db.session.commit()
        TRANSFER_COUNT.labels(transaction_type="deposit", status="success").inc()
        log.info("Deposit completed ref=%s to=%s amount=%.2f", txn.reference_number, to_id, amount)
        return jsonify(txn.to_dict()), 201
    except requests.RequestException as e:
        abort(503, description=f"Account service unavailable: {e}")


# ─── Entry Point ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)), debug=False)
