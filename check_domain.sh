#!/bin/sh
# Licensed under GPL v2 License
# Original Nagios script: https://github.com/glensc/nagios-plugin-check_domain
# Copyright (c) 2005 Tomàs Núñez Lirola <tnunez@criptos.com> (Original Author)
# Copyright (c) 2009-2016 Elan Ruusamäe <glen@pld-linux.org> (Maintainer)
# Zabbix adapted version: https://github.com/a-stoyanov/zabbix-domain-expiry (A.Stoyanov)
# 20/11/2023 - added '-s|--server' switch logic to accept empty quoted value ""
# 20/11/2023 - changed program exit output to align with zabbix template item pre-processing 

# fail on first error, do not continue
set -e

PROGRAM=${0##*/}
VERSION=1.8.0

STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

die() {
        # shellcheck disable=SC2039
        local rc="$1"
        # shellcheck disable=SC2039
        local msg="$2"
        echo "$msg"

        if [ "$rc" = 0 ]; then
                # remove outfile if not caching
                [ -z "$cache_dir" ] && rm -f "$outfile"
        else
                # always remove output even if caching to force re-check in case on errors
                rm -f "$outfile"
        fi

        exit "$rc"
}

# return true if argument is numeric
# http://stackoverflow.com/a/3951175/2314626
is_numeric() {
        case "$1" in
        ''|*[!0-9]*)
                return 1
                ;;
        esac
        return 0
}

version() {
        echo "check_domain - v$VERSION"
}

usage() {
        echo "Usage: $PROGRAM -h | -d <domain> [-c <critical>] [-w <warning>] [-P <path_to_whois>] [-s <server>]"
}

fullusage() {
        cat <<EOF
check_domain - v$VERSION
Original Nagios script: https://github.com/glensc/nagios-plugin-check_domain
Copyright (c) 2005 Tomàs Núñez Lirola <tnunez@criptos.com> (Original Author)
Copyright (c) 2009-2016 Elan Ruusamäe <glen@pld-linux.org> (Maintainer)
Zabbix adapted version: https://github.com/a-stoyanov/zabbix-domain-expiry (A.Stoyanov)

This script checks the expiration date of a domain name using the whois utility

Usage: $PROGRAM -h | -d <domain> [-c <critical>] [-w <warning>] [-P <path_to_whois>] [-s <server>]
NOTE: -d must be specified

Options:
-h, --help
     Print detailed help
-V, --version
     Print version information
-d, --domain
     Domain name to check
-w, --warning
     Response time to result in warning status (days)
-c, --critical
     Response time to result in critical status (days)
-P, --path
     Path to whois binary
-s, --server
     Specific Whois server for domain name check
-a, --cache-age
     How many days should each WHOIS lookup be cached for (default 0). Requires cache dir.
-C, --cache-dir
     Directory where to cache lookups

This plugin will use whois service to get the expiration date for the domain name.
Example:
     $PROGRAM -d domain.tld -w 30 -c 10

EOF
}

set_defaults() {
        # Default values (days):
        critical=7
        warning=30

        cache_age=0
        cache_dir=

        awk=${AWK:-awk}
}

