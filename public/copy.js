// One copy button per [data-copy] element. Copies the data-copy value when
// set, otherwise the element's original text. Clipboard API needs a secure
// context — https in prod, localhost in dev; both hold.
document.querySelectorAll('[data-copy]').forEach(function (el) {
    var text = el.getAttribute('data-copy') || el.textContent.trim();

    var btn = document.createElement('span');
    btn.innerText = 'Copy';
    btn.classList.add('copy-button');
    el.appendChild(btn);

    btn.addEventListener('click', function () {
        navigator.clipboard.writeText(text).then(function () {
            btn.innerText = 'Copied!';
            setTimeout(function () { btn.innerText = 'Copy'; }, 2000);
        }, function () {
            btn.innerText = 'Failed';
            setTimeout(function () { btn.innerText = 'Copy'; }, 2000);
        });
    });
});
