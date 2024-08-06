package main

import (
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/awserr"
	"github.com/aws/aws-sdk-go/aws/credentials"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/autoscaling"
	"github.com/aws/aws-sdk-go/service/ec2"
	"github.com/aws/aws-sdk-go/service/secretsmanager"
	"github.com/aws/aws-sdk-go/service/ssm"
)

// createSession initializes an AWS session
func createSession(region, accessKey, secretKey string) *session.Session {
	sess, err := session.NewSession(&aws.Config{
		Region: aws.String(region),
		Credentials: credentials.NewStaticCredentials(
			accessKey, // your AWS Access Key ID
			secretKey, // your AWS Secret Access Key
			"",        // a token will be created when using STS (session token service)
		),
	})
	if err != nil {
		log.Fatalf("Failed to create session: %v", err)
	}
	return sess
}

// getInstanceIDFromASG retrieves an instance ID from the given Auto Scaling group
func getInstanceIDFromASG(sess *session.Session, autoScalingGroupID string) (string, error) {
	svcASG := autoscaling.New(sess)

	describeASGInput := &autoscaling.DescribeAutoScalingGroupsInput{
		AutoScalingGroupNames: []*string{
			aws.String(autoScalingGroupID),
		},
	}

	asgResult, err := svcASG.DescribeAutoScalingGroups(describeASGInput)
	if err != nil {
		return "", fmt.Errorf("failed to describe Auto Scaling group: %w", err)
	}

	if len(asgResult.AutoScalingGroups) == 0 {
		return "", fmt.Errorf("no Auto Scaling groups found with ID %s", autoScalingGroupID)
	}

	instanceID := *asgResult.AutoScalingGroups[0].Instances[0].InstanceId
	return instanceID, nil
}

func checkInstanceReady(sess *session.Session, instanceID string, maxRetries int, interval time.Duration) error {
	svcEC2 := ec2.New(sess)
	svcSSM := ssm.New(sess)
	for i := 0; i < maxRetries; i++ {
		// Check instance state
		instanceState, err := getInstanceState(svcEC2, instanceID)
		if err != nil {
			return err
		}

		if instanceState == "running" {
			// Check SSM instance information
			_, err := svcSSM.DescribeInstanceInformation(&ssm.DescribeInstanceInformationInput{
				Filters: []*ssm.InstanceInformationStringFilter{
					{
						Key: aws.String("InstanceIds"),
						Values: []*string{
							aws.String(instanceID),
						},
					},
				},
			})
			if err == nil {
				return nil
			}
		}

		fmt.Printf("Instance not ready, retrying in %s...\n", interval)
		time.Sleep(interval)
	}
	return fmt.Errorf("instance not ready after %d retries", maxRetries)
}

func getInstanceState(svcEC2 *ec2.EC2, instanceID string) (string, error) {
	resp, err := svcEC2.DescribeInstances(&ec2.DescribeInstancesInput{
		InstanceIds: []*string{aws.String(instanceID)},
	})
	if err != nil {
		return "", err
	}

	if len(resp.Reservations) == 0 || len(resp.Reservations[0].Instances) == 0 {
		return "", fmt.Errorf("instance not found")
	}

	return *resp.Reservations[0].Instances[0].State.Name, nil
}

