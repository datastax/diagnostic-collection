# the test target will execute once for every test-collector-k8s*.conf.in configuration file found
CONFIGURATIONS_SSH := $(shell ls test-collector-ssh*.conf)
CONFIGURATIONS_DOCKER := $(shell ls test-collector-docker*.conf)
TESTS_SSH := $(addprefix test_ssh_,${CONFIGURATIONS_SSH})
TESTS_DOCKER := $(addprefix test_docker_,${CONFIGURATIONS_DOCKER})

all: setup ${TESTS_SSH} ${TESTS_DOCKER} teardown

${TESTS_SSH}: test_ssh_%:
	# ds-collector over SSH
	@echo "\n  Testing SSH $* \n"
	docker exec -t ds-collector-tests_bastion_1 sh -c 'echo "" >> /ds-collector-tests/$*'
	docker exec -t ds-collector-tests_bastion_1 sh -c 'echo "git_branch=$$(git rev-parse --abbrev-ref HEAD)" >> /ds-collector-tests/$*'
	docker exec -t ds-collector-tests_bastion_1 sh -c 'echo "git_sha=$$(git rev-parse HEAD)" >> /ds-collector-tests/$*'
	docker exec -t ds-collector-tests_bastion_1 sh -c 'echo "" >> /ds-collector-tests/$*'
	docker exec -t ds-collector-tests_bastion_1 /collector/ds-collector -T -f /ds-collector-tests/$* -n ds-collector-tests_cassandra-00_1
	docker exec -t ds-collector-tests_bastion_1 /collector/ds-collector -T -p -f /ds-collector-tests/$* -n ds-collector-tests_cassandra-00_1
	docker exec -t ds-collector-tests_bastion_1 /collector/ds-collector -X -f /ds-collector-tests/$* -n ds-collector-tests_cassandra-00_1
	# test archives exist
	if ! ( docker exec ds-collector-tests_bastion_1 ls /tmp/datastax/ ) | grep -q ".tar.gz" ; then echo "Failed to generate artefacts in the SSH cluster" ; ( docker exec ds-collector-tests_bastion_1 ls /tmp/datastax/ ) ; exit 1 ; fi
	# ds-collector over SSH with verbose mode
	@echo "\n  Testing SSH verbose $* \n"
	docker exec -t ds-collector-tests_bastion_1 /collector/ds-collector -v -T -f /ds-collector-tests/$* -n ds-collector-tests_cassandra-00_1
	docker exec -t ds-collector-tests_bastion_1 /collector/ds-collector -v -T -p -f /ds-collector-tests/$* -n ds-collector-tests_cassandra-00_1
	docker exec -t ds-collector-tests_bastion_1 /collector/ds-collector -v -X -f /ds-collector-tests/$* -n ds-collector-tests_cassandra-00_1
	# test archives exist
	if ! ( docker exec ds-collector-tests_bastion_1 ls /tmp/datastax/ ) | grep -q ".tar.gz" ; then echo "Failed to generate artefacts in the SSH cluster" ; ( docker exec ds-collector-tests_bastion_1 ls /tmp/datastax/ ) ; exit 1 ; fi
	
${TESTS_DOCKER}: test_docker_%:
	# ds-collector over docker
	@echo "\n  Testing Docker $* \n"
	@echo "" >> $*
	@echo "git_branch=$$(git rev-parse --abbrev-ref HEAD)" >> $*
	@echo "git_sha=$$(git rev-parse HEAD)" >> $*
	echo "" >> $*
	./collector/ds-collector -T -f $* -n ds-collector-tests_cassandra-00_1
	./collector/ds-collector -T -p -f $* -n ds-collector-tests_cassandra-00_1
	./collector/ds-collector -X -f $* -n ds-collector-tests_cassandra-00_1
	# test archives exist
	if ! ls /tmp/datastax/ | grep -q ".tar.gz" ; then echo "Failed to generate artefacts in the docker cluster " ; ls -l /tmp/datastax/ ; exit 1 ; fi
	

setup:
	mkdir -p /tmp/datastax && rm -fr /tmp/datastax/* ../ds-collector.TEST-cluster-one-node-vanilla-ssh-docker-*.tar.gz TEST-cluster-one-node-vanilla-ssh-docker-*_secret.key
	# make diagnostics bundle
	cd ../ ; ISSUE="TEST-cluster-one-node-vanilla-ssh-docker-$$(git rev-parse --abbrev-ref HEAD)--$$(git rev-parse --short HEAD)" make
	tar -xvf ../ds-collector.TEST-cluster-one-node-vanilla-ssh-docker-*.tar.gz
	rm collector/collector.conf
	cp TEST-cluster-one-node-vanilla-ssh-docker-*_secret.key collector/ || true
	# setup single node docker cluster and bastion
	docker-compose up --build -d cassandra-00 bastion
	docker-compose ps
	while (! docker-compose ps | grep -q "ds-collector-tests_cassandra-00_1") || docker-compose ps | grep -q -e "Up (health: starting)" -e "running (started)" || docker-compose ps | grep -q "Exit" ; do docker-compose ps ; echo "waiting 60s…" ; sleep 60 ; done

	# ensure we have a file that is not owned by the copying user
	docker exec -t ds-collector-tests_cassandra-00_1 bash -c 'chown root:root /etc/cassandra/testfile.owneronly_root && chown cassandra:cassandra /etc/cassandra/testfile.owneronly_cassandra'

	# verify sshd and open CQL ports
	docker exec -t ds-collector-tests_cassandra-00_1 bash -c 'pgrep sshd 2>&1 > /dev/null && echo "SSHd is running" || echo "SSHd is not running"'
	docker exec -t ds-collector-tests_cassandra-00_1 bash -c 'ps aux | grep cassandra | grep -v grep 2>&1 > /dev/null && echo "Cassandra is running" || echo "Cassandra is not running"'


teardown:
	docker-compose down
