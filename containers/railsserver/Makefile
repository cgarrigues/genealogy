NAME = cgarrigues/railsserver
VERSION = 0.1.0
CONTAINERNAME = genealogyrails

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
	docker run --name $(CONTAINERNAME) -p 8880:3000 -v /Users/cgarrigues/GitHub/genealogy/lib:/genealogy/lib --detach $(NAME):$(VERSION)