# Parse command line arguments
parse_arguments() {
        # shellcheck disable=SC2039
        local args
        args=$(getopt -o hVd:w:c:P:s:a:C: --long help,version,domain:,warning:,critical:,path:,server:,cache-age:,cache-dir: -u -n "$PROGRAM" -- "$@")
        eval set -- "$args"

        while :; do
                case "$1" in
                -c|--critical)
                        shift
                        critical=$1
                ;;
                -w|--warning)
                        shift
                        warning=$1
                ;;
                -d|--domain)
                        shift
                        domain=$1
                ;;
                -P|--path)
                        shift
                        whoispath=$1
                ;;
                -s|--server)
                    if [ "$2" = "--" ]; then
                          shift
                          break
                        else
                          shift
                          server=$1
                    fi
                ;;
                -V|--version)
                        version
                        exit
                ;;
                -a|--cache-age)
                        shift
                        cache_age=$1
                ;;
                -C|--cache-dir)
                        shift
                        cache_dir=$1
                ;;
                -h|--help)
                        fullusage
                        exit
                ;;
                --)
                        shift
                        break
                ;;
                *)
                        die "$STATE_UNKNOWN" "State: UNKNOWN ; Internal error!"
                ;;
                esac
                shift
        done

        if [ -z "$domain" ]; then
                die "$STATE_UNKNOWN" "State: UNKNOWN ; There is no domain name to check"
        fi

        # validate cache args
        if [ -n "$cache_dir" ] && [ ! -d "$cache_dir" ]; then
                die "$STATE_UNKNOWN" "State: UNKNOWN ; Cache dir: '$cache_dir' does not exist"
        fi
        if [ -n "$cache_age" ] && ! is_numeric "$cache_age"; then
                die "$STATE_UNKNOWN" "State: UNKNOWN ; Cache age is not numeric: '$cache_age'"
        fi
        if [ -n "$cache_dir" ] && [ "$cache_age" -le 0 ]; then
                die "$STATE_UNKNOWN" "State: UNKNOWN ; Cache dir set, but age not"
        fi
}

# create temporary file. as secure as possible
# tempfile name is returned to stdout
temporary_file() {
        # shellcheck disable=SC2039
        # shellcheck disable=SC2169
        mktemp --tmpdir -t check_domainXXXXXX 2>/dev/null || echo "${TMPDIR:-/tmp}/check_domain.$RANDOM.$$"
}

# Looking for whois binary
setup_whois() {
        if [ -n "$whoispath" ]; then
                if [ -x "$whoispath" ]; then
                        whois=$whoispath
                elif [ -x "$whoispath/whois" ]; then
                        whois=$whoispath/whois
                fi
                [ -n "$whois" ] || die "$STATE_UNKNOWN" "State: UNKNOWN ; Unable to find whois binary, you specified an incorrect path"
        else
                # shellcheck disable=SC2039
                type whois > /dev/null 2>&1 || die "$STATE_UNKNOWN" "State: UNKNOWN ; Unable to find whois binary in your path. Is it installed? Please specify path."
                whois=whois
        fi
}

# Run whois(1)
run_whois() {
        # shellcheck disable=SC2039
        local error

        setup_whois

        $whois ${server:+-h $server} "$domain" > "$outfile" 2>&1 && error=$? || error=$?
        [ -s "$outfile" ] || die "$STATE_UNKNOWN" "State: UNKNOWN ; Domain $domain doesn't exist or no WHOIS server available."

        if grep -q -e "No match for" -e "NOT FOUND" -e "NO DOMAIN" "$outfile"; then
                die "$STATE_UNKNOWN" "State: UNKNOWN ; Domain $domain doesn't exist."
        fi

        # check for common errors
        if grep -q -e "Query rate limit exceeded. Reduced information." -e "WHOIS LIMIT EXCEEDED" "$outfile"; then
                die "$STATE_UNKNOWN" "State: UNKNOWN ; Rate limited WHOIS response"
        fi
        if grep -q -e "fgets: Connection reset by peer" "$outfile"; then
                error=0
        fi

        [ $error -eq 0 ] || die "$STATE_UNKNOWN" "State: UNKNOWN ; WHOIS exited with error $error."
}

