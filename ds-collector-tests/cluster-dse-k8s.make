
all: setup test teardown


test:
	# ds-collector over k8s
	cp test-collector-k8s-dse.conf.in /tmp/datastax/test-collector-k8s-dse.conf
	echo "" >> /tmp/datastax/test-collector-k8s-dse.conf
	echo "cqlshUsername=$$(kubectl -n cass-operator get secret cluster2-superuser -o yaml | grep " username" | awk -F" " '{print $$2}' | base64 -d && echo "")" >> /tmp/datastax/test-collector-k8s-dse.conf
	echo "cqlshPassword=$$(kubectl -n cass-operator get secret cluster2-superuser -o yaml | grep " password" | awk -F" " '{print $$2}' | base64 -d && echo "")" >> /tmp/datastax/test-collector-k8s-dse.conf
	./collector/ds-collector -T -f /tmp/datastax/test-collector-k8s-dse.conf -n cluster2-dc1-default-sts-0
	./collector/ds-collector -T -p -f /tmp/datastax/test-collector-k8s-dse.conf -n cluster2-dc1-default-sts-0
	./collector/ds-collector -X -f /tmp/datastax/test-collector-k8s-dse.conf -n cluster2-dc1-default-sts-0
	if ! ls /tmp/datastax/ | grep -q ".tar.gz" ; then echo "Failed to generate artefacts in the K8s cluster "; ls -l /tmp/datastax/ ; exit 1 ; fi


setup:
	mkdir -p /tmp/datastax && rm -fr /tmp/datastax/*
	# make diagnostics bundle
	cd ../ ; ISSUE="TEST-$$(git rev-parse --abbrev-ref HEAD)--$$(git rev-parse --short HEAD)" make
	tar -xvf ../ds-collector.TEST-*.tar.gz
	rm collector/collector.conf
	cp TEST*_secret.key collector/ || true
	test -f collector/collect-info
	# setup k8s cluster
	wget https://thelastpickle.com/files/2021-01-31-cass_operator/01-kind-config.yaml -O /tmp/datastax/01-kind-config.yaml
	kind create cluster --name ds-collector-cluster-dse-k8s --config /tmp/datastax/01-kind-config.yaml
	kubectl create ns cass-operator
	kubectl -n cass-operator apply -f https://thelastpickle.com/files/2021-01-31-cass_operator/02-storageclass-kind.yaml
	kubectl -n cass-operator apply -f https://raw.githubusercontent.com/k8ssandra/cass-operator/v1.7.1/docs/user/cass-operator-manifests.yaml
	while (! kubectl -n cass-operator get pod | grep -q "cass-operator-") || kubectl -n cass-operator get pod | grep -q "0/1" ; do kubectl -n cass-operator get pod ; echo "waiting 10s…" ; sleep 10 ; done
	kubectl -n cass-operator apply -f https://raw.githubusercontent.com/k8ssandra/cass-operator/v1.7.1/operator/example-cassdc-yaml/dse-6.8.x/example-cassdc-minimal.yaml
	while (! kubectl -n cass-operator get pod | grep -q "cluster2-dc1-default-sts-0") || kubectl -n cass-operator get pod | grep -q "0/2" || kubectl -n cass-operator get pod | grep -q "1/2" ; do kubectl -n cass-operator get pod ; echo "waiting 60s…" ; sleep 60 ; done

	@echo "git_branch=$$(git rev-parse --abbrev-ref HEAD)" >> test-collector-k8s-dse.conf
	@echo "git_sha=$$(git rev-parse HEAD)" >> test-collector-k8s-dse.conf


teardown:
	kubectl delete cassdcs --all-namespaces --all
	kubectl delete -f https://raw.githubusercontent.com/k8ssandra/cass-operator/v1.7.1/docs/user/cass-operator-manifests.yaml
	kind delete cluster --name ds-collector-cluster-dse-k8s
