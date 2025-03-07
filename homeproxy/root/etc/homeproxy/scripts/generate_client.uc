#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2023 ImmortalWrt.org
 */

'use strict';

import { readfile, writefile } from 'fs';
import { cursor } from 'uci';

import {
	executeCommand, isEmpty, strToBool, strToInt,
	removeBlankAttrs, validateHostname, validation,
	HP_DIR, RUN_DIR
} from 'homeproxy';

/* UCI config start */
const uci = cursor();

const uciconfig = 'homeproxy';
uci.load(uciconfig);

const uciinfra = 'infra',
      ucimain = 'config',
      ucicontrol = 'control';

const ucidnssetting = 'dns',
      ucidnsserver = 'dns_server',
      ucidnsrule = 'dns_rule';

const uciroutingsetting = 'routing',
      uciroutingnode = 'routing_node',
      uciroutingrule = 'routing_rule';

const ucinode = 'node';

const routing_mode = uci.get(uciconfig, ucimain, 'routing_mode') || 'bypass_mainland_china';

let wan_dns = executeCommand('ifstatus wan | jsonfilter -e \'@["dns-server"][0]\'');
if (wan_dns.exitcode === 0 && trim(wan_dns.stdout))
	wan_dns = trim(wan_dns.stdout);
else
	wan_dns = (routing_mode in ['proxy_mainland_china', 'global']) ? '208.67.222.222' : '114.114.114.114';

const dns_port = uci.get(uciconfig, uciinfra, 'dns_port') || '5333';

let main_node, main_udp_node, dedicated_udp_node, default_outbound, sniff_override = '1',
    dns_server, dns_default_strategy, dns_default_server, dns_disable_cache, dns_disable_cache_expire,
    direct_domain_list;

if (routing_mode !== 'custom') {
	main_node = uci.get(uciconfig, ucimain, 'main_node') || 'nil';
	main_udp_node = uci.get(uciconfig, ucimain, 'main_udp_node') || 'nil';
	dedicated_udp_node = !isEmpty(main_udp_node) && !(main_udp_node in ['same', main_node]);

	dns_server = uci.get(uciconfig, ucimain, 'dns_server');
	if (isEmpty(dns_server) || dns_server === 'wan')
		dns_server = wan_dns;

	direct_domain_list = trim(readfile(HP_DIR + '/resources/direct_list.txt'));
	if (direct_domain_list)
		direct_domain_list = split(direct_domain_list, /[\r\n]/);
} else {
	/* DNS settings */
	dns_default_strategy = uci.get(uciconfig, ucidnssetting, 'default_strategy');
	dns_default_server = uci.get(uciconfig, ucidnssetting, 'default_server');
	dns_disable_cache = uci.get(uciconfig, ucidnssetting, 'disable_cache');
	dns_disable_cache_expire = uci.get(uciconfig, ucidnssetting, 'disable_cache_expire');

	/* Routing settings */
	default_outbound = uci.get(uciconfig, uciroutingsetting, 'default_outbound') || 'nil';
	sniff_override = uci.get(uciconfig, uciroutingsetting, 'sniff_override');
}

const proxy_mode = uci.get(uciconfig, ucimain, 'proxy_mode') || 'redirect_tproxy',
      ipv6_support = uci.get(uciconfig, ucimain, 'ipv6_support') || '0',
      default_interface = uci.get(uciconfig, ucicontrol, 'bind_interface');

let self_mark, redirect_port, tproxy_port,
    tun_name, tun_addr4, tun_addr6, tun_mtu,
    tcpip_stack, endpoint_independent_nat;
if (match(proxy_mode, /redirect/)) {
	self_mark = uci.get(uciconfig, 'infra', 'self_mark') || '100';
	redirect_port = uci.get(uciconfig, 'infra', 'redirect_port') || '5331';
}
if (match(proxy_mode), /tproxy/)
	if (main_udp_node !== 'nil' || routing_mode === 'custom')
		tproxy_port = uci.get(uciconfig, 'infra', 'tproxy_port') || '5332';
