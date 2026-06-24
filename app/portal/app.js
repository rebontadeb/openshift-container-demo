'use strict';

// ── State ──────────────────────────────────────────────────────────────────
let accounts = [];
let activeSection = 'dashboard';
let refreshPaused = false;
const REFRESH_INTERVAL = 10; // seconds
let countdown = REFRESH_INTERVAL;

// ── API helpers ────────────────────────────────────────────────────────────
async function api(path, options = {}) {
  const res = await fetch(path, {
    headers: { 'Content-Type': 'application/json', ...options.headers },
    ...options,
  });
  if (!res.ok) {
    const err = await res.json().catch(() => ({ description: res.statusText }));
    throw new Error(err.description || err.error || res.statusText);
  }
  return res.json();
}

// ── Toast ──────────────────────────────────────────────────────────────────
function toast(msg, type = 'success') {
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.className = `show ${type}`;
  setTimeout(() => el.classList.remove('show'), 3500);
}

// ── Formatting ────────────────────────────────────────────────────────────
function fmtCurrency(n) {
  return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(n);
}

function fmtDate(iso) {
  if (!iso) return '';
  return new Intl.DateTimeFormat('en-US', {
    month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit',
  }).format(new Date(iso));
}

const TYPE_ICONS = { checking: '🏦', savings: '🐷', investment: '📈' };
const TYPE_CSS   = { checking: 'icon-checking', savings: 'icon-savings', investment: 'icon-investment' };

function accountIcon(type) {
  return `<div class="account-icon ${TYPE_CSS[type] || 'icon-checking'}">${TYPE_ICONS[type] || '🏦'}</div>`;
}

// ── Render: Account item ───────────────────────────────────────────────────
function renderAccountItem(a) {
  return `
    <div class="account-item">
      ${accountIcon(a.account_type)}
      <div class="account-info">
        <div class="account-name">${a.owner_name}</div>
        <div class="account-num">${a.account_number}</div>
      </div>
      <div class="account-balance">
        <div class="balance-amount">${fmtCurrency(a.balance)}</div>
        <div class="balance-type">${a.account_type}</div>
      </div>
    </div>`;
}

// ── Render: Transaction item ───────────────────────────────────────────────
function renderTxnItem(t, currentAccountId = null) {
  let isIn = false, icon = '↔️', iconCss = 'icon-dep';
  if (t.transaction_type === 'deposit')    { isIn = true; icon = '⬇️'; iconCss = 'icon-dep'; }
  else if (t.transaction_type === 'withdrawal') { isIn = false; icon = '⬆️'; iconCss = 'icon-with'; }
  else if (t.transaction_type === 'transfer') {
    isIn = (t.to_account_id === currentAccountId || !currentAccountId);
    icon = isIn ? '⬇️' : '⬆️';
    iconCss = isIn ? 'icon-in' : 'icon-out';
  }
  const amountClass = isIn ? 'amount-in' : 'amount-out';
  const amountSign  = isIn ? '+' : '-';
  return `
    <li class="txn-item">
      <div class="txn-icon ${iconCss}">${icon}</div>
      <div class="txn-desc">
        <div class="txn-desc-text">${t.description || t.transaction_type}</div>
        <div class="txn-ref">${t.reference_number}</div>
      </div>
      <div>
        <div class="txn-amount ${amountClass}">${amountSign}${fmtCurrency(t.amount)}</div>
        <div class="txn-date">${fmtDate(t.created_at)}</div>
      </div>
    </li>`;
}

// ── Load: Summary cards ────────────────────────────────────────────────────
async function loadSummary() {
  try {
    const s = await api('/api/accounts/summary');
    const grid = document.getElementById('summary-grid');
    const typeTotal = s.by_type || {};
    grid.innerHTML = `
      <div class="card">
        <div class="card-title">Total Balance</div>
        <div class="stat-value">${fmtCurrency(s.total_balance)}</div>
        <div class="stat-label">Across ${s.account_count} account${s.account_count !== 1 ? 's' : ''}</div>
        <span class="stat-badge badge-green">Active</span>
      </div>
      <div class="card">
        <div class="card-title">Checking & Savings</div>
        <div class="stat-value">${fmtCurrency((typeTotal.checking || 0) + (typeTotal.savings || 0))}</div>
        <div class="stat-label">Liquid assets</div>
        <span class="stat-badge badge-blue">Liquid</span>
      </div>
      <div class="card">
        <div class="card-title">Investments</div>
        <div class="stat-value">${fmtCurrency(typeTotal.investment || 0)}</div>
        <div class="stat-label">Portfolio value</div>
        <span class="stat-badge badge-yellow">Invested</span>
      </div>`;
  } catch (e) {
    console.error('loadSummary:', e);
  }
}

