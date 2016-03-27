NAME = cgarrigues/ldapadmin
VERSION = 0.1.0
CONTAINERNAME = genealogyldapadmin

.PHONY: all build build-nocache

all: build

build:
	docker build -t $(NAME):$(VERSION) --rm .

build-nocache:
	docker build -t $(NAME):$(VERSION) --no-cache --rm .

run:
	-docker stop $(CONTAINERNAME)
	-docker rm $(CONTAINERNAME)
	docker run --name $(CONTAINERNAME) -p 4443:443 --detach $(NAME):$(VERSION)


debug:
	-docker stop $(CONTAINERNAME)
	-docker rm $(CONTAINERNAME)
	docker run --name $(CONTAINERNAME) -p 4443:443 --detach $(NAME):$(VERSION) --loglevel debug
