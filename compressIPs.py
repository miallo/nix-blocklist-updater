import ipaddress
import sys


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def is_valid_cidr(cidr):
    try:
        ipaddress.ip_network(cidr)
        return True
    except ValueError:
        eprint("Skipping invalid line: {}".format(cidr))
        return False


# Merges duplicate, overlapping and adjacent networks (including
# subnets/supernets) in a single pass over the sorted list.
def merge_cidr_range(networks):
    merged = list(ipaddress.collapse_addresses(sorted(networks)))
    eprint("compressed {} IPs down to {}".format(len(networks), len(merged)))
    for net in merged:
        print(str(net))


cidr_list = [line.strip() for line in sys.stdin.read().split('\n') if line.strip()]

# split by parsed address family: entries like ::ffff:1.2.3.4 contain both
# '.' and ':' and must not be classified into two families at once
networks = [ipaddress.ip_network(cidr) for cidr in cidr_list if is_valid_cidr(cidr)]
for version in (4, 6):
    merge_cidr_range([n for n in networks if n.version == version])