# Calculate days until expiration from whois output
get_expiration() {
        # shellcheck disable=SC2039
        local outfile=$1

        # shellcheck disable=SC2016
        $awk '
        BEGIN {
                HH_MM_DD = "[0-9][0-9]:[0-9][0-9]:[0-9][0-9]"
                YYYY = "[0-9][0-9][0-9][0-9]"
                DD = "[0-9][0-9]"
                MON = "[A-Za-z][a-z][a-z]"
                DATE_DD_MM_YYYY_DOT = "[0-9][0-9]\\.[0-9][0-9]\\.[0-9][0-9][0-9][0-9]"
                DATE_DD_MON_YYYY = "[0-9][0-9]-[A-Za-z][a-z][a-z]-[0-9][0-9][0-9][0-9]"
                DATE_ISO_FULL = "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T"
                DATE_ISO_LIKE = "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] "
                DATE_YYYY_MM_DD_DASH = "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]"
                DATE_YYYY_MM_DD_DOT = "[0-9][0-9][0-9][0-9]\\.[0-9][0-9]\\.[0-9][0-9]"
                DATE_YYYY_MM_DD_SLASH = "[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]"
                DATE_DD_MM_YYYY_SLASH = "[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]"
                DATE_YYYY_MM_DD_NIL = "[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]"
                # 2015-10-03 13:36:48
                DATE_YYYY_MM_DD_DASH_HH_MM_SS = DATE_YYYY_MM_DD_DASH " " HH_MM_DD
                # 15.05.2016 13:36:48
                DATE_DD_MM_YYYY_DOT_HH_MM_SS = DATE_DD_MM_YYYY_DOT " " HH_MM_DD

                # Wed Mar 02 23:59:59 GMT 2016
                DATE_DAY_MON_DD_HHMMSS_TZ_YYYY = "[A-Z][a-z][a-z] [A-Z][a-z][a-z] [0-9][0-9] " HH_MM_DD " GMT " YYYY
                # 25-Apr-2018 16:00:50
                DATE_DD_MON_YYYY_HHMMSS = "[0-9][0-9]-" MON "-" YYYY " " HH_MM_DD
                # 02-May-2018 16:12:25 UTC
                DATE_DD_MON_YYYY_HHMMSS_TZ = "[0-9][0-9]-" MON "-" YYYY " " HH_MM_DD " UTC"
                # 2016.01.14 18:47:31
                DATE_YYYYMMDD_HHMMSS = DATE_YYYY_MM_DD_DOT " " HH_MM_DD
                # 21/05/2017 00:00:00 EEST
                DATE_DD_MM_YYYY_SLASH_HHMMSS_TZ = DATE_DD_MM_YYYY_SLASH " " HH_MM_DD " [A-Z]+"
                # 14 Jan 2016 22:40:29 UTC
                DATE_DD_MON_YYYY_HHMMSS_TZ_SPACE = "[0-9][0-9] " MON " " YYYY " " HH_MM_DD " UTC"
                # myname.pchome.com.tw date format: 2023-06-03 00:00:00 (UTC+8)
                DATE_YYYY_MM_DD_DASH_HH_MM_SS_TZ_SPACE_OFFSET = DATE_YYYY_MM_DD_DASH " " HH_MM_DD " ""\\(UTC\\+[0-9]+\\)"

                # 2007-02-28 11:48:53+02
                DATE_YYYY_MM_DD_DASH_HH_MM_SS_TZOFFSET = DATE_YYYY_MM_DD_DASH " " HH_MM_DD "\\+[0-9]+"
                split("january february march april may june july august september october november december", months, " ");
                for (i in months) {
                        mon = months[i]
                        Month[mon] = i;
                        mon = substr(mon, 1, 3)
                        Mon[mon] = i;
                }
        }

        # convert short month name to month number (Month Of Year)
        function mon2moy(month) {
                return Mon[tolower(month)]
        }

        # convert long month name to month number (Month Of Year)
        function month2moy(month) {
                return Month[tolower(month)]
        }

        # get date from DATE_ISO_FULL format from `s` using field separator `fs` from index `i` and exit
        function get_iso_date(s, fs, i,   a, d) {
                if (split(s, a, fs)) {
                        if (split(a[i], d, /T/)) {
                                print d[1];
                                exit;
                        }
                }
        }

        # Expiry date:  05-Dec-2014
        /Expir(y|ation) [Dd]ate:/ && $NF ~ DATE_DD_MON_YYYY {split($3, a, "-"); printf("%s-%s-%s\n", a[3], mon2moy(a[2]), a[1]); exit}

        # expires:      05-Dec-2014
        /expires:/ && $NF ~ DATE_DD_MON_YYYY {split($3, a, "-"); printf("%s-%s-%s\n", a[3], mon2moy(a[2]), a[1]); exit}

        # Expiry Date: 19/11/2015
        /Expiry Date:/ && $NF ~ DATE_DD_MM_YYYY_SLASH {split($3, a, "/"); printf("%s-%s-%s", a[3], a[2], a[1]); exit}

        # Expiration date: 16.11.2013 15:30:13
        /Expiration date:/ && $0 ~ DATE_DD_MM_YYYY_DOT_HH_MM_SS {split($(NF-1), a, "."); printf("%s-%s-%s", a[3], a[2], a[1]); exit}

        # Expire Date:  2015-10-22
        # expire-date:  2016-02-05
        /[Ee]xpire[- ][Dd]ate:/ && $NF ~ DATE_YYYY_MM_DD_DASH {print $NF; exit}

        # expires: 20170716
        /expires:/ && $NF ~ DATE_YYYY_MM_DD_NIL  {printf("%s-%s-%s", substr($2,0,4), substr($2,5,2), substr($2,7,2)); exit}

        # expires:      2015-11-18
        /expires:[ ]+/ && $NF ~ DATE_YYYY_MM_DD_DASH {print $NF; exit}

        # renewal date: 2016.01.14 18:47:31
        /renewal date:/ && $0 ~ DATE_YYYYMMDD_HHMMSS {split($(NF-1), a, "."); printf("%s-%s-%s", a[1], a[2], a[3]); exit}

        # paid-till: 2013.11.01
        /paid-till:/ && $NF ~ DATE_YYYY_MM_DD_DOT {split($2, a, "."); printf("%s-%s-%s", a[1], a[2], a[3]); exit}

        # paid-till: 2016-01-19
        /paid-till:/ && $NF ~ DATE_YYYY_MM_DD_DASH {print $NF; exit}

        # Valid Until: 2016-01-19
        /Valid Until:/ && $NF ~ DATE_YYYY_MM_DD_DASH {print $NF; exit}

        # expire: 16.11.2013
        /expire:/ && $NF ~ DATE_DD_MM_YYYY_DOT {split($2, a, "."); printf("%s-%s-%s", a[3], a[2], a[1]); exit}

        # expire: 2016-01-19
        /expire:/ && $NF ~ DATE_YYYY_MM_DD_DASH {print $NF; exit}

        # Expiration Date: 2017-01-26T10:14:11Z
        # Registrar Registration Expiration Date: 2015-02-22T00:00:00Z
        # Registrar Registration Expiration Date: 2015-01-11T23:00:00-07:00Z
        $0 ~ "Expiration Date: " DATE_ISO_FULL { get_iso_date($0, ":", 2) }

        # domain_datebilleduntil: 2015-01-11T23:00:00-07:00Z
        $0 ~ "billed[ ]*until: " DATE_ISO_FULL { get_iso_date($0, ":", 2) }

        # Registrar Registration Expiration Date: 2018-09-21 00:00:00 -0400
        $0 ~ "Expiration Date: " DATE_ISO_LIKE { get_iso_date($0, ":", 2) }

        # Data de expiração / Expiration Date (dd/mm/yyyy): 18/01/2016
        $0 ~ "Expiration Date .dd/mm/yyyy" {split($NF, a, "/"); printf("%s-%s-%s", a[3], a[2], a[1]); exit}

        # Domain Expiration Date: Wed Mar 02 23:59:59 GMT 2016
        $0 ~ "Expiration Date: *" DATE_DAY_MON_DD_HHMMSS_TZ_YYYY {
                printf("%s-%s-%s", $9, mon2moy($5), $6);
        }

        # Expiration Date:02-May-2018 16:12:25 UTC
        $0 ~ "Expiration Date: *" DATE_DD_MON_YYYY_HHMMSS_TZ {
                sub(/^.*Expiration Date: */, "")
                split($1, a, "-");
                printf("%s-%s-%s", a[3], mon2moy(a[2]), a[1]);
        }

        # .sg domains
        # Expiration Date:              25-Apr-2018 16:00:50
        # (uses tabs between colon and date, we match tabs or spaces regardless)
        $0 ~ "Expiration Date:[ \t]*" DATE_DD_MON_YYYY_HHMMSS {
                sub(/^.*Expiration Date:[ \t]*/, "")
                split($1, a, "-");
                printf("%s-%s-%s", a[3], mon2moy(a[2]), a[1]);
        }

        # Expiry Date: 14 Jan 2016 22:40:29 UTC
        $0 ~ "Expiry Date: *" DATE_DD_MON_YYYY_HHMMSS_TZ_SPACE {
                printf("%s-%s-%s", $5, mon2moy($4), $3);
        }

        # myname.pchome.com.tw
        # Record expires on 2023-06-03 00:00:00 (UTC+8)
        $0 ~ "Record expires on " DATE_YYYY_MM_DD_DASH_HH_MM_SS_TZ_SPACE_OFFSET {
           split($0, a, " "); printf a[4];
           exit;
        }

        # Registry Expiry Date: 2015-08-03T04:00:00Z
        # Registry Expiry Date: 2017-01-26T10:14:11Z
        $0 ~ "Expiry Date: " DATE_ISO_FULL {split($0, a, ":"); s = a[2]; if (split(s,d,/T/)) print d[1]; exit}

        # Expiry date: 2017/07/16
        /Expiry date:/ && $NF ~ DATE_YYYY_MM_DD_SLASH {split($3, a, "/"); printf("%s-%s-%s", a[1], a[2], a[3]); exit}

        # Expiry Date: 19/11/2015 00:59:58
        /Expiry Date:/ && $(NF-1) ~ DATE_DD_MM_YYYY_SLASH {split($3, a, "/"); printf("%s-%s-%s", a[3], a[2], a[1]); exit}

        # Expires: 2014-01-31
        # Expiry : 2014-03-08
        # Valid-date 2014-10-21
        /Valid-date|Expir(es|ation|y)/ && $NF ~ DATE_YYYY_MM_DD_DASH {print $NF; exit}

        # [Expires on] 2014/12/01
        /\[Expires on\]/ && $NF ~ DATE_YYYY_MM_DD_SLASH {split($3, a, "/"); printf("%s-%s-%s", a[1], a[2], a[3]); exit}

        # [State] Connected (2014/12/01)
        /\[State\]/ && $NF ~ DATE_YYYY_MM_DD_SLASH {gsub("[()]", "", $3); split($3, a, "/"); printf("%s-%s-%s", a[1], a[2], a[3]); exit}

        # expires at: 21/05/2017 00:00:00 EEST
        $0 ~ "expires at: *" DATE_DD_MM_YYYY_SLASH_HHMMSS_TZ {split($3, a, "/"); printf("%s-%s-%s", a[3], a[2], a[1]); exit}

        # Renewal Date: 2016-06-25
        $0 ~ "Renewal Date: *" DATE_YYYY_MM_DD { print($3); exit}

        # Expiry Date: 31-03-2016
        $0 ~ "Expiry Date: *" DATE_DD_MM_YYYY {split($3, a, "-"); printf("%s-%s-%s", a[3], a[2], a[1]); exit}

        # .il domains
        # validity:     05-11-2022
        # .il domains registered at the dawn of Internet never expire...
        # validity:     N/A
        $0 ~ "validity: *" DATE_DD_MM_YYYY {if ($2 == "N/A") {print "2100-01-01"} else {split($2, a, "-"); printf("%s-%s-%s", a[3], a[2], a[1])}; exit}

        # Expired: 2015-10-03 13:36:48
        $0 ~ "Expired: *" DATE_YYYY_MM_DD_DASH_HH_MM_SS {split($2, a, "-"); printf("%s-%s-%s", a[1], a[2], a[3]); exit}

        # Expiration Time: 2015-10-03 13:36:48
        $0 ~ "Expiration Time: *" DATE_YYYY_MM_DD_DASH_HH_MM_SS {split($3, a, "-"); printf("%s-%s-%s", a[1], a[2], a[3]); exit}

        # .fi domains
        # expires............: 4.7.2017 13:36:48
        /^expires\.*: +[0-9][0-9]?\.[0-9][0-9]?\.[0-9][0-9][0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ {
                sub(/^expires\.*: +/, "")
                split($1, a, ".");
                printf("%s-%02d-%02d", a[3], a[2], a[1]);
                exit;
        }

        # .ua domain
        # expires: 2017-09-01 17:09:32+03
        $0 ~ "expires: *" DATE_YYYY_MM_DD_DASH_HH_MM_SS_TZOFFSET {split($2, a, "-"); printf("%s-%s-%s", a[1], a[2], a[3]); exit}
        # FIXME: XXX: weak patterns

        # .ar domains
        # expire:               2025-12-22 00:00:00
        # (uses tabs between colon and date, we match tabs or spaces regardless)
        $0 ~ "expire:[ \t]*" DATE_YYYY_MM_DD_HHMMSS {
                sub(/^.*expire:[ \t]*/, "")
                split($1, a, "-");
                printf("%s-%s-%s", a[1], a[2], a[3]);
        }

        # renewal: 31-March-2016
        /renewal:/{split($2, a, "-"); printf("%s-%s-%s\n", a[3], month2moy(a[2]), a[1]); exit}

        # expires: March 5 2014
        /expires:/{printf("%s-%s-%s\n", $4, month2moy($2), $3); exit}

        # Renewal date:
        # Monday 21st Sep 2015
        /Renewal date:/{renewal = 1; next}
        {if (renewal) { sub(/[^0-9]+/, "", $2); printf("%s-%s-%s", $4, mon2moy($3), $2); exit}}

        # paid-till:     2017-12-10T12:42:36Z
        /paid-till:/ && $NF ~ DATE_ISO_FULL {split($0, a, ":"); s = a[2]; if (split(s,d,/T/)) print d[1]; exit}
        ' "$outfile"
}

set_defaults
parse_arguments "$@"

if [ -n "$cache_dir" ]; then
        # we might consider whois server name in cache file
        outfile=$cache_dir/$domain

        # clean up cache file if it's outdated
        test -f "$outfile" && find "$outfile" -mtime "+$cache_age" -delete

        # run whois if cache is empty or missing
        test -s "$outfile" || run_whois
else
        outfile=$(temporary_file)
        run_whois
fi
expiration=$(get_expiration "$outfile")

# Trim leading and trailing whitespace
expiration=$(echo "$expiration" | xargs)

[ -z "$expiration" ] && die "$STATE_UNKNOWN" "State: UNKNOWN ; Unable to figure out expiration date for $domain Domain."

expseconds=$(date +%s --date="$expiration")
expdate=$(date +'%Y-%m-%d' --date="$expiration")
nowseconds=$(date +%s)
diffseconds=$((expseconds-nowseconds))
expdays=$((diffseconds/86400))

# Trigger alarms (if applicable) if the domain is not expired.
if [ $expdays -ge 0 ]; then
        [ $expdays -lt "$critical" ] && die "$STATE_CRITICAL" "State: CRITICAL ; Days left: $expdays ; Expire date: $expdate"
        [ $expdays -lt "$warning" ] && die "$STATE_WARNING" "State: WARNING ; Days left: $expdays ; Expire date: $expdate"

        # No alarms? Ok, everything is right.
        die "$STATE_OK" "State: OK ; Days left: $expdays ; Expire date: $expdate"
fi

# Trigger alarms if applicable in the case that $warning and/or $critical are negative
[ $expdays -lt "$critical" ] && die "$STATE_CRITICAL" "State: EXPIRED ; Days since expired: ${expdays#-} ; Expire date: $expdate"
[ $expdays -lt "$warning" ] && die "$STATE_WARNING" "State: EXPIRED ; Days since expired: ${expdays#-} ; Expire date: $expdate"
# No alarms? Ok, everything is right.
die "$STATE_OK" "State: EXPIRED ; Days since expired: ${expdays#-} ; Expire date: $expdate"
