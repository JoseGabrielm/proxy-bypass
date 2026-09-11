/* ================================================================
   State
   ================================================================ */
const state = {
    view: 'loading',
    installed: false,
    running: false,
    proxyInfo: null,
    installing: false,
    steps: [],
    results: null,
    reverting: false,
    testing: false,
    testResult: null,
};

const STEPS_TEMPLATE = [
    { id: 'download', title: 'Baixando sing-box' },
    { id: 'config',   title: 'Configurando proxy' },
    { id: 'install',  title: 'Instalando no sistema' },
    { id: 'start',    title: 'Iniciando serviço' },
];

/* ================================================================
   Icons (inline SVG)
   ================================================================ */
const icon = {
    check: '<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg>',
    x: '<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>',
    warn: '<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M12 9v4"/><path d="M12 17h.01"/></svg>',
    eye: '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg>',
    eyeOff: '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24"/><line x1="1" y1="1" x2="23" y2="23"/></svg>',
    externalLink: '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><polyline points="15 3 21 3 21 9"/><line x1="10" y1="14" x2="21" y2="3"/></svg>',
    spinner: '<div class="mini-spinner"></div>',
    checkBig: '\u2713',
    warnBig: '\u26A0',
    xBig: '\u2715',
};

/* ================================================================
   API
   ================================================================ */
async function api(path, opts) {
    opts = opts || {};
    var res = await fetch(path, {
        method: opts.method || 'GET',
        headers: opts.body ? { 'Content-Type': 'application/json' } : {},
        body: opts.body ? JSON.stringify(opts.body) : undefined,
    });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    return res.json();
}

function apiStatus() { return api('/api/status'); }
function apiCancel() { return api('/api/cancel', { method: 'POST' }); }
function apiMonitor() { return api('/api/monitor', { method: 'POST' }); }
function apiTest(ip, port, password) {
    return api('/api/test', {
        method: 'POST',
        body: { ip: ip, port: parseInt(port), password: password }
    });
}

async function apiInstall(ip, port, password, autostart) {
    var res = await fetch('/api/install', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ip: ip, port: parseInt(port), password: password, autostart: autostart }),
    });

    var reader = res.body.getReader();
    var decoder = new TextDecoder();
    var buffer = '';

    while (true) {
        var chunk = await reader.read();
        if (chunk.done) break;

        buffer += decoder.decode(chunk.value, { stream: true });
        var parts = buffer.split('\n\n');
        buffer = parts.pop();

        for (var i = 0; i < parts.length; i++) {
            var part = parts[i];
            if (!part.trim()) continue;
            var lines = part.split('\n');
            var event = 'message', data = '';
            for (var j = 0; j < lines.length; j++) {
                if (lines[j].indexOf('event: ') === 0) event = lines[j].slice(7).trim();
                else if (lines[j].indexOf('data: ') === 0) data = lines[j].slice(6);
            }
            if (data) {
                try { handleSSE(event, JSON.parse(data)); }
                catch (e) { console.error('SSE parse error:', e, data); }
            }
        }
    }
}

function handleSSE(event, data) {
    if (event === 'step') {
        var step = state.steps.find(function(s) { return s.id === data.id; });
        if (step) {
            step.status = data.status;
            step.message = data.message || '';
        }
        render();
    } else if (event === 'complete') {
        state.results = data;
        state.view = 'results';
        state.installing = false;
        setHeader('Discord Proxy', 'Instalação concluída');
        render();
    } else if (event === 'error') {
        var activeStep = state.steps.find(function(s) { return s.status === 'running'; });
        if (activeStep) {
            activeStep.status = 'error';
            activeStep.message = data.message;
        }
        state.installing = false;
        render();
    }
}

/* ================================================================
   Render
   ================================================================ */
function $content() { return document.getElementById('card-content'); }

function setHeader(title, subtitle) {
    document.getElementById('header-title').textContent = title;
    document.getElementById('header-subtitle').textContent = subtitle;
}

function render() {
    var el = $content();
    switch (state.view) {
        case 'loading':     el.innerHTML = viewLoading(); break;
        case 'form':        el.innerHTML = viewForm(); break;
        case 'progress':    el.innerHTML = viewProgress(); break;
        case 'results':     el.innerHTML = viewResults(); break;
        case 'management':  el.innerHTML = viewManagement(); break;
    }
}

/* -------- Loading -------- */
function viewLoading() {
    return '<div class="loading-container">' +
        '<div class="loading-spinner"></div>' +
        '<span style="color: var(--text-muted); font-size: 13px;">Verificando...</span>' +
    '</div>';
}

