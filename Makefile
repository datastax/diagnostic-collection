.PHONY: collector

collector: check-env generate-key
	@cp -R ds-collector/ collector
	@rm -f collector/collect-info
	@cd collector ; docker run --rm -v $$PWD:/volume -w /volume -t clux/muslrust rustc --target x86_64-unknown-linux-musl rust-commands/*.rs ; cd -
	@test -f collector/collect-info
	@rm -f collector/collector.hosts
	@rm -f collector/collector.conf
	@mv collector/collector.hosts.in collector/collector.hosts
	@mv collector/collector.conf.in collector/collector.conf
	@od -An -vtx1 collector/collector-0.11.1-SNAPSHOT.jar > collector/collector-0.11.1-SNAPSHOT.txt
	@rm collector/collector-0.11.1-SNAPSHOT.jar
	@sed -i.bak 's/\#issueId=.*/issueId=\"${ISSUE}\"/' collector/collector.conf
	@sed -i.bak 's/\#skipS3/skipS3/' collector/collector.conf
ifdef COLLECTOR_S3_AWS_KEY
ifdef COLLECTOR_S3_AWS_SECRET
	@sed -i.bak 's/\#keyId=.*/keyId=\"${COLLECTOR_S3_AWS_KEY}\"/' collector/collector.conf
	@sed -i.bak 's/\#keySecret=.*/keySecret=\"${COLLECTOR_S3_AWS_SECRET}\"/' collector/collector.conf
	@sed -i.bak 's/skipS3=.*/skipS3=\"false\"/' collector/collector.conf
endif
endif
	@sed -i.bak 's/\#encrypt_uploads/encrypt_uploads/' collector/collector.conf
ifdef COLLECTOR_SECRETSMANAGER_KEY
ifdef COLLECTOR_SECRETSMANAGER_SECRET
	@sed -i.bak 's/encrypt_uploads=.*/encrypt_uploads=\"true\"/' collector/collector.conf
endif
endif
ifdef is_docker
	@echo docker
	@sed -i.bak 's/\#use_docker=.*/use_docker=\"${is_docker}\"/' collector/collector.conf
	@sed -i.bak 's/\#skipSudo=.*/skipSudo=\"true\"/' collector/collector.conf
endif
ifdef is_k8s
	@echo k8s
	@sed -i.bak 's/\#use_k8s=.*/use_k8s=\"${is_k8s}\"/' collector/collector.conf
	@sed -i.bak 's/\#skipSudo=.*/skipSudo=\"true\"/' collector/collector.conf
endif
ifdef k8s_namespace
	@sed -i.bak 's/\#k8s_namespace=.*/k8s_namespace=\"${k8s_namespace}\"/' collector/collector.conf
endif
ifdef is_dse
	@echo dse
	@sed -i.bak 's/\#is_dse=.*/is_dse=\"${is_dse}\"/' collector/collector.conf
endif
	@rm -rf collector/*.bak
	@rm -rf collector/.idea
	@tar cvzf ds-collector.${ISSUE}.tar.gz collector
	@rm -rf collector
	@echo "A collector tarball has been generated as ds-collector.${ISSUE}.tar.gz"

check-env:
ifndef ISSUE
	$(error ISSUE is undefined, please set env var ISSUE and rerun)
endif
ifdef COLLECTOR_S3_AWS_KEY
ifndef COLLECTOR_S3_AWS_SECRET
	$(error COLLECTOR_S3_AWS_SECRET must also be defined if COLLECTOR_S3_AWS_KEY is defined)
endif
ifndef COLLECTOR_SECRETSMANAGER_KEY
	$(error COLLECTOR_SECRETSMANAGER_KEY must also be defined if COLLECTOR_S3_AWS_KEY is defined)
endif
endif
ifdef COLLECTOR_SECRETSMANAGER_KEY
ifndef COLLECTOR_SECRETSMANAGER_SECRET
	$(error COLLECTOR_SECRETSMANAGER_SECRET must also be defined if COLLECTOR_SECRETSMANAGER_KEY is defined)
endif
ifndef COLLECTOR_S3_AWS_KEY
	$(error COLLECTOR_S3_AWS_KEY must also be defined if COLLECTOR_SECRETSMANAGER_KEY is defined)
endif
ifndef COLLECTOR_S3_AWS_SECRET
	$(error COLLECTOR_S3_AWS_SECRET must also be defined if COLLECTOR_SECRETSMANAGER_KEY is defined)
endif
	@(AWS_ACCESS_KEY_ID=${COLLECTOR_SECRETSMANAGER_KEY} AWS_SECRET_ACCESS_KEY=${COLLECTOR_SECRETSMANAGER_SECRET} aws --region=us-west-2 secretsmanager list-secrets 2>/dev/null | grep -q Name ) || { echo >&2 "Failure: aws --region=us-west-2 secretsmanager list-secrets"; exit 1; }
endif
	@(command -v docker >/dev/null 2>&1) || { echo >&2 "docker needs to be installed"; exit 1; }
	@(docker info >/dev/null 2>&1) || { echo "docker needs to running"; exit 1; }
    

generate-key:
ifndef ISSUE
	$(error ISSUE is undefined, please set env var ISSUE and rerun)
endif
ifdef COLLECTOR_SECRETSMANAGER_KEY
ifdef COLLECTOR_SECRETSMANAGER_SECRET
	@(command -v aws >/dev/null 2>&1) || { echo >&2 "aws needs to be installed"; exit 1; }
	@(command -v openssl >/dev/null 2>&1) || { echo >&2 "openssl needs to be installed"; exit 1; }
	$(eval KEY_FILE_NAME := $(shell echo $${ISSUE}_secret.key))
	$(eval SECRET_EXISTS := $(shell AWS_ACCESS_KEY_ID=${COLLECTOR_SECRETSMANAGER_KEY} AWS_SECRET_ACCESS_KEY=${COLLECTOR_SECRETSMANAGER_SECRET} aws --region=us-west-2 secretsmanager list-secrets | grep ${KEY_FILE_NAME} | grep Name))
	@if [ -z "${SECRET_EXISTS}" ]; then \
		echo "Since the secret does not exist for ${ISSUE}, will generate a new one" ; \
		openssl rand -base64 256 > ${KEY_FILE_NAME} ; \
		echo "An encryption key has been generated as ${KEY_FILE_NAME}" ; \
		echo "I will now add the key to the Secrets Manager" ; \
		AWS_ACCESS_KEY_ID=${COLLECTOR_SECRETSMANAGER_KEY} AWS_SECRET_ACCESS_KEY=${COLLECTOR_SECRETSMANAGER_SECRET} aws --region=us-west-2 secretsmanager create-secret --name ${KEY_FILE_NAME} --description "Reuben collector key" --secret-string file://${KEY_FILE_NAME} ;\
	else \
		echo "Secret exists in Secrets Manager with ${SECRET_EXISTS}" ; \
		echo "Issue ${ISSUE} already already exists. Not creating a new secret." ; \
	fi
endif
endif