if (match(proxy_mode), /tun/) {
	tun_name = uci.get(uciconfig, uciinfra, 'tun_name') || 'singtun0';
	tun_addr4 = uci.get(uciconfig, uciinfra, 'tun_addr4') || '172.19.0.1/30';
	tun_addr6 = uci.get(uciconfig, uciinfra, 'tun_addr6') || 'fdfe:dcba:9876::1/126';
	tun_mtu = uci.get(uciconfig, uciinfra, 'tun_mtu') || '9000';
	tcpip_stack = 'system';
	if (routing_mode === 'custom') {
		tcpip_stack = uci.get(uciconfig, uciroutingsetting, 'tcpip_stack') || 'system';
		endpoint_independent_nat = uci.get(uciconfig, uciroutingsetting, 'endpoint_independent_nat');
	}
}
/* UCI config end */

/* Config helper start */
function parse_port(strport) {
	if (type(strport) !== 'array' || isEmpty(strport))
		return null;

	let ports = [];
	for (let i in strport)
		push(ports, int(i));

	return ports;

}

function generate_outbound(node) {
	if (type(node) !== 'object' || isEmpty(node))
		return null;

	const outbound = {
		type: node.type,
		tag: 'cfg-' + node['.name'] + '-out',
		routing_mark: strToInt(self_mark),

		server: node.address,
		server_port: strToInt(node.port),

		username: node.username,
		password: node.password,

		/* Direct */
		override_address: node.override_address,
		override_port: strToInt(node.override_port),
		proxy_protocol: strToInt(node.proxy_protocol),
		/* Hysteria */
		up_mbps: strToInt(node.hysteria_down_mbps),
		down_mbps: strToInt(node.hysteria_down_mbps),
		obfs: node.hysteria_bofs_password,
		auth: (node.hysteria_auth_type === 'base64') ? node.hysteria_auth_payload : null,
		auth_str: (node.hysteria_auth_type === 'string') ? node.hysteria_auth_payload : null,
		recv_window_conn: strToInt(node.hysteria_recv_window_conn),
		recv_window: strToInt(node.hysteria_revc_window),
		disable_mtu_discovery: strToBool(node.hysteria_disable_mtu_discovery),
		/* Shadowsocks */
		method: node.shadowsocks_encrypt_method || node.shadowsocksr_encrypt_method,
		plugin: node.shadowsocks_plugin,
		plugin_opts: node.shadowsocks_plugin_opts,
		/* ShadowsocksR */
		protocol: node.shadowsocksr_protocol,
		protocol_param: node.shadowsocksr_protocol_param,
		obfs: node.shadowsocksr_obfs,
		obfs_param: node.shadowsocksr_obfs_param,
		/* ShadowTLS / Socks */
		version: (node.type === 'shadowtls') ? strToInt(node.shadowtls_version) : ((node.type === 'socks') ? node.socks_version : null),
		/* Tuic */
		uuid: node.uuid,
		congestion_control: node.tuic_congestion_control,
		udp_relay_mode: node.tuic_udp_relay_mode,
		udp_over_stream: strToBool(node.tuic_udp_over_stream),
		zero_rtt_handshake: strToBool(node.tuic_enable_zero_rtt),
		heartbeat: node.tuic_heartbeat ? (node.tuic_heartbeat + 's') : null,
		/* VLESS / VMess */
		flow: node.vless_flow,
		alter_id: strToInt(node.vmess_alterid),
		security: node.vmess_encrypt,
		global_padding: node.vmess_global_padding ? (node.vmess_global_padding === '1') : null,
		authenticated_length: node.vmess_authenticated_length ? (node.vmess_authenticated_length === '1') : null,
		packet_encoding: node.packet_encoding,
		/* WireGuard */
		system_interface: (node.type === 'wireguard') || null,
		interface_name: (node.type === 'wireguard') ? 'singwg-cfg-' + node['.name'] + '-out' : null,
		local_address: node.wireguard_local_address,
		private_key: node.wireguard_private_key,
		peer_public_key: node.wireguard_peer_public_key,
		pre_shared_key: node.wireguard_pre_shared_key,
		reserved: parse_port(node.wireguard_reserved),
		mtu: strToInt(node.wireguard_mtu),

		multiplex: (node.multiplex === '1') ? {
			enabled: true,
			protocol: node.multiplex_protocol,
			max_connections: strToInt(node.multiplex_max_connections),
			min_streams: strToInt(node.multiplex_min_streams),
			max_streams: strToInt(node.multiplex_max_streams),
			padding: (node.multiplex_padding === '1')
		} : null,
		tls: (node.tls === '1') ? {
			enabled: true,
			server_name: node.tls_sni,
			insecure: (node.tls_insecure === '1'),
			alpn: node.tls_alpn,
			min_version: node.tls_min_version,
			max_version: node.tls_max_version,
			cipher_suites: node.tls_cipher_suites,
			certificate_path: node.tls_cert_path,
			ech: (node.enable_ech === '1') ? {
				enabled: true,
				dynamic_record_sizing_disabled: (node.tls_ech_tls_disable_drs === '1'),
				pq_signature_schemes_enabled: (node.tls_ech_enable_pqss === '1'),
				config: node.tls_ech_config
			} : null,
			utls: !isEmpty(node.tls_utls) ? {
				enabled: true,
				fingerprint: node.tls_utls
			} : null,
			reality: (node.tls_reality === '1') ? {
				enabled: true,
				public_key: node.tls_reality_public_key,
				short_id: node.tls_reality_short_id
			} : null
		} : null,
		transport: !isEmpty(node.transport) ? {
			type: node.transport,
			host: node.http_host,
			path: node.http_path || node.ws_path,
			headers: node.ws_host ? {
				Host: node.ws_host
			} : null,
			method: node.http_method,
			max_early_data: strToInt(node.websocket_early_data),
			early_data_header_name: node.websocket_early_data_header,
			service_name: node.grpc_servicename,
			idle_timeout: node.http_idle_timeout ? (node.http_idle_timeout + 's') : null,
			ping_timeout: node.http_ping_timeout ? (node.http_ping_timeout + 's') : null,
			permit_without_stream: strToBool(node.grpc_permit_without_stream)
		} : null,
		udp_over_tcp: (node.udp_over_tcp === '1') ? {
			enabled: true,
			version: strToInt(node.udp_over_tcp_version)
		} : null,
		tcp_fast_open: strToBool(node.tcp_fast_open),
		tcp_multi_path: strToBool(node.tcp_multi_path),
		udp_fragment: strToBool(node.udp_fragment)
	};

	return outbound;
}