/* -------- Form -------- */
function viewForm() {
    return '<div class="view-enter">' +
        '<div class="input-group">' +
            '<label class="input-label" for="inp-ip">IP / Host do servidor</label>' +
            '<input type="text" id="inp-ip" class="input-field" placeholder="ex: 203.0.113.5" autocomplete="off" spellcheck="false">' +
            '<div class="input-error" id="err-ip">Informe o IP ou hostname do servidor</div>' +
        '</div>' +
        '<div class="input-group">' +
            '<label class="input-label" for="inp-port">Porta</label>' +
            '<input type="number" id="inp-port" class="input-field" placeholder="ex: 8388" min="1" max="65535" autocomplete="off">' +
            '<div class="input-error" id="err-port">Porta inválida (1\u201365535)</div>' +
        '</div>' +
        '<div class="input-group">' +
            '<label class="input-label" for="inp-pass">Senha</label>' +
            '<div class="input-wrapper">' +
                '<input type="password" id="inp-pass" class="input-field input-field-password" placeholder="Senha do servidor" autocomplete="off">' +
                '<button type="button" class="toggle-password" data-action="toggle-password">' + icon.eye + '</button>' +
            '</div>' +
            '<div class="input-error" id="err-pass">Informe a senha</div>' +
        '</div>' +
        '<div class="input-group" style="display: flex; flex-direction: row; align-items: center; margin-top: 10px;">' +
            '<input type="checkbox" id="inp-autostart" checked style="margin-right: 8px; width: 16px; height: 16px; accent-color: var(--primary); cursor: pointer;">' +
            '<label class="input-label" for="inp-autostart" style="margin-bottom: 0; cursor: pointer; user-select: none;">Iniciar com o Windows</label>' +
        '</div>' +
        '</div>' +
        (state.testResult ? '<div class="test-banner ' + (state.testResult.success ? 'success' : 'error') + '">' +
            (state.testResult.success ? icon.checkBig + '&nbsp; Conexão bem sucedida!' : icon.xBig + '&nbsp; ' + esc(state.testResult.message)) +
        '</div>' : '') +
        '<div class="btn-row">' +
            '<button class="btn btn-secondary" data-action="test"' + (state.testing ? ' disabled' : '') + '>' +
                (state.testing ? '<div class="spinner-inline"></div> ' : '') + 'Testar Conexão' +
            '</button>' +
            '<button class="btn btn-primary" data-action="install"' + (state.installing || state.testing ? ' disabled' : '') + '>' +
                'Instalar \u25B8' +
            '</button>' +
        '</div>' +
    '</div>';
}

/* -------- Progress -------- */
function viewProgress() {
    var total = state.steps.length;
    var done = state.steps.filter(function(s) { return s.status === 'done'; }).length;
    var hasError = state.steps.some(function(s) { return s.status === 'error'; });
    var pct = (done / total * 100);

    var stepsHtml = '';
    for (var i = 0; i < state.steps.length; i++) {
        var s = state.steps[i];
        var iconHtml = '';
        if (s.status === 'done') iconHtml = icon.check;
        else if (s.status === 'running') iconHtml = icon.spinner;
        else if (s.status === 'error') iconHtml = icon.x;
        else if (s.status === 'warning') iconHtml = icon.warn;

        var msgHtml = s.message ? '<div class="step-msg">' + esc(s.message) + '</div>' : '';
        stepsHtml += '<div class="step ' + s.status + '">' +
            '<div class="step-icon">' + iconHtml + '</div>' +
            '<div class="step-title">' + esc(s.title) + '</div>' +
            msgHtml +
        '</div>';
    }

    var errorMsg = '';
    if (hasError) {
        errorMsg = '<div class="divider"></div>' +
           '<div class="test-banner error">' + icon.xBig + '&nbsp; A instalação falhou. Corrija o problema e tente novamente.</div>' +
           '<div class="btn-row"><button class="btn btn-secondary btn-block" data-action="back-to-form">\u2190 Voltar</button></div>';
    }

    return '<div class="view-enter">' +
        '<div class="progress-track"><div class="progress-fill" style="width:' + pct + '%"></div></div>' +
        '<div class="stepper">' + stepsHtml + '</div>' +
        errorMsg +
    '</div>';
}

/* -------- Results -------- */
function viewResults() {
    var r = state.results || {};
    
    return '<div class="view-enter">' +
        '<div class="results-title">' +
            '<span style="color: var(--success); font-size: 22px;">\u2713</span>' +
            ' Instalação concluída' +
        '</div>' +
        '<div class="btn-row">' +
            '<button class="btn btn-secondary btn-sm" data-action="monitor">' +
                icon.externalLink + ' Monitor' +
            '</button>' +
            '<button class="btn btn-danger btn-sm" data-action="cancel">' +
                'Desinstalar' +
            '</button>' +
        '</div>' +
    '</div>';
}

