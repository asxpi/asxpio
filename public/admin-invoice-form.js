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
})();
