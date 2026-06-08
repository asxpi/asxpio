(function () {
    const tbody = document.querySelector('#items-table tbody');
    const addBtn = document.getElementById('add-row');

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

    // --- Litecoin: live rate fetch + auto amount ------------------------
    const rateInput = document.getElementById('ltc_rate');
    const amountInput = document.getElementById('ltc_amount');
    const fetchBtn = document.getElementById('fetch-ltc-rate');
    const rateStatus = document.getElementById('ltc-rate-status');
    const rateCcy = document.getElementById('ltc-rate-ccy');
    const currencySel = document.getElementById('currency');
    const gelRateInput = document.getElementById('gel_rate');

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

    function syncCcyLabel() {
        if (rateCcy && currencySel) rateCcy.textContent = currencySel.value;
    }
    syncCcyLabel();
    if (currencySel) currencySel.addEventListener('change', syncCcyLabel);

    if (rateInput) rateInput.addEventListener('input', recomputeAmount);
    tbody.addEventListener('input', recomputeAmount);

    if (fetchBtn) {
        fetchBtn.addEventListener('click', function () {
            const ccy = currencySel ? currencySel.value : 'USD';
            const params = new URLSearchParams({ currency: ccy });
            if (gelRateInput && gelRateInput.value) params.set('gel_rate', gelRateInput.value);
            rateStatus.textContent = ' fetching…';
            fetch('/admin/ltc-rate?' + params.toString(), { headers: { Accept: 'application/json' } })
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
})();