// ── Load: Accounts ─────────────────────────────────────────────────────────
async function loadAccounts() {
  accounts = await api('/api/accounts');

  // Dashboard mini list (first 4)
  const dash = document.getElementById('account-list-dash');
  dash.innerHTML = accounts.slice(0, 4).map(renderAccountItem).join('') ||
    `<div class="empty-state"><div class="icon">🏦</div>No accounts found</div>`;

  // Full accounts page
  const full = document.getElementById('account-list-full');
  full.innerHTML = accounts.map(renderAccountItem).join('') ||
    `<div class="empty-state"><div class="icon">🏦</div>No accounts found</div>`;

  // Populate transfer dropdowns
  const fromSel     = document.getElementById('from-account');
  const toSel       = document.getElementById('to-account');
  const depositSel  = document.getElementById('deposit-account');
  const opts = accounts.map(a =>
    `<option value="${a.id}">${a.owner_name} — ${a.account_number} (${fmtCurrency(a.balance)})</option>`
  ).join('');
  fromSel.innerHTML    = opts;
  toSel.innerHTML      = opts;
  depositSel.innerHTML = opts;

  // Default to-account different from from-account
  if (accounts.length > 1) toSel.selectedIndex = 1;
}

// ── Load: Transactions ─────────────────────────────────────────────────────
async function loadTransactions() {
  const txns = await api('/api/transactions?limit=20');

  const dash = document.getElementById('txn-list-dash');
  const full = document.getElementById('txn-list-full');

  if (!txns.length) {
    const empty = `<div class="empty-state"><div class="icon">💳</div>No transactions yet</div>`;
    dash.innerHTML = empty;
    full.innerHTML = empty;
    return;
  }

  dash.innerHTML = txns.slice(0, 6).map(t => renderTxnItem(t)).join('');
  full.innerHTML = txns.map(t => renderTxnItem(t)).join('');
}

// ── Section navigation ─────────────────────────────────────────────────────
function showSection(name) {
  document.querySelectorAll('section').forEach(s => s.style.display = 'none');
  document.querySelectorAll('.nav-btn').forEach(b => b.classList.remove('active'));
  document.getElementById(`section-${name}`).style.display = 'block';
  event.currentTarget.classList.add('active');
  activeSection = name;

  if (name === 'accounts') loadAccounts();
  if (name === 'history')  loadTransactions();
}

// ── Auto-refresh ───────────────────────────────────────────────────────────
async function refreshActiveSection() {
  if (refreshPaused) return;
  try {
    if (activeSection === 'dashboard') {
      await Promise.all([loadSummary(), loadAccounts(), loadTransactions()]);
    } else if (activeSection === 'accounts') {
      await loadAccounts();
    } else if (activeSection === 'history') {
      await loadTransactions();
    }
    // transfer section: refresh account dropdowns silently
    else if (activeSection === 'transfer') {
      await loadAccounts();
    }
  } catch (e) {
    console.warn('Auto-refresh error:', e);
  }
}

function startRefreshCycle() {
  const countdownEl = document.getElementById('refresh-countdown');
  const toggleBtn   = document.getElementById('refresh-toggle');

  countdown = REFRESH_INTERVAL;

  setInterval(() => {
    if (refreshPaused) return;
    countdown--;
    countdownEl.textContent = countdown;
    if (countdown <= 0) {
      countdown = REFRESH_INTERVAL;
      refreshActiveSection();
    }
  }, 1000);

  toggleBtn.addEventListener('click', () => {
    refreshPaused = !refreshPaused;
    toggleBtn.textContent   = refreshPaused ? '▶' : '⏸';
    toggleBtn.title         = refreshPaused ? 'Resume auto-refresh' : 'Pause auto-refresh';
    toggleBtn.classList.toggle('paused', refreshPaused);
    if (!refreshPaused) {
      countdown = REFRESH_INTERVAL;
      countdownEl.textContent = countdown;
    } else {
      countdownEl.textContent = '—';
    }
  });
}

// ── Add Account ────────────────────────────────────────────────────────────
const TYPE_PREFIX = { checking: 'CHK', savings: 'SAV', investment: 'INV' };

