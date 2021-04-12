##! This script detects a large number of ICMP Time Exceeded messages heading
##! toward hosts that have sent low TTL packets. It generates a notice when the
##! number of ICMP Time Exceeded messages for a source-destination pair exceeds
##! a threshold.

##@load base/frameworks/signatures
## @load-sigs ./detect-low-ttls.sig

redef Signatures::ignored_ids += /traceroute-detector.*/;

module Tracedroute;

export {
    redef enum Log::ID += { LOG };

    redef enum Notice::Type += {
        ## Indicates that a host was seen running traceroutes.  For more
        ## detail about specific traceroutes that we run, refer to the
        ## traceroute.log.
        Detected
    };

    ## By default this script requires that any host detected running
    ## traceroutes first send low TTL packets (TTL < 10) to the traceroute
    ## destination host.  Changing this setting to F will relax the
    ## detection a bit by solely relying on ICMP time-exceeded messages to
    ## detect traceroute.
    const require_low_ttl_packets = T &redef;

    ## Defines the threshold for ICMP Time Exceeded messages for a src-dst
    ## pair.  This threshold only comes into play after a host is found to
    ## be sending low TTL packets.
    const icmp_time_exceeded_threshold: double = 1 &redef;

    ## Interval at which to watch for the
    ## :zeek:id:`Traceroute::icmp_time_exceeded_threshold` variable to be
    ## crossed.  At the end of each interval the counter is reset.
    const icmp_time_exceeded_interval = 3min &redef;

    ## The log record for the traceroute log.
    type Info: record {
        ## Address initiating the traceroute.
        originator:   addr &log;
        ## Destination address of the traceroute.
        dst:   addr &log;
        ## Protocol used for the traceroute.
        proto: string &log;

        ## extra bonus!
        emitter: addr &log;
        ttl: count &log;
    };

    global log_traceroute: event(rec: Tracedroute::Info);

    type TrackedResponse: record {
        resp_ip: addr;
        reached_dst: bool &optional;
    };

    type TrackedRequest: record {
        ttl_out: count;
    };

    type TrackedRoute: record {
        dst: addr &log;
        originator: addr &log;
        saw_unreached: bool &log &optional;

        proto: string &optional; # Just UDP for now
        t_resp_tbl: table[port] of TrackedResponse;
        t_req_tbl:  table[port] of TrackedRequest;
    };

    global icmp_traceroute_tbl: table[string] of TrackedRoute;
    global log_tracedroutes: function(icmp_tbl: table[string] of TrackedRoute);
}

event zeek_init() &priority=5
{
    Log::create_stream(Tracedroute::LOG, [$columns=Info, $ev=log_traceroute, $path="tracedroute"]);
}

function log_tracedroutes(icmp_tbl: table[string] of TrackedRoute) {
    for (t in icmp_tbl) {
        local v : vector of set[addr] = vector();
        local i = 0;
        while (i < 10) {
            v[i] = set();
            i += 1;
        }

        local r = icmp_tbl[t];
        if (|r$t_resp_tbl| > 2 && |r$t_req_tbl| > 2) {
            for (p in r$t_resp_tbl) {
                if (p !in r$t_req_tbl) {
                    ;
                } else {
                    local tresp = r$t_resp_tbl[p];
                    local treq = r$t_req_tbl[p];
                    local s = v[treq$ttl_out];
                    add s[tresp$resp_ip];
                }
            }

            for (j in v) {
                for (emit_addr in v[j]) {
                    local tr_info = [
                        $originator=r$originator,
                        $dst=r$dst,
                        $proto="udp",
                        $emitter=emit_addr,
                        $ttl=j
                    ];
                    Log::write(Tracedroute::LOG, tr_info);
                }
            }
        }
    }
}