/* -------- Management (already installed) -------- */
function viewManagement() {
    var running = state.running;
    var info = state.proxyInfo;

    return '<div class="view-enter">' +
        '<div style="text-align: center; margin-bottom: 20px;">' +
            '<span class="status-badge ' + (running ? 'running' : 'stopped') + '">' +
                '<span class="status-dot"></span>' +
                (running ? 'Ativo' : 'Parado') +
            '</span>' +
        '</div>' +
        (info ? '<div class="mgmt-info">' +
            '<div class="label">Servidor proxy</div>' +
            '<div class="value">' + esc(info.ip) + ':' + esc(String(info.port)) + '</div>' +
        '</div>' : '') +
        '<div class="divider"></div>' +
        '<div class="btn-row">' +
            '<button class="btn btn-secondary btn-block" data-action="monitor">' +
                icon.externalLink + ' Monitor' +
            '</button>' +
        '</div>' +
        '<div class="btn-row">' +
            '<button class="btn btn-secondary btn-block" data-action="reinstall">' +
                'Reinstalar' +
            '</button>' +
            '<button class="btn btn-danger btn-block" data-action="cancel"' + (state.reverting ? ' disabled' : '') + '>' +
                (state.reverting ? '<div class="spinner-inline" style="border-top-color: var(--error)"></div> ' : '') + 'Desinstalar' +
            '</button>' +
        '</div>' +
    '</div>';
}

/* ================================================================
   Helpers
   ================================================================ */
function esc(s) {
    if (!s) return '';
    var el = document.createElement('span');
    el.textContent = s;
    return el.innerHTML;
}

function getFormData() {
    var ip = (document.getElementById('inp-ip') || {}).value || '';
    var port = (document.getElementById('inp-port') || {}).value || '';
    var password = (document.getElementById('inp-pass') || {}).value || '';
    var autostart = true;
    var asEl = document.getElementById('inp-autostart');
    if (asEl) autostart = asEl.checked;
    return { ip: ip.trim(), port: port.trim(), password: password, autostart: autostart };
}

function validateForm() {
    var fd = getFormData();
    var valid = true;

    var ipEl = document.getElementById('inp-ip');
    var portEl = document.getElementById('inp-port');
    var passEl = document.getElementById('inp-pass');

    if (!fd.ip) { if (ipEl) ipEl.classList.add('has-error'); valid = false; }
    else { if (ipEl) ipEl.classList.remove('has-error'); }

    var portNum = parseInt(fd.port);
    if (!fd.port || isNaN(portNum) || portNum < 1 || portNum > 65535) {
        if (portEl) portEl.classList.add('has-error'); valid = false;
    } else { if (portEl) portEl.classList.remove('has-error'); }

    if (!fd.password) { if (passEl) passEl.classList.add('has-error'); valid = false; }
    else { if (passEl) passEl.classList.remove('has-error'); }

    return valid;
}

function showConfirm(title, message, onConfirm) {
    var root = document.getElementById('confirm-root');
    root.innerHTML = '<div class="confirm-overlay" data-action="confirm-cancel">' +
        '<div class="confirm-box" onclick="event.stopPropagation()">' +
            '<h3>' + title + '</h3>' +
            '<p>' + message + '</p>' +
            '<div class="btn-row">' +
                '<button class="btn btn-secondary" data-action="confirm-cancel-btn">Cancelar</button>' +
                '<button class="btn btn-danger" data-action="confirm-ok">Confirmar</button>' +
            '</div>' +
        '</div>' +
    '</div>';

    root.querySelector('[data-action="confirm-ok"]').onclick = function() {
        root.innerHTML = '';
        onConfirm();
    };
    root.querySelector('[data-action="confirm-cancel-btn"]').onclick = function() {
        root.innerHTML = '';
    };
    root.querySelector('[data-action="confirm-cancel"]').onclick = function(e) {
        if (e.target === e.currentTarget) root.innerHTML = '';
    };
}

/* ================================================================
   Handlers
   ================================================================ */
// Store form data before re-render
var savedFormData = { ip: '', port: '', password: '', autostart: true };

function saveFormState() {
    if (state.view === 'form') {
        savedFormData = getFormData();
    }
}