function generateAccountNumber(type) {
  const prefix = TYPE_PREFIX[type] || 'ACC';
  const num = String(Math.floor(1000 + Math.random() * 9000));
  return `FF-${num}-${prefix}`;
}

document.getElementById('toggle-add-account').addEventListener('click', () => {
  const wrap = document.getElementById('add-account-form-wrap');
  const isHidden = wrap.style.display === 'none';
  wrap.style.display = isHidden ? 'block' : 'none';
  document.getElementById('toggle-add-account').textContent = isHidden ? '✕ Cancel' : '+ Add Account';
  if (isHidden) {
    // Auto-generate account number based on selected type
    const type = document.getElementById('new-account-type').value;
    document.getElementById('new-account-number').value = generateAccountNumber(type);
    document.getElementById('new-owner-name').focus();
  }
});

document.getElementById('cancel-add-account').addEventListener('click', () => {
  document.getElementById('add-account-form-wrap').style.display = 'none';
  document.getElementById('toggle-add-account').textContent = '+ Add Account';
  document.getElementById('add-account-form').reset();
});

document.getElementById('new-account-type').addEventListener('change', (e) => {
  document.getElementById('new-account-number').value = generateAccountNumber(e.target.value);
});

document.getElementById('add-account-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const btn = document.getElementById('add-account-btn');
  btn.disabled = true;
  btn.textContent = 'Creating…';

  try {
    const payload = {
      owner_name:      document.getElementById('new-owner-name').value.trim(),
      email:           document.getElementById('new-email').value.trim(),
      account_number:  document.getElementById('new-account-number').value.trim(),
      account_type:    document.getElementById('new-account-type').value,
      initial_balance: parseFloat(document.getElementById('new-initial-balance').value || '0'),
    };
    await api('/api/accounts', { method: 'POST', body: JSON.stringify(payload) });
    toast(`Account ${payload.account_number} created!`);
    document.getElementById('add-account-form').reset();
    document.getElementById('add-account-form-wrap').style.display = 'none';
    document.getElementById('toggle-add-account').textContent = '+ Add Account';
    await Promise.all([loadAccounts(), loadSummary()]);
  } catch (err) {
    toast(err.message, 'error');
  } finally {
    btn.disabled = false;
    btn.textContent = 'Create Account';
  }
});

// ── Transfer form ──────────────────────────────────────────────────────────
document.getElementById('transfer-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const btn = document.getElementById('transfer-btn');
  btn.disabled = true;
  btn.textContent = 'Processing…';

  try {
    const payload = {
      from_account_id: document.getElementById('from-account').value,
      to_account_id:   document.getElementById('to-account').value,
      amount:          parseFloat(document.getElementById('transfer-amount').value),
      description:     document.getElementById('transfer-desc').value || 'Transfer',
    };
    await api('/api/transactions/transfer', {
      method: 'POST',
      body: JSON.stringify(payload),
    });
    toast(`Transfer of ${fmtCurrency(payload.amount)} completed!`);
    document.getElementById('transfer-amount').value = '';
    document.getElementById('transfer-desc').value = '';
    await loadAccounts();
  } catch (err) {
    toast(err.message, 'error');
  } finally {
    btn.disabled = false;
    btn.textContent = 'Send Transfer';
  }
});

// ── Deposit form ───────────────────────────────────────────────────────────
document.getElementById('deposit-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const btn = document.getElementById('deposit-btn');
  btn.disabled = true;
  btn.textContent = 'Processing…';

  try {
    const payload = {
      to_account_id: document.getElementById('deposit-account').value,
      amount:        parseFloat(document.getElementById('deposit-amount').value),
      description:   document.getElementById('deposit-desc').value || 'Deposit',
    };
    await api('/api/transactions/deposit', {
      method: 'POST',
      body: JSON.stringify(payload),
    });
    toast(`Deposit of ${fmtCurrency(payload.amount)} successful!`);
    document.getElementById('deposit-amount').value = '';
    document.getElementById('deposit-desc').value = '';
    await loadAccounts();
  } catch (err) {
    toast(err.message, 'error');
  } finally {
    btn.disabled = false;
    btn.textContent = 'Deposit Funds';
  }
});

// ── Init ───────────────────────────────────────────────────────────────────
(async () => {
  try {
    await Promise.all([loadSummary(), loadAccounts(), loadTransactions()]);
    startRefreshCycle();
  } catch (err) {
    console.error('Init error:', err);
    toast('Failed to load data. Is the backend running?', 'error');
  }
})();