# event raw_packet(p: raw_pkt_hdr)
# {
#     # TODO figure out why some packet captures do not fire signature-detect
#     # but still have low ttls da @nskelsey del passato, baci e abbracci!
#     # TODO
#     if (p$ip$ttl < 10) {
#         print "raw-pkt", p$ip$ttl;
#     }
#
# }


# Low TTL packets are detected with a signature.
event signature_match(state: signature_state, msg: string, data: string)
{
    if ( state$sig_id == /traceroute-detector.*/ )
    {
       # print msg;
        local s = cat(state$conn$id$orig_h,"-",state$conn$id$resp_h,"-",get_port_transport_proto(state$conn$id$resp_p));

        local p_hdr  = get_current_packet_header();
        local p = get_current_packet();

        #print "sig detect match", s, p_hdr$ip$ttl, state$conn$id$orig_p;

        if (!p_hdr?$ip) {
            return;
        }

        local tr : TrackedRoute;
        local tmp_req_tbl : table[port] of TrackedRequest;
        local tmp_resp_tbl : table[port] of TrackedResponse;
        if (s !in icmp_traceroute_tbl) {
            tr = [$originator=state$conn$id$orig_h, $dst=state$conn$id$resp_h, $t_resp_tbl=tmp_resp_tbl, $t_req_tbl=tmp_req_tbl];
            icmp_traceroute_tbl[s] = tr;
        } else {
            tr = icmp_traceroute_tbl[s];
        }

        local udp_port = state$conn$id$orig_p;

        local t_req : TrackedRequest;
        if (udp_port !in tr$t_req_tbl) {
          t_req = [$ttl_out=p_hdr$ip$ttl];
          tr$t_req_tbl[udp_port] = t_req;
        } else {
          print "t_req already seen:", s, udp_port, t_req;
        }
    }
}

event icmp_time_exceeded(c: connection, icmp: icmp_conn, code: count, context: icmp_context)
{
    local s = cat(context$id$orig_h,"-",context$id$resp_h,"-",get_port_transport_proto(context$id$resp_p));

    local p_hdr  = get_current_packet_header();
    local p = get_current_packet();

    if (!p_hdr?$ip) {
        return;
    }

    #print "icmp_time_exceeded", s, icmp$orig_h, p_hdr$ip$ttl, c$id$resp_p, context$id$orig_p;
    local tr : TrackedRoute;
    local tmp_req_tbl : table[port] of TrackedRequest;
    local tmp_resp_tbl : table[port] of TrackedResponse;
    if (s !in icmp_traceroute_tbl) {
        tr = [$originator=context$id$orig_h, $dst=context$id$resp_h, $t_resp_tbl=tmp_resp_tbl, $t_req_tbl=tmp_req_tbl];
        icmp_traceroute_tbl[s] = tr;
    } else {
        tr = icmp_traceroute_tbl[s];
    }

    local udp_port = context$id$orig_p;

    local t_resp : TrackedResponse;
    if (udp_port !in tr$t_resp_tbl) {
      t_resp = [$resp_ip=icmp$orig_h];
      tr$t_resp_tbl[udp_port] = t_resp;
    } else {
      print "t_resp already seen:", s, udp_port, t_resp;
    }

}

event icmp_unreachable(c: connection, icmp: icmp_conn, code: count, context: icmp_context)
{
    local s = cat(context$id$orig_h,"-",context$id$resp_h,"-",get_port_transport_proto(context$id$resp_p));

    local tr : TrackedRoute;
    if (s in icmp_traceroute_tbl) {
        tr = icmp_traceroute_tbl[s];
    } else {
        print "saw icmp_unreachable but no req found", s;
    }

    local udp_port = context$id$orig_p;

    local t_resp : TrackedResponse;
    if (udp_port !in tr$t_resp_tbl) {
      t_resp = [$resp_ip=icmp$orig_h, $reached_dst=T];
      tr$t_resp_tbl[udp_port] = t_resp;
    } else {
      print "t_resp already seen:", s, udp_port, t_resp;
    }
}
