-- FinanceFlow Database Initialization
-- Creates schema and seeds demo data for workshop

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ─── Accounts ────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS accounts (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    owner_name      VARCHAR(255)    NOT NULL,
    email           VARCHAR(255)    UNIQUE NOT NULL,
    account_number  VARCHAR(20)     UNIQUE NOT NULL,
    account_type    VARCHAR(20)     NOT NULL DEFAULT 'checking',  -- checking | savings | investment
    balance         DECIMAL(15, 2)  NOT NULL DEFAULT 0.00,
    currency        VARCHAR(3)      NOT NULL DEFAULT 'USD',
    status          VARCHAR(20)     NOT NULL DEFAULT 'active',    -- active | frozen | closed
    created_at      TIMESTAMPTZ     DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_accounts_updated_at ON accounts;
CREATE TRIGGER trg_accounts_updated_at
    BEFORE UPDATE ON accounts
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ─── Transactions ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS transactions (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    from_account_id     UUID REFERENCES accounts(id),
    to_account_id       UUID REFERENCES accounts(id),
    amount              DECIMAL(15, 2)  NOT NULL CHECK (amount > 0),
    currency            VARCHAR(3)      NOT NULL DEFAULT 'USD',
    transaction_type    VARCHAR(30)     NOT NULL,  -- transfer | deposit | withdrawal | payment
    status              VARCHAR(20)     NOT NULL DEFAULT 'completed',  -- pending | completed | failed | reversed
    description         TEXT,
    reference_number    VARCHAR(50)     UNIQUE NOT NULL,
    created_at          TIMESTAMPTZ     DEFAULT NOW()
);

-- ─── Indexes ──────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_transactions_from_account ON transactions(from_account_id);
CREATE INDEX IF NOT EXISTS idx_transactions_to_account   ON transactions(to_account_id);
CREATE INDEX IF NOT EXISTS idx_transactions_created_at   ON transactions(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_accounts_status           ON accounts(status);

-- ─── Seed Data ────────────────────────────────────────────────────────────────

INSERT INTO accounts (id, owner_name, email, account_number, account_type, balance) VALUES
    ('11111111-1111-1111-1111-111111111111', 'Alice Johnson',  'alice@demo.financeflow',         'FF-0001-CHK', 'checking',   12450.75),
    ('22222222-2222-2222-2222-222222222222', 'Alice Johnson',  'alice.savings@demo.financeflow',  'FF-0001-SAV', 'savings',    34200.00),
    ('33333333-3333-3333-3333-333333333333', 'Bob Martinez',   'bob@demo.financeflow',            'FF-0002-CHK', 'checking',    8920.50),
    ('44444444-4444-4444-4444-444444444444', 'Carol Chen',     'carol@demo.financeflow',          'FF-0003-CHK', 'checking',    5100.00),
    ('55555555-5555-5555-5555-555555555555', 'Carol Chen',     'carol.invest@demo.financeflow',   'FF-0003-INV', 'investment', 98750.25)
ON CONFLICT DO NOTHING;

INSERT INTO transactions (from_account_id, to_account_id, amount, transaction_type, status, description, reference_number) VALUES
    ('11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333', 500.00,  'transfer',    'completed', 'Rent split March',     'REF-2024-001'),
    ('33333333-3333-3333-3333-333333333333', '44444444-4444-4444-4444-444444444444', 150.00,  'transfer',    'completed', 'Dinner reimbursement', 'REF-2024-002'),
    ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 1000.00, 'transfer',    'completed', 'Monthly savings',      'REF-2024-003'),
    (NULL,                                   '55555555-5555-5555-5555-555555555555', 5000.00, 'deposit',     'completed', 'Dividend payment',     'REF-2024-004'),
    ('44444444-4444-4444-4444-444444444444', NULL,                                   200.00,  'withdrawal',  'completed', 'ATM withdrawal',        'REF-2024-005')
ON CONFLICT DO NOTHING;
