(function () {
    const tbody = document.querySelector('#items-table tbody');
    const addBtn = document.getElementById('add-row');

    // PDF render + two S3 uploads make create slow enough to double-click,
    // which would mint two invoices with consecutive numbers.
    const form = document.querySelector('form.invoice-form');
    if (form) {
        form.addEventListener('submit', function () {
            const btn = form.querySelector('button[type="submit"]');
            if (btn) { btn.disabled = true; btn.textContent = 'Creating…'; }
        });
    }

    function reindex() {
        Array.from(tbody.querySelectorAll('tr.item-row')).forEach((row, i) => {
            row.querySelectorAll('input').forEach((input) => {
                input.name = input.name.replace(/items\[\d+\]/, 'items[' + i + ']');
            });
        });
    }

    addBtn.addEventListener('click', function () {
        const last = tbody.querySelector('tr.item-row:last-child');
        const clone = last.cloneNode(true);
        clone.querySelectorAll('input').forEach((input) => { input.value = ''; });
        tbody.appendChild(clone);
        reindex();
    });

    tbody.addEventListener('click', function (e) {
        if (!e.target.matches('.remove-row')) return;
        const rows = tbody.querySelectorAll('tr.item-row');
        if (rows.length <= 1) return;
        e.target.closest('tr.item-row').remove();
        reindex();
    });

    // --- Crypto: coin select, live rate fetch + auto amount -------------
    const coinSel = document.getElementById('crypto_coin');
    const addressInput = document.getElementById('crypto_address');
    const rateInput = document.getElementById('crypto_rate');
    const amountInput = document.getElementById('crypto_amount');
    const fetchBtn = document.getElementById('fetch-crypto-rate');
    const rateStatus = document.getElementById('crypto-rate-status');
    const rateCcy = document.getElementById('crypto-rate-ccy');
    const rateCoin = document.getElementById('crypto-rate-coin');
    const currencySel = document.getElementById('currency');
    const gelRateInput = document.getElementById('gel_rate');

    // Default payout addresses per coin, rendered server-side from env.
    let cryptoDefaults = {};
    const defaultsEl = document.getElementById('crypto-defaults');
    if (defaultsEl) {
        try { cryptoDefaults = JSON.parse(defaultsEl.textContent); } catch (e) { /* leave empty */ }
    }

    // On coin change: swap in the new coin's default address, but never
    // clobber a hand-entered one (only replace blank or known defaults).
    if (coinSel && addressInput) {
        coinSel.addEventListener('change', function () {
            const val = addressInput.value.trim();
            const isDefault = val === '' || Object.values(cryptoDefaults).indexOf(val) !== -1;
            if (isDefault) addressInput.value = cryptoDefaults[coinSel.value] || '';
            rateInput.value = '';
            if (amountInput) amountInput.value = '';
            amountTouched = false;
            rateStatus.textContent = '';
            syncCcyLabel();
        });
    }

    function invoiceTotal() {
        let total = 0;
        tbody.querySelectorAll('tr.item-row').forEach((row) => {
            const inputs = row.querySelectorAll('input');
            const qty = parseFloat(inputs[1].value) || 0;
            const unit = parseFloat(inputs[2].value) || 0;
            total += qty * unit;
        });
        return total;
    }

    // Whether the operator has hand-edited the amount; if so, don't clobber it.
    let amountTouched = false;
    if (amountInput) amountInput.addEventListener('input', () => { amountTouched = true; });

    function recomputeAmount() {
        if (!amountInput || amountTouched) return;
        const rate = parseFloat(rateInput.value);
        const total = invoiceTotal();
        if (rate > 0 && total > 0) {
            amountInput.value = (total / rate).toFixed(8).replace(/\.?0+$/, '');
        }
    }

    const gelRateCcy = document.getElementById('gel-rate-ccy');
    function syncCcyLabel() {
        const ccy = currencySel ? currencySel.value : 'USD';
        if (rateCcy) rateCcy.textContent = ccy;
        if (gelRateCcy) gelRateCcy.textContent = ccy;
        if (rateCoin && coinSel) rateCoin.textContent = coinSel.value;
    }
    syncCcyLabel();
    if (currencySel) currencySel.addEventListener('change', syncCcyLabel);

    if (rateInput) rateInput.addEventListener('input', recomputeAmount);
    tbody.addEventListener('input', recomputeAmount);

    if (fetchBtn) {
        fetchBtn.addEventListener('click', function () {
            const ccy = currencySel ? currencySel.value : 'USD';
            const coin = coinSel ? coinSel.value : 'LTC';
            const params = new URLSearchParams({ coin: coin, currency: ccy });
            if (gelRateInput && gelRateInput.value) params.set('gel_rate', gelRateInput.value);
            rateStatus.textContent = ' fetching…';
            fetch('/admin/crypto-rate?' + params.toString(), { headers: { Accept: 'application/json' } })
                .then((r) => r.json().then((j) => ({ ok: r.ok, j })))
                .then(({ ok, j }) => {
                    if (!ok) { rateStatus.textContent = ' ' + (j.error || 'failed'); return; }
                    rateInput.value = j.rate;
                    rateStatus.textContent = ' ✓ live';
                    recomputeAmount();
                })
                .catch(() => { rateStatus.textContent = ' network error'; });
        });
    }

    // --- Official GEL rate from NBG -------------------------------------
    const gelFetchBtn = document.getElementById('fetch-gel-rate');
    const gelStatus = document.getElementById('gel-rate-status');
    const issuedInput = document.getElementById('issued_on');

    if (gelFetchBtn) {
        gelFetchBtn.addEventListener('click', function () {
            const ccy = currencySel ? currencySel.value : 'USD';
            const params = new URLSearchParams({ currency: ccy });
            // Past invoice ⇒ fetch the rate as published for the issued date.
            if (issuedInput && issuedInput.value && issuedInput.value < today()) {
                params.set('date', issuedInput.value);
            }
            gelStatus.textContent = ' fetching…';
            fetch('/admin/gel-rate?' + params.toString(), { headers: { Accept: 'application/json' } })
                .then((r) => r.json().then((j) => ({ ok: r.ok, j })))
                .then(({ ok, j }) => {
                    if (!ok) { gelStatus.textContent = ' ' + (j.error || 'failed'); return; }
                    if (gelRateInput) gelRateInput.value = j.rate;
                    gelStatus.textContent = params.has('date')
                        ? ' ✓ official ' + params.get('date')
                        : ' ✓ official (latest)';
                })
                .catch(() => { gelStatus.textContent = ' network error'; });
        });
    }

    function today() {
        const d = new Date();
        const m = String(d.getMonth() + 1).padStart(2, '0');
        const day = String(d.getDate()).padStart(2, '0');
        return d.getFullYear() + '-' + m + '-' + day;
    }
})();
