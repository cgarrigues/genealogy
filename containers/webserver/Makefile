NAME = cgarrigues/taskrunner
VERSION = 0.1.0
CONTAINERNAME = genealogywebserver

.PHONY: all build build-nocache

all: build

build:
	docker build -t $(NAME):$(VERSION) --rm .

build-nocache:
	docker build -t $(NAME):$(VERSION) --no-cache --rm .

run:
	-docker stop $(CONTAINERNAME)
	-docker rm $(CONTAINERNAME)
	-docker volume ls -q|xargs docker volume rm
	docker run --name $(CONTAINERNAME) -p 4343:443 -p 8080:80 -v /Users/cgarrigues/GitHub/genealogy/lib:/genealogy/lib --detach $(NAME):$(VERSION)
