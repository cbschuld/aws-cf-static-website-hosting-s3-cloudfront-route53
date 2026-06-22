#!/bin/bash
set -euo pipefail

# Deploy the CloudFormation template that lives next to this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/static-website.yml"

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

echo "Enter Root Domain Name (e.g., domain.name):"
read -r root_domain_name

echo "Enter App Domain Name (e.g., app.domain.name):"
read -r app_domain_name

echo "Enter Certificate ARN (from us-east-1 for CloudFront):"
read -r certificate_arn

echo "Enter Stack Name:"
read -r stack_name

# Display all inputs for confirmation
echo "You have entered the following information:"
echo "AWS CLI Profile Name: $profile"
echo "AWS Region: $region"
echo "Root Domain Name: $root_domain_name"
echo "App Domain Name: $app_domain_name"
echo "Certificate ARN: $certificate_arn"
echo "Stack Name: $stack_name"
echo "Do you want to proceed? (yes/no):"
read -r confirmation

if [[ "$confirmation" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
  # Execute the AWS command with the user-provided variables
  aws cloudformation create-stack --stack-name "$stack_name" \
  --template-body "file://$TEMPLATE" \
  --parameters \
  ParameterKey=DomainName,ParameterValue="$root_domain_name" \
  ParameterKey=AppDomainName,ParameterValue="$app_domain_name" \
  ParameterKey=CertificateARN,ParameterValue="$certificate_arn" \
  --region "$region" \
  --profile="$profile"

  echo "Stack creation command executed."
else
  echo "Operation cancelled by the user."
  exit 1
fi