function get_outbound(cfg) {
	if (isEmpty(cfg))
		return null;

	if (cfg in ['direct-out', 'block-out'])
		return cfg;
	else {
		const node = uci.get(uciconfig, cfg, 'node');
		if (isEmpty(node))
			die(sprintf("%s's node is missing, please check your configuration.", cfg));
		else
			return 'cfg-' + node + '-out';
	}
}

function get_resolver(cfg) {
	if (isEmpty(cfg))
		return null;

	if (cfg in ['default-dns', 'block-dns'])
		return cfg;
	else
		return 'cfg-' + cfg + '-dns';
}
/* Config helper end */

const config = {};

/* Log */
config.log = {
	disabled: false,
	level: 'warn',
	output: RUN_DIR + '/sing-box-c.log',
	timestamp: true
};

/* DNS start */
/* Default settings */
config.dns = {
	servers: [
		{
			tag: 'default-dns',
			address: wan_dns,
			detour: 'direct-out'
		},
		{
			tag: 'block-dns',
			address: 'rcode://name_error'
		}
	],
	rules: [],
	strategy: dns_default_strategy,
	disable_cache: (dns_disable_cache === '1'),
	disable_expire: (dns_disable_cache_expire === '1')
};

if (!isEmpty(main_node)) {
	/* Avoid DNS loop */
	const main_node_addr = uci.get(uciconfig, main_node, 'address');
	if (validateHostname(main_node_addr))
		push(config.dns.rules, {
			domain: main_node_addr,
			server: 'default-dns'
		});

	if (dedicated_udp_node) {
		const main_udp_node_addr = uci.get(uciconfig, main_udp_node, 'address');
		if (validateHostname(main_udp_node_addr))
			push(config.dns.rules, {
				domain: main_udp_node_addr,
				server: 'default-dns'
			});
	}

	if (direct_domain_list)
		push(config.dns.rules, {
			domain_keyword: direct_domain_list,
			server: 'default-dns'
		});

	if (isEmpty(config.dns.rules))
		config.dns.rules = null;

	let default_final_dns = 'default-dns';
	/* Main DNS */
	if (dns_server !== wan_dns) {
		push(config.dns.servers, {
			tag: 'main-dns',
			address: 'tcp://' + (validation('ip6addr', dns_server) ? `[${dns_server}]` : dns_server),
			strategy: (ipv6_support !== '1') ? 'ipv4_only' : null,
			detour: 'main-out'
		});

		default_final_dns = 'main-dns';
	}

	config.dns.final = default_final_dns;
} else if (!isEmpty(default_outbound)) {
	/* DNS servers */
	uci.foreach(uciconfig, ucidnsserver, (cfg) => {
		if (cfg.enabled !== '1')
			return;

		push(config.dns.servers, {
			tag: 'cfg-' + cfg['.name'] + '-dns',
			address: cfg.address,
			address: cfg.address,
			address_resolver: get_resolver(cfg.address_resolver),
			address_strategy: cfg.address_strategy,
			strategy: cfg.resolve_strategy,
			detour: get_outbound(cfg.outbound)
		});
	});

	/* DNS rules */
	uci.foreach(uciconfig, ucidnsrule, (cfg) => {
		if (cfg.enabled !== '1')
			return;

		push(config.dns.rules, {
			invert: cfg.invert,
			network: cfg.network,
			protocol: cfg.protocol,
			domain: cfg.domain,
			domain_suffix: cfg.domain_suffix,
			domain_keyword: cfg.domain_keyword,
			domain_regex: cfg.domain_regex,
			geosite: cfg.geosite,
			source_geoip: cfg.source_geoip,
			source_ip_cidr: cfg.source_ip_cidr,
			source_port: parse_port(cfg.source_port),
			source_port_range: cfg.source_port_range,
			port: parse_port(cfg.port),
			port_range: cfg.port_range,
			process_name: cfg.process_name,
			process_path: cfg.process_path,
			user: cfg.user,
			invert: (cfg.invert === '1'),
			outbound: get_outbound(cfg.outbound),
			server: get_resolver(cfg.server),
			disable_cache: (cfg.dns_disable_cache === '1')
		});
	});

	if (isEmpty(config.dns.rules))
		config.dns.rules = null;

	config.dns.final = get_resolver(dns_default_server);
}
/* DNS end */

