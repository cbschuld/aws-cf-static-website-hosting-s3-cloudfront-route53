# Static HTTPS / SSL Website Hosting with AWS

## Using CloudFront, S3 and Route53

This repository provides an AWS CloudFormation Template to construct a CloudFront SSL/HTTPS static hosted website from an S3 bucket including the necessary Route53 DNS entries.

You need to have a few things in place for these templates to work:

- A certificate in the AWS Certificate Manager (ACM) for your domain
- A hosted zone in Route53 for your domain

## Determine the Hosted Zone ID

Determine the zone ID using the AWS CLI. In this example I'll use my named profile `example` and look for `example.com`

### Using the AWS CLI

Please note you'll need `jq` for this operation to work.  If you are on MacOS, for example, you can add it with brew: `brew install jq`

```sh
aws route53 list-hosted-zones-by-name --profile=example |
jq --arg name "example.com." \
-r '.HostedZones | .[] | select(.Name=="\($name)") | .Id'
```

### Example output:

```
/hostedzone/Z1UVA2VESUQ1UN
```

## Create a Certificate

Create the certificate in the AWS Certificate Manager (ACM) for your domain. You can use the AWS CLI or the AWS Console. Here is the example for the AWS CLI. You need to know the **domain name** and the **hosted zone ID**.

```sh
aws cloudformation create-stack --stack-name example-com-certificate --template-body file://certificate.yml \
--parameters \
ParameterKey=DomainName,ParameterValue=example.com \
ParameterKey=HostedZoneId,ParameterValue=Z1UVA2VESUQ1UN \
--region=us-east-1 \
--profile=example
```

aws cloudformation create-stack --stack-name aztecsoftware-net-certificate --template-body file://certificate.yml \
--parameters \
ParameterKey=DomainName,ParameterValue=aztecsoftware.net \
ParameterKey=HostedZoneId,ParameterValue=Z1UVA5VESUQ1GN \
--region=us-east-1 \
--profile=aztec

```

### Using the Stack Template(s)
```

aws cloudformation create-stack --stack-name aztecsoftware-net-static-website --template-body file://static-website.yml \
--parameters \
ParameterKey=DomainName,ParameterValue=aztecsoftware.net \
ParameterKey=AppDomainName,ParameterValue=aztecsoftware.net \
ParameterKey=CertificateARN,ParameterValue=arn:aws:acm:us-east-1:115504476576:certificate/6cb63a42-626f-4cc3-91fc-243c25d45b68 \
--region=us-east-1 \
--profile=aztec

```

```
