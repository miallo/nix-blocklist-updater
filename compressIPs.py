import ipaddress
import sys

def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)

cidr_list = [ line.strip() for line in sys.stdin.read().strip().split('\n') if line.strip() ]

v4_list = [ ip for ip in cidr_list if "." in ip ]
v6_list = [ ip for ip in cidr_list if ":" in ip ]

if len(cidr_list) != len(v4_list) + len(v6_list):
    eprint("found strings neither containing '.' nor ':'")


# Expects a sorted list of ip_networks
def iterate_cidr_range(networks):
    if len(networks) <= 1:
        return networks
    merged_ranges = []
    current_range = networks[0]

    for next_range in networks[1:]:
        if next_range == current_range or next_range.subnet_of(current_range):
            # skip, because we already have it
            continue
        elif current_range.subnet_of(next_range):
            # no need to keep smaller old curr
            current_range = next_range
        # elif current_range.overlaps(next_range):
        #     supernet = current_range.supernet(new_prefix=current_range.prefixlen)
        #     current_range = ipaddress.ip_network(supernet)
        elif next(current_range.supernet().subnets()) == current_range and \
                current_range.prefixlen == next_range.prefixlen and \
                (current_range.broadcast_address + 1) == next_range.network_address:
            # consecutive blocks of the same prefixlen which can be parsed as
            # the next bigger supernet, because of least segnificant bit being
            # large enough
            current_range = current_range.supernet()
        else:
            merged_ranges.append(current_range)
            current_range = next_range

    merged_ranges.append(current_range)
    return merged_ranges

def is_valid_cidr(cidr):
    try:
        ipaddress.ip_network(cidr)
        return True
    except ValueError:
        eprint("Skipping invalid line: {}".format(cidr))
        return False

def merge_cidr_range(cidr_list):
    merged = iterate_cidr_range(sorted(ipaddress.ip_network(cidr) for cidr in cidr_list if is_valid_cidr(cidr)))

    for i in range(10):
        new_merged = iterate_cidr_range(merged)
        if new_merged == merged:
            break # fixpoint, so no further merging needed
        merged = new_merged

    eprint("compressed {} IPs down to {}".format(len(cidr_list), len(merged)))

    for ip in merged:
        print(str(ip))

merge_cidr_range(v4_list)
merge_cidr_range(v6_list)