function restoreFormState() {
    if (state.view === 'form') {
        var ipEl = document.getElementById('inp-ip');
        var portEl = document.getElementById('inp-port');
        var passEl = document.getElementById('inp-pass');
        var asEl = document.getElementById('inp-autostart');
        if (ipEl) ipEl.value = savedFormData.ip;
        if (portEl) portEl.value = savedFormData.port;
        if (passEl) passEl.value = savedFormData.password;
        if (asEl) asEl.checked = savedFormData.autostart !== false;
    }
}

// Wrap render to preserve form state
var _originalRender = render;
render = function() {
    saveFormState();
    _originalRender();
    restoreFormState();
};

async function handleInstall() {
    saveFormState();
    if (!validateForm()) return;
    var fd = savedFormData;

    state.view = 'progress';
    state.installing = true;
    state.steps = STEPS_TEMPLATE.map(function(s) { return { id: s.id, title: s.title, status: 'pending', message: '' }; });
    state.results = null;
    setHeader('Discord Proxy', 'Instalando...');
    render();

    try {
        await apiInstall(fd.ip, parseInt(fd.port), fd.password, fd.autostart);
        if (state.view !== 'results') {
            state.installing = false;
            render();
        }
    } catch (e) {
        console.error('Install stream error:', e);
        var activeStep = state.steps.find(function(s) { return s.status === 'running'; });
        if (activeStep) {
            activeStep.status = 'error';
            activeStep.message = 'Conexão perdida: ' + e.message;
        }
        state.installing = false;
        render();
    }
}

async function handleTest() {
    saveFormState();
    if (!validateForm()) return;
    var fd = savedFormData;

    state.testing = true;
    state.testResult = null;
    render();

    try {
        var result = await apiTest(fd.ip, fd.port, fd.password);
        state.testResult = result;
    } catch (e) {
        state.testResult = { success: false, message: 'Erro ao testar a conexão: ' + e.message };
    } finally {
        state.testing = false;
        render();
    }
}

async function handleMonitor() {
    try { await apiMonitor(); }
    catch (e) { console.error('Monitor error:', e); }
}

async function handleCancel() {
    showConfirm(
        'Desinstalar proxy?',
        'Isso vai parar o sing-box, remover a tarefa agendada, o adaptador de rede virtual, e devolver a rede ao normal.',
        async function() {
            state.reverting = true;
            render();
            try {
                var result = await apiCancel();
                if (result.success) {
                    state.installed = false;
                    state.running = false;
                    state.view = 'form';
                    state.results = null;
                    savedFormData = { ip: '', port: '', password: '', autostart: true };
                    setHeader('Discord Proxy', 'Configure a proxy para o Discord');
                }
            } catch (e) {
                console.error('Cancel error:', e);
            } finally {
                state.reverting = false;
                render();
            }
        }
    );
}

/* ================================================================
   Event Delegation
   ================================================================ */
document.addEventListener('click', function(e) {
    var target = e.target.closest('[data-action]');
    if (!target) return;

    var action = target.dataset.action;
    switch (action) {
        case 'test':            handleTest(); break;
        case 'install':         handleInstall(); break;
        case 'monitor':         handleMonitor(); break;
        case 'cancel':          handleCancel(); break;
        case 'reinstall':
            state.view = 'form';
            savedFormData = { ip: '', port: '', password: '', autostart: true };
            setHeader('Discord Proxy', 'Configure a proxy para o Discord');
            render();
            break;
        case 'back-to-form':
            state.view = 'form';
            setHeader('Discord Proxy', 'Configure a proxy para o Discord');
            render();
            break;
        case 'toggle-password':
            var inp = document.getElementById('inp-pass');
            if (inp) {
                var isPass = inp.type === 'password';
                inp.type = isPass ? 'text' : 'password';
                target.innerHTML = isPass ? icon.eyeOff : icon.eye;
            }
            break;
    }
});

document.addEventListener('input', function(e) {
    if (e.target.classList.contains('input-field')) {
        e.target.classList.remove('has-error');
    }
});

document.addEventListener('keydown', function(e) {
    if (e.key === 'Enter' && state.view === 'form') {
        e.preventDefault();
        handleInstall();
    }
});

/* ================================================================
   Init
   ================================================================ */
async function init() {
    try {
        var status = await apiStatus();
        state.installed = status.installed;
        state.running = status.running;
        state.proxyInfo = status.proxyInfo;

        if (status.installed) {
            state.view = 'management';
            setHeader('Discord Proxy', 'Gerenciamento');
        } else {
            state.view = 'form';
            setHeader('Discord Proxy', 'Configure a proxy para o Discord');
        }
    } catch (e) {
        state.view = 'form';
        setHeader('Discord Proxy', 'Configure a proxy para o Discord');
    }
    render();
}

init();