/* Inbound start */
config.inbounds = [];

push(config.inbounds, {
	type: 'direct',
	tag: 'dns-in',
	listen: '::',
	listen_port: int(dns_port)
});

if (match(proxy_mode, /redirect/))
	push(config.inbounds, {
		type: 'redirect',
		tag: 'redirect-in',

		listen: '::',
		listen_port: int(redirect_port),
		sniff: true,
		sniff_override_destination: (sniff_override === '1')
	});
if (match(proxy_mode, /tproxy/))
	push(config.inbounds, {
		type: 'tproxy',
		tag: 'tproxy-in',

		listen: '::',
		listen_port: int(tproxy_port),
		network: 'udp',
		sniff: true,
		sniff_override_destination: (sniff_override === '1')
	});
if (match(proxy_mode, /tun/))
	push(config.inbounds, {
		type: 'tun',
		tag: 'tun-in',

		interface_name: tun_name,
		inet4_address: tun_addr4,
		inet6_address: (ipv6_support === '1') ? tun_addr6 : null,
		mtu: strToInt(tun_mtu),
		auto_route: false,
		endpoint_independent_nat: strToBool(endpoint_independent_nat),
		stack: tcpip_stack,
		sniff: true,
		sniff_override_destination: (sniff_override === '1'),
	});
/* Inbound end */

