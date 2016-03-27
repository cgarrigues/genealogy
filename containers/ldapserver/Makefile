NAME = cgarrigues/ldapserver
VERSION = 0.1.0
CONTAINERNAME = genealogyldapserver

.PHONY: all build build-nocache

all: build

build:
	docker build -t $(NAME):$(VERSION) --rm .

build-nocache:
	docker build -t $(NAME):$(VERSION) --no-cache --rm .

run:
	docker stop $(CONTAINERNAME)
	docker rm $(CONTAINERNAME)
	docker run --name $(CONTAINERNAME) --detach $(NAME):$(VERSION)

dump:
	docker exec $(CONTAINERNAME) ldapsearch -x -h localhost -b dc=deepeddy,dc=com -D "cn=admin,dc=deepeddy,dc=com" -w '4zY!4*s#bPMO'

