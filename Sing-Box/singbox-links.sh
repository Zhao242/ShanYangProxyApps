#!/bin/sh
# Debian / Alpine: export local sing-box links with jq and OpenSSL.
# Upload this single file to GitHub as UTF-8 with LF line endings.
set -eu

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }
need_value() { [ "$#" -ge 2 ] || die "$1 requires a value"; }

# Remember this downloaded file; stdin execution has no script file to remove.
script_path=''
case "${0##*/}" in
    sh|dash|ash|bash|busybox|-sh|-dash|-ash|-bash) ;;
    *)
        case "$0" in
            /*) script_path=$0 ;;
            *) script_path=$PWD/$0 ;;
        esac ;;
esac

config=''
host=''
ipv4=''
ipv6=''
name=$(hostname | cut -d . -f 1)
fingerprint=chrome
base64_output=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        -c|--config) need_value "$@"; config=$2; shift 2 ;;
        --host) need_value "$@"; host=$2; shift 2 ;;
        --ipv4) need_value "$@"; ipv4=$2; shift 2 ;;
        --ipv6) need_value "$@"; ipv6=$2; shift 2 ;;
        --name) need_value "$@"; name=$2; shift 2 ;;
        --fingerprint) need_value "$@"; fingerprint=$2; shift 2 ;;
        --base64) base64_output=1; shift ;;
        -h|--help)
            cat <<'HELP'
Usage: sh singbox-links.sh [options]
  -c, --config PATH   sing-box config.json (auto-detected if omitted)
  --host HOST        public domain or IP; skips public-IP detection
  --ipv4 IP          explicit IPv4; skips public-IP detection
  --ipv6 IP          explicit IPv6; may be combined with --ipv4
  --name NAME        node name prefix (default: server hostname)
  --fingerprint FP   Reality fingerprint (default: chrome)
  --base64           output a Base64 subscription
  -h, --help         show this help

Supports Shadowsocks and VLESS Reality over TCP. No Python or Bash required.
Missing jq / openssl / curl are installed using apt-get (Debian) or apk
(Alpine) when running as root. Reads configuration without changing services.
Deletes this script after successfully printing links. Keeps it on failure
or when displaying help.
HELP
            exit 0 ;;
        *) die "unknown argument: $1 (use --help)" ;;
    esac
done

if [ -n "$host" ] && { [ -n "$ipv4" ] || [ -n "$ipv6" ]; }; then
    die 'use --host OR --ipv4 / --ipv6'
fi

if [ -z "$config" ]; then
    for candidate in /etc/sing-box/config.json /usr/local/etc/sing-box/config.json \
        /etc/singbox/config.json /root/sbox/sb.json "$PWD/config.json"; do
        [ -f "$candidate" ] || continue
        if [ -n "$config" ] && [ "$config" != "$candidate" ]; then
            die "multiple configs found; select one with --config: $config ; $candidate"
        fi
        config=$candidate
    done
fi
[ -n "$config" ] || die 'config not found; use --config /path/to/config.json'
[ -f "$config" ] && [ -r "$config" ] || die "cannot read config: $config"

missing=''
for dependency in jq openssl curl; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        missing="$missing $dependency"
    fi
done
if [ -n "$missing" ]; then
    [ "$(id -u)" = 0 ] || die "missing:$missing. Run as root to install dependencies."
    [ -r /etc/os-release ] || die "cannot identify OS; install:$missing ca-certificates"
    . /etc/os-release
    case "${ID:-}" in
        debian)
            log "Installing dependencies with apt-get:$missing ca-certificates"
            apt-get update >&2
            # Intentional word splitting: package names come only from the fixed list above.
            DEBIAN_FRONTEND=noninteractive apt-get install -y $missing ca-certificates >&2 ;;
        alpine)
            log "Installing dependencies with apk:$missing ca-certificates"
            apk add --no-cache $missing ca-certificates >&2 ;;
        *) die 'automatic dependency installation supports Debian and Alpine only' ;;
    esac
fi

umask 077
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/singbox-links.XXXXXX") || die 'cannot create temporary directory'
cleanup() {
    # This directory contains only the flat files created by this invocation.
    rm -f "$temp_dir"/*
    rmdir "$temp_dir"
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

log "Reading config: $config"
if ! jq -e 'if type == "object" and (.inbounds | type == "array") then .
    else error("config must contain an inbounds array") end' "$config" > "$temp_dir/config.json"; then
    die 'cannot parse config; provide a complete, standard JSON config file'
fi

# Validate IP literals using jq, with no DNS lookup or external process per octet.
cat > "$temp_dir/ip.jq" <<'JQ'
def ipv4:
    split(".") as $a | ($a | length) == 4 and
    all($a[]; test("^(0|[1-9][0-9]{0,2})$") and (tonumber <= 255));
def hextets:
    if . == "" then [] else split(":") end;
def ipv6:
    . as $original |
    (if contains(".") then
        split(":")[-1] as $last |
        if ($last | ipv4) then sub("[0-9.]+$"; "0:0") else "!" end
    else . end) |
    if contains("::") then
        split("::") as $s |
        ($s | length) == 2 and
        (($s | map(hextets) | add) as $g |
            ($g | length) < 8 and all($g[]; test("^[0-9a-fA-F]{1,4}$")))
    else
        split(":") as $g |
        ($g | length) == 8 and all($g[]; test("^[0-9a-fA-F]{1,4}$"))
    end;
if $family == 4 then $ip | ipv4 else $ip | ipv6 end
JQ

valid_ip() {
    jq -ne --arg ip "$2" --argjson family "$1" -f "$temp_dir/ip.jq" >/dev/null 2>&1
}

if [ -n "$ipv4" ]; then valid_ip 4 "$ipv4" || die 'invalid --ipv4 address'; fi
if [ -n "$ipv6" ]; then
    ipv6=${ipv6#\[}; ipv6=${ipv6%\]}
    valid_ip 6 "$ipv6" || die 'invalid --ipv6 address'
fi
if [ -n "$host" ]; then
    host=${host#\[}; host=${host%\]}
    case "$host" in
        *:*) valid_ip 6 "$host" || die 'invalid IPv6 in --host' ;;
        *[!0-9.]*)
            case "$host" in
                *[!A-Za-z0-9.-]*|.*|-*|*..*|*-)
                    die '--host must be a domain or IP without a scheme, path or port' ;;
            esac ;;
        *) valid_ip 4 "$host" || die 'invalid IPv4 in --host' ;;
    esac
fi

detect_ip() {
    family=$1
    case "$family" in
        4) services='https://api4.ipify.org https://ipv4.icanhazip.com' ;;
        6) services='https://api6.ipify.org https://ipv6.icanhazip.com' ;;
    esac
    for service in $services; do
        # Ignore curlrc and proxy variables: query this server's direct egress IP.
        address=$(curl -q --noproxy '*' "-$family" -fsS --connect-timeout 3 --max-time 5 \
            "$service" 2>/dev/null) || address=''
        if [ -n "$address" ] && valid_ip "$family" "$address"; then
            printf '%s' "$address"
            return 0
        fi
    done
    return 1
}

if [ -z "$host" ] && [ -z "$ipv4" ] && [ -z "$ipv6" ]; then
    log 'Detecting server public IPv4 / IPv6...'
    detect_ip 4 > "$temp_dir/ipv4" & pid4=$!
    detect_ip 6 > "$temp_dir/ipv6" & pid6=$!
    wait "$pid4" || :
    wait "$pid6" || :
    ipv4=$(cat "$temp_dir/ipv4")
    ipv6=$(cat "$temp_dir/ipv6")
    [ -n "$ipv4$ipv6" ] || die 'IP detection failed; use --host DOMAIN_OR_IP or --ipv4 / --ipv6'
    [ -n "$ipv4" ] || log 'No IPv4 detected; omitting IPv4 links.'
    [ -n "$ipv6" ] || log 'No IPv6 detected; omitting IPv6 links.'
fi

# Derive each unique Reality public key once. Private keys never enter argv.
jq -r '[.inbounds[] | objects | select(.type == "vless") | .tls.reality |
    objects | select(.enabled == true) | .private_key |
    strings | select(length > 0)] | unique[]' "$temp_dir/config.json" > "$temp_dir/keys"
: > "$temp_dir/keymap.tsv"
while IFS= read -r private_key; do
    encoded=${private_key%=}
    case "$encoded" in *[!A-Za-z0-9_+/-]*|'')
        log 'Skipping malformed Reality private key.'; continue ;;
    esac
    if [ "${#encoded}" != 43 ]; then
        log 'Skipping Reality private key with invalid length.'; continue
    fi
    if ! printf '%s=' "$encoded" | tr '_-' '/+' | openssl base64 -d -A > "$temp_dir/key.raw" 2>/dev/null; then
        log 'Cannot decode Reality private key.'; continue
    fi
    if [ "$(wc -c < "$temp_dir/key.raw" | tr -d '[:space:]')" != 32 ]; then
        log 'Skipping Reality private key that is not 32 bytes.'; continue
    fi
    # RFC 8410 PKCS#8 DER prefix for a 32-byte X25519 private key.
    {
        printf '\060\056\002\001\000\060\005\006\003\053\145\156\004\042\004\040'
        cat "$temp_dir/key.raw"
    } > "$temp_dir/key.der"
    if ! openssl pkey -inform DER -in "$temp_dir/key.der" -pubout -outform DER \
        -out "$temp_dir/pub.der" 2>/dev/null; then
        log 'Cannot derive Reality public key; OpenSSL with X25519 support is required.'; continue
    fi
    if [ "$(wc -c < "$temp_dir/pub.der" | tr -d '[:space:]')" != 44 ]; then
        log 'Unexpected X25519 public-key encoding.'; continue
    fi
    public_key=$(tail -c 32 "$temp_dir/pub.der" | openssl base64 -A | tr '/+' '_-' | tr -d '=')
    [ "${#public_key}" = 43 ] || die 'cannot encode Reality public key'
    printf '%s\t%s\n' "$private_key" "$public_key" >> "$temp_dir/keymap.tsv"
done < "$temp_dir/keys"

# Generate all links in one jq invocation; shell never evaluates config text.
cat > "$temp_dir/links.jq" <<'JQ'
def str: if type == "string" then . else "" end;
def obj: if type == "object" then . else {} end;
def arr: if type == "array" then . else [] end;
def text_or($fallback): str | if length > 0 then . else $fallback end;
def skip($message): ("skip: " + $message + "\n" | stderr) | empty;
def family:
    if contains(":") then "v6"
    elif test("^[0-9.]+$") then "v4" else "" end;
def authority: if contains(":") then "[" + . + "]" else . end;
# Match urllib.parse.quote(..., safe="") used by the original parser.
def uri:
    @uri | gsub("!"; "%21") | gsub("'"; "%27") |
    gsub("\\("; "%28") | gsub("\\)"; "%29") | gsub("\\*"; "%2A");
def node_label($tag; $user; $family):
    [$name, $tag, $user, $family] | map(select(length > 0)) | join("-") | uri;
def query:
    map((.[0] | uri | gsub("%20"; "+")) + "=" +
        (.[1] | uri | gsub("%20"; "+"))) | join("&");

($keymap | split("\n") | map(select(length > 0) | split("\t") |
    {key: .[0], value: .[1]}) | from_entries) as $public_keys |
(if $host != "" then [{host: $host, family: ($host | family)}]
 else [{host: $ipv4, family: "v4"}, {host: $ipv6, family: "v6"}] |
    map(select(.host != "")) end) as $targets |
[
    .inbounds[] | objects | . as $in |
    if .type != "shadowsocks" and .type != "vless" then
        skip("unsupported inbound type: " + (.type | text_or("unknown")))
    elif (.listen_port | type) != "number" then skip("invalid listen_port")
    elif .listen_port < 1 or .listen_port > 65535 or (.listen_port | floor) != .listen_port then
        skip("invalid listen_port")
    elif .type == "shadowsocks" then
        (.tag | text_or("SS")) as $tag |
        (.method | str) as $method | (.password | str) as $server_password |
        $targets[] as $target |
        (if (.users | arr | length) > 0 then
            .users | to_entries[] | .key as $index | .value | objects |
            (.method | text_or($method)) as $m |
            (.password | str) as $p |
            {name: (.name | text_or("user" + (($index + 1) | tostring))), method: $m,
             password: (if ($m | startswith("2022-")) and $p != "" and $server_password != ""
                then $server_password + ":" + $p else $p end)}
         else {name: "", method: $method, password: $server_password} end) as $user |
        if $user.method == "" or $user.password == "" then skip("SS method / password missing")
        else
            # Preserve the original parser's padded standard Base64 for every SS method.
            ($user.method + ":" + $user.password | @base64) as $auth |
            $target | "ss://" + $auth + "@" + (.host | authority) + ":" +
                ($in.listen_port | tostring) + "#" + node_label($tag; $user.name; .family)
        end
    else
        (.tls | obj) as $tls | ($tls.reality | obj) as $reality |
        (.transport | obj) as $transport |
        if $tls.enabled != true or $reality.enabled != true then skip("VLESS without enabled Reality TLS")
        elif ($transport.type // "tcp") != "tcp" then skip("VLESS Reality non-TCP transport")
        else
            ($public_keys[($reality.private_key | str)] // "") as $pbk |
            ($tls.server_name | text_or($reality.handshake.server | str)) as $sni |
            ($reality.short_id | if type == "array" then .[0] else . end | str) as $sid |
            (.users | arr) as $users |
            (.tag | text_or("Reality")) as $tag |
            if $pbk == "" then skip("Reality public key unavailable")
            elif $sni == "" then skip("Reality server_name / handshake.server missing")
            else
                $targets[] as $target |
                $users | to_entries[] | .key as $index | .value | objects |
                (.uuid | str) as $uuid | (.flow | str) as $flow |
                (.name | text_or(if ($users | length) > 1 then "user" + (($index + 1) | tostring) else "" end)) as $user |
                if $uuid == "" then skip("VLESS UUID missing") else
                    ([ ["encryption", "none"] ] +
                        (if $flow != "" then [["flow", $flow]] else [] end) +
                        [["security", "reality"], ["sni", $sni], ["fp", $fingerprint], ["pbk", $pbk]] +
                        (if $sid != "" then [["sid", $sid]] else [] end) +
                        [["type", "tcp"], ["headerType", "none"]] | query) as $query |
                    $target | "vless://" + ($uuid | uri) + "@" + (.host | authority) + ":" +
                        ($in.listen_port | tostring) + "?" + $query + "#" + node_label($tag; $user; .family)
                end
            end
        end
    end
] | if length == 0 then error("no supported links generated") else .[] end
JQ

if ! jq -r --arg name "$name" --arg host "$host" --arg ipv4 "$ipv4" --arg ipv6 "$ipv6" \
    --arg fingerprint "$fingerprint" --rawfile keymap "$temp_dir/keymap.tsv" \
    -f "$temp_dir/links.jq" "$temp_dir/config.json" > "$temp_dir/links.txt"; then
    die 'link generation failed'
fi

if [ "$base64_output" = 1 ]; then
    # Match the original parser: encode joined links without a final newline.
    links_body=$(cat "$temp_dir/links.txt")
    printf '%s' "$links_body" | openssl base64 -A
    printf '\n'
else
    cat "$temp_dir/links.txt"
fi

# Reached only after link generation and output both succeed.
if [ -n "$script_path" ] && [ -f "$script_path" ]; then
    if rm -f -- "$script_path"; then
        log 'Done. Downloaded script deleted.'
    else
        log "warning: links generated, but could not delete script: $script_path"
    fi
fi
