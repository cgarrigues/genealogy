NAME = cgarrigues/taskrunner
VERSION = 0.1.0
CONTAINERNAME = genealogytaskrunner

.PHONY: all build build-nocache

all: build

build:
	cp -r ../../lib genealogy/.
	cp -r ../../bin genealogy/.
	docker build -t $(NAME):$(VERSION) --rm .

build-nocache:
	docker build -t $(NAME):$(VERSION) --no-cache --rm .

run:
	-docker stop $(CONTAINERNAME)
	-docker rm $(CONTAINERNAME)
	-docker volume ls -q|xargs docker volume rm
	docker run --name $(CONTAINERNAME) --detach $(NAME):$(VERSION)
