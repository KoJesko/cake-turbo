'use strict';
'require view';
'require rpc';
'require ui';
'require poll';

var callStatus = rpc.declare({ object: 'cake-turbo', method: 'status' });
var callGet = rpc.declare({ object: 'cake-turbo', method: 'get' });
var callSet = rpc.declare({ object: 'cake-turbo', method: 'set', params: [ 'values' ] });
var callService = rpc.declare({ object: 'cake-turbo', method: 'service', params: [ 'action' ] });

var PROFILES = {
	balanced: _('Balanced: the latency knobs in config.sh (+15 ms threshold, floor at MIN_PCT)'),
	throughput: _('Throughput: ping under 30 ms may rise 27.5 ms (max 50 ms), higher pings 1.5x; never below plan when overprovisioned'),
	'fibre-throughput': _('Fibre throughput: like Throughput with half the allowance (13.75 ms) and loaded ping capped at 20 ms'),
	extra: _('Extra: ignores ping, runs at the ceiling when busy, backs off only on packet loss')
};

/* [key, label, unit, description, profiles it matters for (null = all)] */
var FIELDS = [
	[ 'DL_BASE_KBPS', _('Download plan'), 'kbit/s', _('What the ISP sells'), null ],
	[ 'UL_BASE_KBPS', _('Upload plan'), 'kbit/s', null, null ],
	[ 'DL_OVERPROV_PCT', _('Download ceiling'), '% of plan', _('160 = up to 1.6x the plan'), null ],
	[ 'UL_OVERPROV_PCT', _('Upload ceiling'), '% of plan', _('100 = never above the plan'), null ],
	[ 'MIN_PCT', _('Floor'), '% of plan', _('Throughput/Extra floor overprovisioned directions at 100%'), null ],
	[ 'DELAY_THR_MS', _('Bloat threshold'), 'ms', _('RTT rise that counts as bufferbloat'), [ 'balanced' ] ],
	[ 'THROUGHPUT_LOW_PING_MS', _('Low-ping limit'), 'ms', _('Idle pings below this get the fixed allowance'), [ 'throughput', 'fibre-throughput' ] ],
	[ 'THROUGHPUT_LOW_EXTRA_MS', _('Low-ping allowance'), 'ms', _('Extra ping allowed under load'), [ 'throughput' ] ],
	[ 'FIBRE_LOW_EXTRA_MS', _('Low-ping allowance'), 'ms', _('Extra ping allowed under load'), [ 'fibre-throughput' ] ],
	[ 'THROUGHPUT_MAX_PING_MS', _('Ping cap'), 'ms', _('Loaded ping never above this (low pings)'), [ 'throughput' ] ],
	[ 'FIBRE_MAX_PING_MS', _('Ping cap'), 'ms', _('Loaded ping never above this (low pings)'), [ 'fibre-throughput' ] ],
	[ 'THROUGHPUT_PCT', _('High-ping allowance'), '%', _('50 = loaded ping up to 1.5x idle'), [ 'throughput', 'fibre-throughput' ] ]
];

function mbit(kbit) {
	return (kbit == null) ? '-' : (kbit / 1000).toFixed(kbit >= 100000 ? 0 : 1) + ' Mbit/s';
}

