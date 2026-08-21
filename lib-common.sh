#!/bin/bash
# Shared helpers for the deploy scripts. Sourced, not executed.

# CloudFront can only use certificates from us-east-1, regardless of where the
# website stack lives. This is a hard AWS constraint, not a preference.
readonly CERT_REGION="us-east-1"

die() { echo "ERROR: $*" >&2; exit 1; }

require_tools() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "'$t' is required but not installed."
  done
}

# Prompt until non-empty and echo the answer, so callers can write
#   x="$(ask "Enter X")"
# The prompt goes to stderr so command substitution captures only the answer.
ask() {
  local prompt="$1" reply=""
  while [ -z "$reply" ]; do
    printf '%s: ' "$prompt" >&2
    read -r reply
    [ -z "$reply" ] && echo "  (cannot be empty)" >&2
  done
  printf '%s\n' "$reply"
}

validate_profile() {
  aws sts get-caller-identity --profile="$1" >/dev/null 2>&1 \
    || die "Profile '$1' is invalid or unable to authenticate."
}

confirm() {
  local reply
  printf 'Do you want to proceed? (yes/no): '
  read -r reply
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Find the most specific PUBLIC hosted zone that is a DNS-suffix parent of the
# given domain. A cert for www.example.com is validated in the example.com zone,
# so an exact-name match is not enough. Private zones are excluded because they
# cannot serve public DNS validation records.
#
# Echoes the bare zone id. Dies if zero or more than one candidate matches.
lookup_hosted_zone() {
  local domain="$1" profile="$2" zones candidates count
  zones=$(aws route53 list-hosted-zones --profile="$profile" --output json) \
    || die "Could not list hosted zones."

  # Build "<name-without-trailing-dot> <id>" for public zones only, then keep
  # those that are a suffix of the domain, longest (most specific) first.
  candidates=$(printf '%s' "$zones" | jq -r '
    .HostedZones[]
    | select(.Config.PrivateZone == false)
    | "\(.Name | rtrimstr("."))\t\(.Id | sub("^/hostedzone/"; ""))"
  ' | awk -v d="$domain" '
    { n = $1
      if (d == n) { print length(n) "\t" $0; next }
      # d must END WITH "." n. Do not use index()==length-diff: index returns 0
      # when absent, which collides with a 0 length-diff and matches wrongly.
      suf = "." n
      if (length(d) > length(suf) && substr(d, length(d) - length(suf) + 1) == suf) {
        print length(n) "\t" $0
      }
    }' | sort -rn)

  [ -z "$candidates" ] && die "No public hosted zone found that is a parent of '$domain'."

  # Ambiguous only if two zones tie at the same (most specific) name length.
  local top_len
  top_len=$(printf '%s\n' "$candidates" | head -1 | cut -f1)
  count=$(printf '%s\n' "$candidates" | awk -F'\t' -v L="$top_len" '$1==L' | wc -l | tr -d ' ')
  if [ "$count" -ne 1 ]; then
    echo "Multiple public hosted zones match '$domain':" >&2
    printf '%s\n' "$candidates" | awk -F'\t' -v L="$top_len" '$1==L {print "  " $2 "  " $3}' >&2
    die "Ambiguous - re-run and supply the zone id explicitly."
  fi

  printf '%s\n' "$candidates" | head -1 | cut -f3
}

# The zone's own name, without the trailing dot.
hosted_zone_name() {
  aws route53 get-hosted-zone --id "$1" --profile="$2" \
    --query 'HostedZone.Name' --output text 2>/dev/null | sed 's/\.$//'
}

# True if $1 is inside DNS zone $2 (equal, or a subdomain of it).
domain_in_zone() {
  [ "$1" = "$2" ] || [ "${1%".$2"}" != "$1" ]
}

# A wildcard SAN covers exactly ONE label: *.example.com matches www.example.com
# but NOT a.b.example.com.
cert_covers_domain() {
  local domain="$1" name
  shift
  for name in "$@"; do
    [ "$name" = "$domain" ] && return 0
    if [ "${name#\*.}" != "$name" ]; then
      # NB: split declarations - in a single `local a=.. b=$a`, b does not
      # see a's new value.
      local base="${name#\*.}"
      local rest="${domain%".$base"}"
      # rest is the single remaining label if domain is exactly one level under base
      if [ "$rest" != "$domain" ] && [ -n "$rest" ] && [[ "$rest" != *.* ]]; then
        return 0
      fi
    fi
  done
  return 1
}

# An ARN regex cannot tell you the certificate is issued, in the right region,
# or actually covers the alias. Check the real thing.
validate_certificate() {
  local arn="$1" domain="$2" profile="$3" json status n
  local -a names
  case "$arn" in
    arn:*:acm:${CERT_REGION}:*) ;;
    *) die "Certificate must be in ${CERT_REGION} for CloudFront. Got: $arn" ;;
  esac

  json=$(aws acm describe-certificate --certificate-arn "$arn" \
           --region "$CERT_REGION" --profile="$profile" --output json 2>/dev/null) \
    || die "Could not describe certificate. Check the ARN and your permissions."

  status=$(printf '%s' "$json" | jq -r '.Certificate.Status')
  [ "$status" = "ISSUED" ] \
    || die "Certificate status is '$status', expected ISSUED. DNS validation may still be pending."

  # Portable read loop - mapfile is bash 4+, macOS still ships bash 3.2.
  names=()
  while IFS= read -r n; do
    [ -n "$n" ] && names+=("$n")
  done < <(printf '%s' "$json" | jq -r '
    [.Certificate.DomainName] + (.Certificate.SubjectAlternativeNames // []) | unique | .[]')

  cert_covers_domain "$domain" "${names[@]}" \
    || die "Certificate does not cover '$domain'. It covers: ${names[*]}
Note a wildcard matches only one label (*.example.com covers www.example.com, not a.b.example.com)."

  echo "Certificate OK: ISSUED in ${CERT_REGION}, covers ${domain}"
}
