
all: setup test teardown


test:
	# ds-collector over k8s
	cp test-collector-k8s-dse.conf.in /tmp/datastax/test-collector-k8s-dse.conf
	echo "" >> /tmp/datastax/test-collector-k8s-dse.conf
	echo "cqlshUsername=$$(kubectl -n cass-operator get secret cluster2-superuser -o yaml | grep " username" | awk -F" " '{print $$2}' | base64 -d && echo "")" >> /tmp/datastax/test-collector-k8s-dse.conf
	echo "cqlshPassword=$$(kubectl -n cass-operator get secret cluster2-superuser -o yaml | grep " password" | awk -F" " '{print $$2}' | base64 -d && echo "")" >> /tmp/datastax/test-collector-k8s-dse.conf
	../ds-collector/ds-collector -T -f /tmp/datastax/test-collector-k8s-dse.conf -n cluster2-dc1-default-sts-0
	../ds-collector/ds-collector -X -f /tmp/datastax/test-collector-k8s-dse.conf -n cluster2-dc1-default-sts-0
	if ! ls /tmp/datastax/ | grep -q ".tar.gz" ; then echo "Failed to generate artefacts in the K8s cluster "; ls -l /tmp/datastax/ ; exit 1 ; fi


setup:
	rm -f ../ds-collector/collect-info
	cd ../ds-collector ; docker run --rm -v $$PWD:/volume -w /volume -t clux/muslrust rustc --target x86_64-unknown-linux-musl rust-commands/*.rs ; cd -
	test -f ../ds-collector/collect-info
	mkdir -p /tmp/datastax && rm -fr /tmp/datastax/*
	wget https://thelastpickle.com/files/2021-01-31-cass_operator/01-kind-config.yaml -O /tmp/datastax/01-kind-config.yaml
	kind create cluster --name ds-collector-cluster-dse-k8s --config /tmp/datastax/01-kind-config.yaml
	kubectl create ns cass-operator
	kubectl -n cass-operator apply -f https://thelastpickle.com/files/2021-01-31-cass_operator/02-storageclass-kind.yaml
	kubectl -n cass-operator apply -f https://raw.githubusercontent.com/k8ssandra/cass-operator/v1.7.1/docs/user/cass-operator-manifests.yaml
	while (! kubectl -n cass-operator get pod | grep -q "cass-operator-") || kubectl -n cass-operator get pod | grep -q "0/1" ; do kubectl -n cass-operator get pod ; echo "waiting 10s…" ; sleep 10 ; done
	kubectl -n cass-operator apply -f https://raw.githubusercontent.com/k8ssandra/cass-operator/v1.7.1/operator/example-cassdc-yaml/dse-6.8.x/example-cassdc-minimal.yaml
	while (! kubectl -n cass-operator get pod | grep -q "cluster2-dc1-default-sts-0") || kubectl -n cass-operator get pod | grep -q "0/2" || kubectl -n cass-operator get pod | grep -q "1/2" ; do kubectl -n cass-operator get pod ; echo "waiting 60s…" ; sleep 60 ; done


teardown:
	kubectl delete cassdcs --all-namespaces --all
	kubectl delete -f https://raw.githubusercontent.com/k8ssandra/cass-operator/v1.7.1/docs/user/cass-operator-manifests.yaml
	kind delete cluster --name ds-collector-cluster-dse-k8s
