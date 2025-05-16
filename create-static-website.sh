#!/bin/bash

echo "Enter AWS CLI Profile Name:"
read profile

# Validate AWS CLI Profile Name
if aws sts get-caller-identity --profile="$profile" > /dev/null 2>&1; then
  echo "Profile name is valid."
else
  echo "Profile name is invalid or unable to authenticate. Please check the profile name and credentials."
  exit 1
fi

echo "Enter AWS Region (e.g., us-east-1):"
read region

echo "Enter Root Domain Name (e.g., domain.name):"
read root_domain_name

echo "Enter App Domain Name (e.g., app.domain.name):"
read app_domain_name

echo "Enter Certificate ARN (from us-east-1 for CloudFront):"
read certificate_arn

echo "Enter Stack Name:"
read stack_name

# Display all inputs for confirmation
echo "You have entered the following information:"
echo "AWS CLI Profile Name: $profile"
echo "AWS Region: $region"
echo "Root Domain Name: $root_domain_name"
echo "App Domain Name: $app_domain_name"
echo "Certificate ARN: $certificate_arn"
echo "Stack Name: $stack_name"
echo "Do you want to proceed? (yes/no):"
read confirmation

if [[ "$confirmation" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
  # Download the CloudFormation template
  wget -O static-website-template.yml https://raw.githubusercontent.com/cbschuld/aws-cf-static-website-hosting-s3-cloudfront-route53/main/static-website.yml

  # Execute the AWS command with the user-provided variables
  aws cloudformation create-stack --stack-name "$stack_name" \
  --template-body file://static-website-template.yml \
  --parameters \
  ParameterKey=DomainName,ParameterValue="$root_domain_name" \
  ParameterKey=AppDomainName,ParameterValue="$app_domain_name" \
  ParameterKey=CertificateARN,ParameterValue="$certificate_arn" \
  --region "$region" \
  --profile="$profile" \
  --capabilities CAPABILITY_IAM

  echo "Stack creation command executed."

  # Delete the downloaded file
  rm -f static-website-template.yml
  echo "Downloaded CloudFormation template deleted."
else
  echo "Operation cancelled by the user."
  exit 1
fi
