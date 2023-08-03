.PHONY: clean pre-commit

# pre-commit variables
DOCKER_IMG = ghcr.io/antonbabenko/pre-commit-terraform
DOCKER_TAG = latest
REPO_NAME = action-terraform-ci

clean:
	find . -type d -name "*.terraform" -or -name "*.terraform.lock.hcl" | sudo xargs rm -vrf

pre-commit:
	docker run -e "USERID=$$(id -u):$$(id -g)" -v $$(pwd):/lint -w /lint ${DOCKER_IMG}:${DOCKER_TAG} run -a