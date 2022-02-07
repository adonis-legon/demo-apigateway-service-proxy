EMAIL_ENDPOINT=$1

# Create SNS Topic
TOPIC_ARN=$(aws sns create-topic --name service-proxy-topic --output text --query 'TopicArn')

# Create SMS Subscription to the previous topic
aws sns subscribe --topic-arn $TOPIC_ARN --protocol email --notification-endpoint $EMAIL_ENDPOINT

# Send a test message to the topic
aws sns publish --topic-arn $TOPIC_ARN --message 'This is a test'

# Create the Api Gateway
API_ID=$(aws apigateway create-rest-api --name 'Service Proxy' --output text --query 'id')

# Get the root Resource Id
ROOT_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id $API_ID --output text --query 'items[0].id')

# Create the Ingest resource as a child of the root resource
INGEST_RESOURCE_ID=$(aws apigateway create-resource --rest-api-id $API_ID --parent-id $ROOT_RESOURCE_ID --path-part ingest --output text --query 'id')

# Assign an HTTP Method to the Ingest resource
aws apigateway put-method --rest-api-id $API_ID --resource-id $INGEST_RESOURCE_ID --http-method POST --authorization-type NONE

# Create IAM Role for the Api Gateway
ROLE_ARN=$(aws iam create-role --role-name service-proxy-role --assume-role-policy-document '{ "Version": "2012-10-17", "Statement": { "Effect": "Allow", "Principal": {"Service": "apigateway.amazonaws.com"}, "Action": "sts:AssumeRole" } }' --output text --query 'Role.Arn')

# Assing permissions to the new Role to publish message to the previously created SNS topic
aws iam put-role-policy \
--role-name service-proxy-role \
--policy-name 'sns-publish' \
--policy-document '{ "Version": "2012-10-17", "Statement": { "Effect": "Allow", "Action": "sns:Publish", "Resource": "'$TOPIC_ARN'" } }'

# Create Api Gateway to SNS Integration
REGION=$(aws configure get region)
aws apigateway put-integration \
--rest-api-id $API_ID \
--resource-id $INGEST_RESOURCE_ID \
--http-method POST \
--type AWS \
--integration-http-method POST \
--uri 'arn:aws:apigateway:'$REGION':sns:path//' \
--credentials $ROLE_ARN \
--request-parameters '{
      "integration.request.header.Content-Type": "'\'application/x-www-form-urlencoded\''"
  }' \
--request-templates '{ 
  "application/json": "Action=Publish&TopicArn=$util.urlEncode('\'$TOPIC_ARN\'')&Message=$util.urlEncode($input.body)"
}' \
--passthrough-behavior NEVER

# Create an integration response to process the reponse from the SNS API
aws apigateway put-integration-response \
--rest-api-id $API_ID \
--resource-id $INGEST_RESOURCE_ID \
--http-method POST \
--status-code 200 \
--selection-pattern "" \
--response-templates '{"application/json": "{\"body\": \"Message received.\"}"}'

# Create a method response to specify the content to be returned to the client application
aws apigateway put-method-response \
--rest-api-id $API_ID \
--resource-id $INGEST_RESOURCE_ID \
--http-method POST \
--status-code 200 \
--response-models '{"application/json": "Empty" }'

# Create a Prod deployment of the API
aws apigateway create-deployment --rest-api-id $API_ID --stage-name prod

# Test the API
curl -X POST https://$API_ID.execute-api.$REGION.amazonaws.com/prod/ingest \
--data 'Hello, from your terminal!' \
-H 'Content-Type: application/json'