// executeScriptOnInstance runs the script on the specified instance and returns the output
func executeScriptOnInstance(sess *session.Session, instanceID, scriptContent string) (string, error) {
	svcSSM := ssm.New(sess)

	sendCommandInput := &ssm.SendCommandInput{
		InstanceIds: []*string{
			aws.String(instanceID),
		},
		DocumentName: aws.String("AWS-RunShellScript"),
		Parameters: map[string][]*string{
			"commands": {
				aws.String(scriptContent),
			},
		},
	}

	sendCommandResult, err := svcSSM.SendCommand(sendCommandInput)
	if err != nil {
		return "", fmt.Errorf("failed to send command: %w", err)
	}

	commandID := *sendCommandResult.Command.CommandId

	for {
		time.Sleep(5 * time.Second)

		getCommandInvocationInput := &ssm.GetCommandInvocationInput{
			CommandId:  aws.String(commandID),
			InstanceId: aws.String(instanceID),
		}

		getCommandInvocationOutput, err := svcSSM.GetCommandInvocation(getCommandInvocationInput)
		if err != nil {
			return "", fmt.Errorf("failed to get command invocation: %w", err)
		}

		if *getCommandInvocationOutput.Status == ssm.CommandInvocationStatusSuccess {
			return *getCommandInvocationOutput.StandardOutputContent, nil
		}

		if *getCommandInvocationOutput.Status == ssm.CommandInvocationStatusFailed ||
			*getCommandInvocationOutput.Status == ssm.CommandInvocationStatusCancelled ||
			*getCommandInvocationOutput.Status == ssm.CommandInvocationStatusTimedOut {
			return "", fmt.Errorf("command failed with status: %s", *getCommandInvocationOutput.Status)
		}

		fmt.Printf("Command status: %s, waiting...\n", *getCommandInvocationOutput.Status)
	}
}

// storeOutputInSecretsManager stores the key-value pairs in AWS Secrets Manager
func storeOutputInSecretsManager(sess *session.Session, secretName string, secretData map[string]string) error {
	svcSM := secretsmanager.New(sess)

	// Convert the key-value pairs to a JSON string
	secretValue, err := json.Marshal(secretData)
	if err != nil {
		return fmt.Errorf("failed to marshal secret data: %w", err)
	}

	// Trim any whitespace characters from the JSON string
	secretString := strings.TrimSpace(string(secretValue))

	// Check if the secret already exists
	getSecretValueInput := &secretsmanager.GetSecretValueInput{
		SecretId: aws.String(secretName),
	}

	_, err = svcSM.GetSecretValue(getSecretValueInput)
	if err != nil {
		// If the secret does not exist, create a new one
		if isResourceNotFoundException(err) {
			_, err := svcSM.CreateSecret(&secretsmanager.CreateSecretInput{
				Name:         aws.String(secretName),
				SecretString: aws.String(string(secretString)),
			})
			if err != nil {
				return fmt.Errorf("failed to create secret: %w", err)
			}
		} else {
			return fmt.Errorf("failed to get secret value: %w", err)
		}
	} else {
		// If the secret exists, update it
		_, err := svcSM.UpdateSecret(&secretsmanager.UpdateSecretInput{
			SecretId:     aws.String(secretName),
			SecretString: aws.String(string(secretString)),
		})
		if err != nil {
			return fmt.Errorf("failed to update secret: %w", err)
		}
	}

	return nil
}

// getSecret retrieves the secret value from AWS Secrets Manager and parses it into a map
func getSecretManager(sess *session.Session, secretName string) (map[string]string, error) {
	svcSM := secretsmanager.New(sess)

	// Retrieve the secret value
	getSecretValueInput := &secretsmanager.GetSecretValueInput{
		SecretId: aws.String(secretName),
	}

	result, err := svcSM.GetSecretValue(getSecretValueInput)
	if err != nil {
		return nil, fmt.Errorf("failed to get secret value: %w", err)
	}

	// Parse the JSON string into a map
	var secretData map[string]string
	err = json.Unmarshal([]byte(*result.SecretString), &secretData)
	if err != nil {
		return nil, fmt.Errorf("failed to unmarshal secret data: %w", err)
	}

	return secretData, nil
}

// isResourceNotFoundException checks if the error is a ResourceNotFoundException
func isResourceNotFoundException(err error) bool {
	if aerr, ok := err.(awserr.Error); ok {
		if aerr.Code() == secretsmanager.ErrCodeResourceNotFoundException {
			return true
		}
	}
	return false
}
