.PHONY: help

TAG := "bryanhuntesl/eflame:latest"

shell: ## Run an Erlang shell in the image
	docker run --rm -it -v /tmp:/tmp $(TAG) erl

sh: ## Boot to a shell prompt
	docker run --rm -it -v /tmp:/tmp $(TAG) /bin/sh

build: ## Build the Docker image
	docker build --squash --force-rm -t $(TAG) .

clean: ## Clean up generated images
	@docker rmi --force $(TAG)

rebuild: clean build ## Rebuild the Docker image

release: build ## Rebuild and release the Docker image to Docker Hub
	docker push $(TAG)
