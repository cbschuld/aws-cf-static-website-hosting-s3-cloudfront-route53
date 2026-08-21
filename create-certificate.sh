#!/bin/bash
set -euo pipefail

# Deploy the plain certificate stack.
#
# The region is NOT configurable: CloudFront can only attach certificates from
# us-east-1, no matter where the website stack itself lives. Letting the user
# pick a region here produces a certificate that fails much later, when the
# distribution is created.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"
TEMPLATE="$SCRIPT_DIR/certificate.yml"

require_tools aws jq

profile="$(ask "Enter AWS CLI Profile Name")"
validate_profile "$profile"
echo "Profile name is valid."

domain="$(ask "Enter Domain (e.g. example.com)")"

hosted_zone_id="$(lookup_hosted_zone "$domain" "$profile")"
zone_name="$(hosted_zone_name "$hosted_zone_id" "$profile")"
echo "Hosted Zone: $zone_name ($hosted_zone_id)"

stack_name="$(ask "Enter Stack Name")"

echo
echo "You have entered the following information:"
echo "  AWS CLI Profile Name: $profile"
echo "  Region:               $CERT_REGION (fixed - required by CloudFront)"
echo "  Domain:               $domain"

echo "  Hosted Zone:          $zone_name ($hosted_zone_id)"
echo "  Stack Name:           $stack_name"
echo

if ! confirm; then
  echo "Operation cancelled by the user."
  exit 1
fi

aws cloudformation deploy \
  --stack-name "$stack_name" \
  --template-file "$TEMPLATE" \
  --parameter-overrides \
    DomainName="$domain" \
    HostedZoneId="$hosted_zone_id" \
  --no-fail-on-empty-changeset \
  --region "$CERT_REGION" \
  --profile="$profile"

# `deploy` above already blocked until the stack reached CREATE_COMPLETE, and
# the ACM resource does not reach that state until DNS validation succeeds - so
# by this point the certificate is issued.
cert_arn="$(aws cloudformation describe-stacks \
  --stack-name "$stack_name" --region "$CERT_REGION" --profile="$profile" \
  --query "Stacks[0].Outputs[?OutputKey=='CertificateArn'].OutputValue" --output text)"

echo
echo "Certificate ARN: $cert_arn"
echo "Pass this to create-static-website.sh."
