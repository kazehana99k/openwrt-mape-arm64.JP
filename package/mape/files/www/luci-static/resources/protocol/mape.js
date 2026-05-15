'use strict';
'require form';
'require fs';
'require network';

/*
 * LuCI protocol handler for MAP-E (custom).
 *
 * Renders the configuration form on Network → Interfaces for any interface
 * with `option proto 'mape'`. Backend: /lib/netifd/proto/mape.sh.
 *
 * Supports three input modes:
 *   ① pd_prefix      — operator gives PD directly (most common)
 *   ② tunlink        — read PD from upstream IPv6 interface (e.g. wan6)
 *   ③ manual fields  — full RFC 7597 parameter override (Asahi/transix/etc.)
 */

return network.registerProtocol('mape', {
	getI18n: function() {
		return _('MAP-E (custom)');
	},

	getIfname: function() {
		return this._ubus('l3_device') || this.sid;
	},

	getOpkgPackage: function() {
		return 'mape';
	},

	isFloating: function() { return true; },
	isVirtual:  function() { return true; },
	getDevices: function() { return null; },

	containsDevice: function(dev) {
		return network.getIfnameOf(dev) == this.getIfname();
	},

	renderFormOptions: function(s) {
		var o;

		/* === General tab === */

		/* Auto-detected parameters preview (read-only, populated after Save & Apply
		 * by reading /var/run/mape.<iface>.json which the netifd proto handler writes). */
		o = s.taboption('general', form.DummyValue, '_detected',
			_('Auto-detected parameters'));
		o.rawhtml = true;
		o.cfgvalue = function(section_id) {
			return fs.read('/var/run/mape.' + section_id + '.json').then(function(content) {
				var d;
				try { d = JSON.parse(content); }
				catch (e) { return _('(invalid status file)'); }

				return [
					'<div style="font-family:monospace;line-height:1.6">',
					'<b>' + _('ISP') + ':</b> ' + (d.isp_name || _('unknown')) + '<br>',
					'<b>' + _('Matched rule') + ':</b> ' + (d.rule_id || '—') + '<br>',
					'<b>' + _('CE IPv6') + ':</b> ' + (d.ce_ipv6 || '—') + '<br>',
					'<b>' + _('IPv4') + ':</b> ' + (d.ipv4 || '—') + '<br>',
					'<b>' + _('Border Relay') + ':</b> ' + (d.br_ipv6 || '—') + '<br>',
					'<b>' + _('PSID') + ':</b> ' + (d.psid != null ? d.psid : '—'),
					' (offset=' + d.psid_offset + ', len=' + d.psid_len + ')<br>',
					'<b>' + _('EA bits') + ':</b> ' + (d.ea_len || '—') + '<br>',
					'</div>'
				].join('');
			}).catch(function() {
				return '<em>' + _('Not yet detected. Save & Apply to populate, then refresh.') + '</em>';
			});
		};

		o = s.taboption('general', form.Value, 'pd_prefix',
			_('IPv6 PD prefix'),
			_('Your delegated IPv6 prefix from the ISP, e.g. <code>2404:7a80:0:0::/56</code>. ' +
			  'Mutually exclusive with <em>tunlink</em>.'));
		o.placeholder = '2404:7a80:0:0::/56';
		o.datatype = 'cidr6';

		o = s.taboption('general', form.ListValue, 'tunlink',
			_('Read PD from upstream interface'),
			_('Alternative to PD prefix: auto-fetch the PD from another IPv6 interface (typically wan6).'));
		o.value('', '— none (use pd_prefix) —');
		o.value('wan6', 'wan6');
		o.optional = true;

		o = s.taboption('general', form.Value, 'wan_dev',
			_('Physical WAN device'),
			_('The L2 interface on which the CE IPv6 address is bound (e.g. eth4).'));
		o.placeholder = 'eth4';
		o.datatype = 'string';

		/* === Advanced tab === */

		o = s.taboption('advanced', form.Value, 'mtu',
			_('MTU'),
			_('Tunnel MTU. Default 1460 leaves 40 bytes for IPv6 encapsulation overhead.'));
		o.placeholder = '1460';
		o.datatype = 'range(576, 1500)';
		o.optional = true;

		o = s.taboption('advanced', form.ListValue, 'encaplimit',
			_('Encapsulation limit'),
			_('IPv6 tunnel encap limit. Most Japanese ISPs require <code>none</code>.'));
		o.value('none');
		o.value('0');
		o.optional = true;

		o = s.taboption('advanced', form.Flag, 'legacy_mssfix',
			_('Clamp TCP MSS'),
			_('Add TCPMSS --clamp-mss-to-pmtu on FORWARD to avoid PMTU black holes. Recommended.'));
		o.default = '1';

		o = s.taboption('advanced', form.ListValue, 'snat_mode',
			_('SNAT mode'),
			_('Default <code>statistic</code> matches the reference mape.sh. <code>fullconenat</code> ' +
			  'requires kmod-ipt-fullconenat and improves NAT for games / WebRTC / Rustdesk.'));
		o.value('statistic');
		o.value('fullconenat');
		o.default = 'statistic';

		o = s.taboption('advanced', form.Flag, 'icmp_use_first_set',
			_('SNAT ICMP via first port set'),
			_('Use the first PSID-allocated port range as ICMP identifier range. ' +
			  'Required by most BRs to accept ICMP echo replies.'));
		o.default = '1';

		o = s.taboption('advanced', form.Value, 'rule',
			_('ISP rule override'),
			_('Force a specific rule from rules.json instead of auto-detecting (e.g. <code>biglobe-a-2404-7a80</code>). ' +
			  'Leave empty for auto.'));
		o.placeholder = 'auto';
		o.optional = true;

		/* === Manual override (in Advanced tab; for ISPs not in rules.json) === */

		o = s.taboption('advanced', form.Value, 'peeraddr',
			_('Manual: Border Relay (BR) IPv6 address'),
			_('For ISPs not in rules.json. Leave empty to use the BR from the matched rule.'));
		o.datatype = 'ip6addr';
		o.optional = true;

		o = s.taboption('advanced', form.Value, 'ip6prefix',
			_('Manual: Rule IPv6 prefix'));
		o.datatype = 'ip6addr';
		o.optional = true;

		o = s.taboption('advanced', form.Value, 'ip6prefixlen',
			_('Manual: Rule IPv6 prefix length'));
		o.datatype = 'range(0, 128)';
		o.optional = true;

		o = s.taboption('advanced', form.Value, 'ipaddr',
			_('Manual: Rule IPv4 prefix'));
		o.datatype = 'ip4addr';
		o.optional = true;

		o = s.taboption('advanced', form.Value, 'ip4prefixlen',
			_('Manual: Rule IPv4 prefix length'));
		o.datatype = 'range(0, 32)';
		o.optional = true;

		o = s.taboption('advanced', form.Value, 'ealen',
			_('Manual: EA bit length'));
		o.datatype = 'range(0, 48)';
		o.optional = true;

		o = s.taboption('advanced', form.Value, 'psidlen',
			_('Manual: PSID length'));
		o.datatype = 'range(0, 16)';
		o.optional = true;

		o = s.taboption('advanced', form.Value, 'offset',
			_('Manual: PSID offset'));
		o.datatype = 'range(0, 16)';
		o.optional = true;
	}
});
