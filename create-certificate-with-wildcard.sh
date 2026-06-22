#!/bin/bash
set -euo pipefail

# Deploy the CloudFormation template that lives next to this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/certificate-with-wildcard.yml"

echo "Enter AWS CLI Profile Name:"
read -r profile

# Validate AWS CLI Profile Name
if aws sts get-caller-identity --profile="$profile" > /dev/null 2>&1; then
  echo "Profile name is valid."
else
  echo "Profile name is invalid or unable to authenticate. Please check the profile name and credentials."
  exit 1
fi

echo "Enter AWS Region (e.g., us-east-1):"
read -r region

# Loop until a valid domain is entered
valid_domain=0
while [ $valid_domain -eq 0 ]; do
    echo "Enter Domain (without www):"
    read -r domain

    # Regex for a basic validation of a domain name (simplified)
    if [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$ ]]; then
        valid_domain=1
    else
        echo "Invalid domain format. Please enter a valid domain."
    fi
done

# Fetch HostedZoneId
hosted_zone_id=$(aws route53 list-hosted-zones-by-name --profile="$profile" | \
jq --arg name "$domain." -r '.HostedZones | .[] | select(.Name=="\($name)") | .Id')
hosted_zone_id=${hosted_zone_id#/hostedzone/}  # Remove '/hostedzone/' prefix

if [ -z "$hosted_zone_id" ]; then
  echo "Could not find Hosted Zone ID for the domain. Please check the domain name."
  exit 1
else
  echo "Hosted Zone ID: $hosted_zone_id"
fi

echo "Enter Stack Name:"
read -r stack_name

# Display all inputs for confirmation
echo "You have entered the following information:"
echo "AWS CLI Profile Name: $profile"
echo "AWS Region: $region"
echo "Domain: $domain"
echo "Hosted Zone ID: $hosted_zone_id"
echo "Stack Name: $stack_name"
echo "Do you want to proceed? (yes/no):"
read -r confirmation

if [[ "$confirmation" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
  # Execute the AWS command with the user-provided variables
  aws cloudformation create-stack --stack-name "$stack_name" \
  --template-body "file://$TEMPLATE" \
  --parameters \
  ParameterKey=DomainName,ParameterValue="$domain" \
  ParameterKey=HostedZoneId,ParameterValue="$hosted_zone_id" \
  --region "$region" \
  --profile="$profile"

  echo "Stack creation command executed."
else
  echo "Operation cancelled by the user."
  exit 1
fi