/* Outbound start */
/* Default outbounds */
config.outbounds = [
	{
		type: 'direct',
		tag: 'direct-out',
		routing_mark: strToInt(self_mark)
	},
	{
		type: 'block',
		tag: 'block-out'
	},
	{
		type: 'dns',
		tag: 'dns-out'
	}
];

/* Main outbounds */
if (!isEmpty(main_node)) {
	const main_node_cfg = uci.get_all(uciconfig, main_node) || {};
	push(config.outbounds, generate_outbound(main_node_cfg));
	config.outbounds[length(config.outbounds)-1].tag = 'main-out';

	if (dedicated_udp_node) {
		const main_udp_node_cfg = uci.get_all(uciconfig, main_udp_node) || {};
		push(config.outbounds, generate_outbound(main_udp_node_cfg));
		config.outbounds[length(config.outbounds)-1].tag = 'main-udp-out';
	}
} else if (!isEmpty(default_outbound))
	uci.foreach(uciconfig, uciroutingnode, (cfg) => {
		if (cfg.enabled !== '1')
			return;

		const outbound = uci.get_all(uciconfig, cfg.node) || {};
		push(config.outbounds, generate_outbound(outbound));
		config.outbounds[length(config.outbounds)-1].domain_strategy = cfg.domain_strategy;
		config.outbounds[length(config.outbounds)-1].bind_interface = cfg.bind_interface;
		config.outbounds[length(config.outbounds)-1].detour = get_outbound(cfg.outbound);
	});
/* Outbound end */

/* Routing rules start */
/* Default settings */
config.route = {
	geoip: !isEmpty(default_outbound) ? {
		path: HP_DIR + '/resources/geoip.db',
		download_url: 'https://github.com/1715173329/sing-geoip/releases/latest/download/geoip.db',
		download_detour: get_outbound(default_outbound)
	} : null,
	geosite: !isEmpty(default_outbound) ? {
		path: HP_DIR + '/resources/geosite.db',
		download_url: 'https://github.com/1715173329/sing-geosite/releases/latest/download/geosite.db',
		download_detour: get_outbound(default_outbound)
	} : null,
	rules: [
		{
			inbound: 'dns-in',
			outbound: 'dns-out'
		},
		{
			protocol: 'dns',
			outbound: 'dns-out'
		}
	],
	auto_detect_interface: isEmpty(default_interface) ? true : null,
	default_interface: default_interface
};

/* Routing rules */
if (!isEmpty(main_node)) {
	/* Direct list */
	if (length(direct_domain_list))
		push(config.route.rules, {
			domain_keyword: direct_domain_list,
			outbound: 'direct-out'
		});

	/* Main UDP out */
	if (dedicated_udp_node)
		push(config.route.rules, {
			network: 'udp',
			outbound: 'main-udp-out'
		});

	config.route.final = 'main-out';
} else if (!isEmpty(default_outbound)) {
	uci.foreach(uciconfig, uciroutingrule, (cfg) => {
		if (cfg.enabled !== '1')
			return null;

		push(config.route.rules, {
			invert: cfg.invert,
			ip_version: cfg.ip_version,
			network: cfg.network,
			protocol: cfg.protocol,
			domain: cfg.domain,
			domain_suffix: cfg.domain_suffix,
			domain_keyword: cfg.domain_keyword,
			domain_regex: cfg.domain_regex,
			geosite: cfg.geosite,
			source_geoip: cfg.source_geoip,
			geoip: cfg.geoip,
			source_ip_cidr: cfg.source_ip_cidr,
			ip_cidr: cfg.ip_cidr,
			source_port: parse_port(cfg.source_port),
			source_port_range: cfg.source_port_range,
			port: parse_port(cfg.port),
			port_range: cfg.port_range,
			process_name: cfg.process_name,
			process_path: cfg.process_path,
			user: cfg.user,
			invert: (cfg.invert === '1'),
			outbound: get_outbound(cfg.outbound)
		});
	});

	config.route.final = get_outbound(default_outbound);
}
/* Routing rules end */

system('mkdir -p ' + RUN_DIR);
writefile(RUN_DIR + '/sing-box-c.json', sprintf('%.J\n', removeBlankAttrs(config)));
