#!/bin/bash
set -euo pipefail

# Deploy the static website stack (S3 + CloudFront + Route53).
#
# Uses `cloudformation deploy` rather than `create-stack` so re-running against
# an existing stack updates it instead of erroring out.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"
TEMPLATE="$SCRIPT_DIR/static-website.yml"

require_tools aws jq

profile="$(ask "Enter AWS CLI Profile Name")"
validate_profile "$profile"
echo "Profile name is valid."

region="$(ask "Enter AWS Region for the S3 bucket (e.g. us-east-1)")"
app_domain_name="$(ask "Enter App Domain Name (e.g. app.domain.name)")"

# Resolve the zone from the domain rather than asking for a separate root
# domain and hoping the two agree.
hosted_zone_id="$(lookup_hosted_zone "$app_domain_name" "$profile")"
zone_name="$(hosted_zone_name "$hosted_zone_id" "$profile")"
domain_in_zone "$app_domain_name" "$zone_name" \
  || die "'$app_domain_name' is not inside hosted zone '$zone_name'."
echo "Hosted Zone: $zone_name ($hosted_zone_id)"

certificate_arn="$(ask "Enter Certificate ARN (from $CERT_REGION)")"
validate_certificate "$certificate_arn" "$app_domain_name" "$profile"

echo
echo "Site type:"
echo "  spa    - client-side router; 404s are served /index.html"
echo "  static - prerendered site (Hugo/Jekyll); real 404s stay 404"
site_type=""
while [ "$site_type" != "spa" ] && [ "$site_type" != "static" ]; do
  site_type="$(ask "Enter Site Type (spa/static)")"
done

stack_name="$(ask "Enter Stack Name")"

echo
echo "You have entered the following information:"
echo "  AWS CLI Profile Name: $profile"
echo "  AWS Region:           $region"
echo "  App Domain Name:      $app_domain_name"
echo "  Hosted Zone:          $zone_name ($hosted_zone_id)"
echo "  Certificate ARN:      $certificate_arn"
echo "  Site Type:            $site_type"
echo "  Stack Name:           $stack_name"
echo

if ! confirm; then
  echo "Operation cancelled by the user."
  exit 1
fi

# --no-fail-on-empty-changeset: without it an unchanged redeploy exits non-zero
# and `set -e` kills the script before the outputs below are ever printed.
aws cloudformation deploy \
  --stack-name "$stack_name" \
  --template-file "$TEMPLATE" \
  --parameter-overrides \
    AppDomainName="$app_domain_name" \
    HostedZoneId="$hosted_zone_id" \
    CertificateARN="$certificate_arn" \
    SiteType="$site_type" \
  --no-fail-on-empty-changeset \
  --tags "Name=$app_domain_name" \
  --region "$region" \
  --profile="$profile"

echo
echo "Stack outputs:"
aws cloudformation describe-stacks \
  --stack-name "$stack_name" --region "$region" --profile="$profile" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text \
  | awk -F'\t' '{ printf "  %-18s %s\n", $1, $2 }'

bucket="$(aws cloudformation describe-stacks \
  --stack-name "$stack_name" --region "$region" --profile="$profile" \
  --query "Stacks[0].Outputs[?OutputKey=='Bucket'].OutputValue" --output text)"
dist="$(aws cloudformation describe-stacks \
  --stack-name "$stack_name" --region "$region" --profile="$profile" \
  --query "Stacks[0].Outputs[?OutputKey=='DistributionId'].OutputValue" --output text)"

echo
echo "Next: upload your site."
echo "  ./deploy-content.sh ./dist $bucket $dist $profile $region"