return view.extend({
	load: function() {
		return Promise.all([ callStatus(), callGet() ]);
	},

	cell: function(id) {
		return this.cells[id] || (this.cells[id] = E('td', { 'class': 'td' }, '-'));
	},

	updateStatus: function(st) {
		var self = this;
		st = st || {};
		var age = (st.updated && st.now) ? st.now - st.updated : null;
		var live = st.running && age != null && age < 10;

		this.stateEl.textContent = st.running ? (live ? _('Running') : _('Running (status stale)')) : _('Stopped');
		this.stateEl.style.color = live ? 'var(--success-color, #2e7d32)' : 'var(--error-color, #c62828)';
		this.profileEl.textContent = st.profile || '-';
		this.bloatEl.textContent = st.bloat || '-';
		this.bootEl.textContent = st.enabled ? _('yes') : _('no');

		[ 'dl', 'ul' ].forEach(function(d) {
			var s = st[d] || {};
			self.cell(d + 'iface').textContent = s.iface || '-';
			self.cell(d + 'rate').textContent = mbit(s.rate);
			self.cell(d + 'good').textContent = mbit(s.good);
			self.cell(d + 'tput').textContent = mbit(s.throughput);
			self.cell(d + 'load').textContent = (s.load != null) ? s.load + '%' : '-';
			self.cell(d + 'range').textContent = (s.base != null) ? mbit(s.base) + ' – ' + mbit(s.max) : '-';
			self.cell(d + 'cuts').textContent = (s.cuts != null) ? String(s.cuts) : '-';
		});

		this.logEl.textContent = (st.log && st.log.length) ? st.log.join('\n') : _('No log lines yet.');
	},

	updateVisibility: function() {
		var p = this.inputs.PROFILE.value;
		this.profileDesc.textContent = PROFILES[p] || '';
		FIELDS.forEach(function(f) {
			var row = this.rows[f[0]];
			row.style.display = (!f[4] || f[4].indexOf(p) >= 0) ? '' : 'none';
		}, this);
	},

	handleSaveSettings: function(ev) {
		var values = {};
		Object.keys(this.inputs).forEach(function(k) {
			var v = String(this.inputs[k].value).trim();
			if (v !== '')
				values[k] = v;
		}, this);

		return callSet(values).then(L.bind(function(res) {
			if (res && res.error)
				ui.addNotification(null, E('p', res.error), 'danger');
			else
				ui.addNotification(null, E('p', res.restarted ? _('Saved and restarted.') : _('Saved. Start the service to apply.')), 'info');
			return callStatus().then(L.bind(this.updateStatus, this));
		}, this)).catch(function(e) {
			ui.addNotification(null, E('p', _('Save failed: ') + e.message), 'danger');
		});
	},

	handleService: function(action, ev) {
		return callService(action).then(L.bind(function(res) {
			if (res && res.error)
				ui.addNotification(null, E('p', res.error), 'danger');
			return new Promise(function(r) { window.setTimeout(r, 1500); });
		}, this)).then(L.bind(function() {
			return callStatus().then(L.bind(this.updateStatus, this));
		}, this));
	},

	render: function(data) {
		var st = data[0] || {}, cfg = data[1] || {};
		var self = this;
		this.cells = {};
		this.inputs = {};
		this.rows = {};

		this.stateEl = E('strong');
		this.profileEl = E('span');
		this.bloatEl = E('span');
		this.bootEl = E('span');
		this.logEl = E('pre', { 'style': 'white-space:pre-wrap;max-height:20em;overflow:auto;font-size:90%' });

		var head = E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, ''),
			E('th', { 'class': 'th' }, _('Interface')),
			E('th', { 'class': 'th' }, _('Shaper rate')),
			E('th', { 'class': 'th' }, _('Learned good')),
			E('th', { 'class': 'th' }, _('Throughput')),
			E('th', { 'class': 'th' }, _('Load')),
			E('th', { 'class': 'th' }, _('Plan – ceiling')),
			E('th', { 'class': 'th' }, _('Cuts'))
		]);
		var rowsEl = [ [ 'dl', _('Download') ], [ 'ul', _('Upload') ] ].map(function(d) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, E('strong', d[1])),
				self.cell(d[0] + 'iface'), self.cell(d[0] + 'rate'), self.cell(d[0] + 'good'),
				self.cell(d[0] + 'tput'), self.cell(d[0] + 'load'), self.cell(d[0] + 'range'),
				self.cell(d[0] + 'cuts')
			]);
		});

		/* settings form */
		var sel = E('select', { 'class': 'cbi-input-select', 'change': L.bind(this.updateVisibility, this) },
			Object.keys(PROFILES).map(function(p) {
				return E('option', { 'value': p, 'selected': (cfg.PROFILE || 'balanced') === p ? '' : null }, p);
			}));
		this.inputs.PROFILE = sel;
		this.profileDesc = E('div', { 'class': 'cbi-value-description' });

		var formRows = [
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Profile')),
				E('div', { 'class': 'cbi-value-field' }, [ sel, this.profileDesc ])
			])
		];
		FIELDS.forEach(function(f) {
			var inp = E('input', {
				'class': 'cbi-input-text', 'type': 'text', 'inputmode': 'decimal',
				'style': 'width:10em', 'value': cfg[f[0]] || '', 'placeholder': _('default')
			});
			self.inputs[f[0]] = inp;
			self.rows[f[0]] = E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, f[1]),
				E('div', { 'class': 'cbi-value-field' }, [
					inp, ' ', E('span', f[2]),
					f[3] ? E('div', { 'class': 'cbi-value-description' }, f[3]) : ''
				])
			]);
			formRows.push(self.rows[f[0]]);
		});

		var page = E('div', { 'class': 'cbi-map' }, [
			E('h2', _('CAKE Turbo')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Moves the SQM cake shaper rates on links the ISP overprovisions. SQM must stay enabled; this only changes its bandwidth.')),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Status')),
				E('p', [
					this.stateEl, ' · ', _('profile'), ' ', this.profileEl,
					' · ', _('bloated samples'), ' ', this.bloatEl,
					' · ', _('start at boot'), ' ', this.bootEl
				]),
				E('table', { 'class': 'table' }, [ head ].concat(rowsEl)),
				E('div', { 'class': 'cbi-page-actions', 'style': 'text-align:left' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(this, 'handleService', 'start') }, _('Start')), ' ',
					E('button', { 'class': 'btn cbi-button cbi-button-reset', 'click': ui.createHandlerFn(this, 'handleService', 'stop') }, _('Stop')), ' ',
					E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleService', 'restart') }, _('Restart')), ' ',
					E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleService', 'enable') }, _('Start at boot')), ' ',
					E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleService', 'disable') }, _('Don\'t start at boot'))
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Settings')),
				cfg.exists ? '' : E('p', { 'class': 'alert-message warning' }, _('/root/cake-turbo/config.sh is missing; run install.sh first.')),
				E('div', { 'class': 'cbi-section-node' }, formRows),
				E('div', { 'class': 'cbi-value-description' },
					_('Saved to /root/cake-turbo/config.sh. A later deploy with a site config from your PC overwrites these values.')),
				E('div', { 'class': 'cbi-page-actions' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-save', 'click': ui.createHandlerFn(this, 'handleSaveSettings') }, _('Save & restart'))
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Recent log')),
				this.logEl
			])
		]);

		this.updateVisibility();
		this.updateStatus(st);
		poll.add(L.bind(function() {
			return callStatus().then(L.bind(this.updateStatus, this));
		}, this), 2);

		return page;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
