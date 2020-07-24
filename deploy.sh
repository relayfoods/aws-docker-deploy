#!/bin/bash
set -e

# Download template
curl -LSso Dockerrun.aws.json.template https://raw.githubusercontent.com/imperfectproduce/aws-docker-deploy/c13ffa2eda068d5d4eee93ce498d1340f72a529c/Dockerrun.aws.json.template

# Set vars that typically do not vary by app
BRANCH=$(git rev-parse --symbolic-full-name --abbrev-ref HEAD | sed 's/[^A-Za-z0-9_\.-]/--/g' | head -c100)
SHA1=$(git rev-parse --short HEAD)
VERSION=$BRANCH-$SHA1-$(date +%s)
DESCRIPTION=$(git log -1 --pretty=%B)
DESCRIPTION=${DESCRIPTION:0:180} # truncate to 180 chars - max beanstalk version description is 200
ZIP=$VERSION.zip

aws configure set default.region $AWS_REGION

# Authenticate against our Docker registry
eval $(aws ecr get-login --region $AWS_REGION | sed "s/-e none //")

# Build and push the image
docker build -t $NAME:$VERSION .
docker tag $NAME:$VERSION $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$NAME:$VERSION
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$NAME:$VERSION

# Copy template Dockerrun.aws.json and replace template vars
cp Dockerrun.aws.json.template Dockerrun.aws.json

# Replace the template values
sed -i.bak "s/<AWS_ACCOUNT_ID>/$AWS_ACCOUNT_ID/" Dockerrun.aws.json
sed -i.bak "s/<AWS_REGION>/$AWS_REGION/" Dockerrun.aws.json
sed -i.bak "s/<NAME>/$NAME/" Dockerrun.aws.json
sed -i.bak "s/<TAG>/$VERSION/" Dockerrun.aws.json
sed -i.bak "s/<CONTAINER_PORT>/$CONTAINER_PORT/" Dockerrun.aws.json

# Zip up the Dockerrun file (feel free to zip up an .ebextensions directory with it)
if [ -d ".ebextensions" ]; then
   zip -r $ZIP Dockerrun.aws.json .ebextensions
else
   zip -r $ZIP Dockerrun.aws.json
fi

aws s3 cp $ZIP s3://$EB_BUCKET/$ZIP

# Create a new application version with the zipped up Dockerrun file
aws elasticbeanstalk create-application-version --application-name "$EB_APP_NAME" \
    --version-label $VERSION --description "$DESCRIPTION" --source-bundle S3Bucket=$EB_BUCKET,S3Key=$ZIP

function env_update_in_progress() {
  STATUS=$(aws elasticbeanstalk describe-environment-health \
    --environment-name $1 --attribute-names HealthStatus \
    --query="HealthStatus" --output text)
  echo "Environment Health is "
  echo $STATUS
  if [[ "$STATUS" != "Ok" ]]; then
    return 0
  else
    echo "Environment update complete"
    return 1
  fi
}

# Update the environment to use the new application version
if [ -z "$EB_ENV_NAME" ]; then
    echo "EB_ENV_NAME is not set, skipping deployment step"
else
  START_TIME=$(date +"%s")
  for env in ${EB_ENV_NAME[@]}; do
    aws elasticbeanstalk update-environment --environment-name $env \
        --version-label $VERSION
    if [ -n "$DEPLOY_POLLING" ]; then
      sleep 30
      while env_update_in_progress $env
      do
        ERROR_EVENTS_FROM_START_TIME=$(aws elasticbeanstalk describe-events \
            --environment-name $env --start-time $START_TIME) \
            | jq -r '.Events[] | select( .Severity == "ERROR")'

        if [[ -n "$ERROR_EVENTS_FROM_START_TIME" ]]; then
          echo $ERROR_EVENTS_FROM_START_TIME
          exit 1
        fi

        sleep 10
      done
    fi
  done
fi

# Clean up
rm $ZIP
rm Dockerrun.aws.json
rm Dockerrun.aws.json.bak
rm Dockerrun.aws.json.template
