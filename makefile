# {{{ -- meta
OPSYS     := alpine
SVCNAME   := coturn
SRCIMAGE  := s6

ifndef ORGNAME # ensure ORGNAME in env is prioritised over default
	ORGNAME  := woahbase
endif
REPONAME  := $(OPSYS)-$(SVCNAME)
ifndef REGISTRY # ensure REGISTRY in env is prioritised over default
	REGISTRY := $(shell docker info -f '{{.IndexServerAddress}}'|awk -F[/:] '{print $$4}')# default is index.docker.io
endif

# for daily build tags, will replace multiple same-day builds
BUILDDATE := $(shell date -u +%Y%m%d)
# detect builder host architecture
HOSTARCH  ?= $(call get_os_platform)
# target architecture on build and run, defaults to host architecture
ARCH      ?= $(HOSTARCH)
IMAGEBASE ?= $(if $(filter scratch,$(SRCIMAGE)),scratch,$(REGISTRY)/$(ORGNAME)/$(OPSYS)-$(SRCIMAGE):$(if $(SRCTAG),$(SRCTAG),$(ARCH)))
IMAGETAG  ?= $(REGISTRY)/$(ORGNAME)/$(REPONAME):$(ARCH)
CNTNAME   := docker_$(SVCNAME)
CNTSHELL  := /bin/bash

VERSION   ?= $(call get_svc_version)

TESTCMD   := \
	uname -a; \
	turnserver -h; \
	#
# -- }}}

# {{{ -- flags
# buildtime flags
# pull newest version of source
# or cache intermediate images,
CACHEFLAGS := --no-cache=true --pull
DOCKERFILE ?= $(if $(wildcard Dockerfile_$(ARCH)),Dockerfile_$(ARCH),Dockerfile)
LABELFLAGS ?= \
	--label online.woahbase.branch=$(shell git rev-parse --abbrev-ref HEAD) \
	--label online.woahbase.build-date=$(BUILDDATE) \
	--label online.woahbase.build-number=$${BUILDNUMBER:-undefined} \
	--label online.woahbase.source-image="$(if $(filter scratch,$(SRCIMAGE)),scratch,$(OPSYS)-$(SRCIMAGE):$(if $(SRCTAG),$(SRCTAG),$(ARCH)))" \
	--label org.opencontainers.image.base.name="$(if $(filter scratch,$(SRCIMAGE)),scratch,docker.io/$(ORGNAME)/$(OPSYS)-$(SRCIMAGE):$(if $(SRCTAG),$(SRCTAG),$(ARCH)))" \
	--label org.opencontainers.image.created=$(shell date -u +"%Y-%m-%dT%H:%M:%SZ") \
	--label org.opencontainers.image.documentation="$(if $(DOC_URL),$(DOC_URL),https://woahbase.online/images)/$(REPONAME)" \
	--label org.opencontainers.image.revision=$(shell git rev-parse --short HEAD) \
	--label org.opencontainers.image.source="$(shell git config --get remote.origin.url)" \
	--label org.opencontainers.image.title=$(REPONAME) \
	--label org.opencontainers.image.url="$(if $(REGISTRY_URL),$(REGISTRY_URL),https://$(REGISTRY))/$(ORGNAME)/$(REPONAME)" \
	--label org.opencontainers.image.vendor=$(ORGNAME) \
	--label org.opencontainers.image.version=tagged \
	# --label org.opencontainers.image.authors="$(shell git config --get user.name)($(shell git config --get user.email))" \
	#
# all build-time flags combined here
BUILDFLAGS ?= \
	$(CACHEFLAGS) \
	$(LABELFLAGS) \
	--build-arg IMAGEBASE=$(IMAGEBASE) \
	--build-arg http_proxy=$(http_proxy) \
	--build-arg https_proxy=$(https_proxy) \
	--build-arg no_proxy=$(no_proxy) \
	--compress \
	--file $(CURDIR)/$(DOCKERFILE) \
	--force-rm \
	--rm \
	--tag $(IMAGETAG) \
	#

# following applies if and when using buildx
BUILDKITCFG  := $(if $(wildcard $(CURDIR)/config.toml),--config $(CURDIR)/config.toml,)
BUILDKITIMG  := $(REGISTRY)/moby/buildkit:latest
BUILDERFLAGS ?= \
	$(BUILDKITCFG) \
	$(call get_docker_platform) \
	--driver docker-container \
	--driver-opt "image=$(BUILDKITIMG)" \
	#

# runtime flags
MOUNTFLAGS := \
	# -v $(CURDIR)/data:/var/lib/coturn \
	# -v /etc/hosts:/etc/hosts:ro \
	# -v /etc/localtime:/etc/localtime:ro \
	#
PORTFLAGS  := \
	-p 3478:3478/udp \
	-p 3478:3478/tcp \
	-p 5349:5349/tcp \
	-p 5349:5349/udp \
	# -p 49152-65535:49152-65535/udp \
	# # or use host network
	# --net=host \
	# # so other local containers can find it without explicit linking,
	# # needs firewall cleared
PUID       := $(shell id -u)
PGID       := $(shell id -g)# gid 100(users) usually pre exists
OTHERFLAGS := \
	--hostname $(SVCNAME) \
	--name $(CNTNAME) \
	-c 256 \
	-m 256m \
	-e PGID=$(PGID) \
	-e PUID=$(PUID) \
	# -e TZ=Asia/Kolkata \
	#
# all runtime flags combined here
RUNFLAGS   := \
	$(MOUNTFLAGS) \
	$(OTHERFLAGS) \
	$(PORTFLAGS) \
	#
# -- }}}

## ---
## Target : Depends :Description
## ---

all : run ## default target

# {{{ -- container targets

logs : ## show logs
	docker logs -f $(CNTNAME)

restart : ## restart container
	docker ps -a --format '{{.Names}}' \
		| grep '$(CNTNAME)' -q \
	&& docker restart $(CNTNAME) \
		|| echo "Service not running.";

rm : ## remove container
	docker rm -f $(CNTNAME)

run : ## run service
	docker run --rm $(RUNFLAGS) $(IMAGETAG)

shell : ## start a shell
	docker run --rm -it $(RUNFLAGS) --entrypoint $(CNTSHELL) $(IMAGETAG)

rdebug : ## shell into container as root
	docker exec -u root -it $(CNTNAME) $(CNTSHELL)

debug : ## shell into container as user
	docker exec -u $(PUID):$(PGID) -it $(CNTNAME) $(CNTSHELL)

stop : ## stop container
	docker stop -t 2 $(CNTNAME)

test : regbinfmt
test : ## run test command, i.e. TESTCMD
	if [ -z "$(SKIP_TEST_$(ARCH))" ] && [ -z "$(SKIP_TEST)" ] && [ -z "$(SKIP_$(ARCH))" ]; \
	then \
		docker run --rm -it --pull=never \
			$(RUNFLAGS) \
			--entrypoint $(CNTSHELL) \
			$(IMAGETAG) \
			-ec '$(TESTCMD)'; \
	else \
		echo "Skipping test: $(IMAGETAG)."; \
	fi;
	#

# -- }}}

# {{{ -- image targets
build : regbinfmt
build : BUILDX := $(shell docker buildx version 1>/dev/null 2>&1 && echo 'present' || echo 'absent')
build : ## build image
	if [ -z "$(SKIP_$(ARCH))" ]; \
	then \
		if [ "X$(BUILDX)" = "Xpresent" ]; \
		then \
			echo "Build(X)ing for $(ARCH) on $(HOSTARCH)"; \
			docker buildx create \
				--name builder_$(SVCNAME) \
				$(BUILDERFLAGS) \
				--use; \
			docker buildx build \
				--load \
				--builder builder_$(SVCNAME) \
				--progress plain $(call get_docker_platform) \
				$(BUILDFLAGS) \
				.; \
			docker buildx rm builder_$(SVCNAME); \
		else \
			echo "Building for $(ARCH) on $(HOSTARCH)"; \
			docker build $(BUILDFLAGS) .; \
		fi; \
	else \
		echo "Skipping build: $(IMAGETAG)."; \
	fi;

clean : ## cleanup
	docker images -a --format '{{.Repository}}:{{.Tag}}' \
		| grep "$(ORGNAME)/$(REPONAME)" \
		| xargs -r -n1 docker rmi
	# cleanup additional stuff below, e.g. config or data

# pull image (optionally from a different source)
pull : REGSRC ?= $(REGISTRY)
pull : ORGSRC  ?= $(ORGNAME)
pull : REPOSRC ?= $(REPONAME)
pull : TAGSRC ?= $(ARCH)
# or, specify only IMAGESRC
pull : IMAGESRC ?= $(REGSRC)/$(ORGSRC)/$(REPOSRC):$(TAGSRC)
# to force skip retag
#   set SKIP_RETAG to non empty string e.g. 1,
#   default is unset
# pull : SKIP_RETAG=
pull : ## pull image from source (could be different repository)
	docker pull \
		$(call get_docker_platform) \
		$(IMAGESRC); \
	if [ -z "$(SKIP_RETAG)" ] && [ "$(IMAGESRC)" != "$(IMAGETAG)" ];\
	then \
		echo "Re-Tagging: $(IMAGESRC) -> $(IMAGETAG)."; \
		docker tag $(IMAGESRC) $(IMAGETAG) \
		&& docker rmi -f $(IMAGESRC); \
	else \
		echo "Skipping retag: $(IMAGESRC)."; \
	fi;

# push image with arch tag
# push image with version tag (if available)
# to skip pushing version set SKIP_VERSIONTAG to non empty string e.g. 1, default is unset if version given
push : SKIP_VERSIONTAG ?= $(if $(VERSION),,1)
push : VERSIONTAG ?= $(subst $(ARCH),$(ARCH)$(if $(VERSION),_$(VERSION),),$(IMAGETAG))
push : BUILDDATETAG ?= $(subst $(ARCH),$(ARCH)$(if $(VERSION),_$(VERSION),)_$(BUILDDATE),$(IMAGETAG))
push : ## push image
	if [ -z "$(SKIP_$(ARCH))" ]; \
	then \
		if [ -z "$(SKIP_LATESTTAG)" ]; \
		then \
			docker push $(IMAGETAG); \
		fi; \
		if [ -z "$(SKIP_VERSIONTAG)" ] && [ -n "$(VERSION)" ];\
		then \
			echo "Tagging $(VERSIONTAG)"; \
			docker tag $(IMAGETAG) $(VERSIONTAG); \
			docker push $(VERSIONTAG); \
		else \
			echo "Skipping push version tag: $(VERSIONTAG)."; \
		fi; \
		if [ -z "$(SKIP_BUILDDATETAG)" ]; then \
			echo "Tagging $(BUILDDATETAG)"; \
			docker tag $(IMAGETAG) $(BUILDDATETAG); \
			docker push $(BUILDDATETAG); \
		else \
			echo "Skipping push builddate tag: $(BUILDDATETAG)."; \
		fi; \
	else \
		echo "Skipping push: $(IMAGETAG)."; \
	fi;

# push image with arch tag, optionally to a different registry
# push image with version tag (if available)
# to skip pushing version set SKIP_VERSIONTAG to non empty string e.g. 1, default is unset if version given
push_registry_% : SKIP_VERSIONTAG ?= $(if $(VERSION),,1)
push_registry_% : REGDSTTAG ?= $(subst $(REGISTRY),$(subst push_registry_,,$@),$(IMAGETAG))
push_registry_% : REGDSTVERSIONTAG ?= $(subst $(ARCH),$(ARCH)_$(VERSION),$(REGDSTTAG))
push_registry_% : REGDSTBUILDDATETAG ?= $(subst $(ARCH),$(ARCH)$(if $(VERSION),_$(VERSION),)_$(BUILDDATE),$(REGDSTTAG))
push_registry_% : ## push image to a different registry
	if [ -z "$(SKIP_$(ARCH))" ]; \
	then \
		if [ "$(IMAGETAG)" != "$(REGDSTTAG)" ]; \
		then \
			echo "Tagging $(REGDSTTAG)"; \
			docker tag $(IMAGETAG) $(REGDSTTAG); \
			if [ -z "$(SKIP_LATESTTAG)" ]; \
			then \
				docker push $(REGDSTTAG); \
			fi; \
		fi; \
		if [ -z "$(SKIP_VERSIONTAG)" ] && [ -n "$(VERSION)" ];\
		then \
			echo "Tagging $(REGDSTVERSIONTAG)"; \
			docker tag $(IMAGETAG) $(REGDSTVERSIONTAG); \
			docker push $(REGDSTVERSIONTAG); \
		else \
			echo "Skipping push version tag: $(REGDSTVERSIONTAG)."; \
		fi; \
		if [ -z "$(SKIP_BUILDDATETAG)" ]; then \
			echo "Tagging $(REGDSTBUILDDATETAG)"; \
			docker tag $(IMAGETAG) $(REGDSTBUILDDATETAG); \
			docker push $(REGDSTBUILDDATETAG); \
		else \
			echo "Skipping push builddate tag: $(REGDSTBUILDDATETAG)."; \
		fi; \
	else \
		echo "Skipping push: $(REGDSTTAG)."; \
	fi;

# to skip annotating, set SKIP_$(ARCH) to non-empty string, e.g. 1. default is unset.
# manifest: SKIP_x86_64=
# manifest: SKIP_aarch64=
# manifest: SKIP_armv7l=
# manifest: SKIP_armhf=
# if tagname != latest, use $(ARCH)_$(TAGNAME) to annotate, else just $(ARCH)
# manifest: TAGNAME = latest
manifest: ## create or update image(s) manifest
	if [ -z "$(SKIP_ANNOTATE)" ]; \
	then \
		MANIFESTTAG=$(subst $(ARCH),$(TAGNAME),$(IMAGETAG)); \
		docker manifest inspect $${MANIFESTTAG} > /dev/null 2>&1; \
		if [ $$? != 0 ]; then docker manifest create \
			$${MANIFESTTAG} \
			$(if $(SKIP_x86_64),,$(subst $(ARCH),x86_64$(if $(subst latest,,$(TAGNAME)),_$(TAGNAME),),$(IMAGETAG))) \
			$(if $(SKIP_aarch64),,$(subst $(ARCH),aarch64$(if $(subst latest,,$(TAGNAME)),_$(TAGNAME),),$(IMAGETAG))) \
			$(if $(SKIP_armv7l),,$(subst $(ARCH),armv7l$(if $(subst latest,,$(TAGNAME)),_$(TAGNAME),),$(IMAGETAG))) \
			$(if $(SKIP_armhf),,$(subst $(ARCH),armhf$(if $(subst latest,,$(TAGNAME)),_$(TAGNAME),),$(IMAGETAG))) \
			;\
		else docker manifest create --amend \
			$${MANIFESTTAG} \
			$(if $(SKIP_x86_64),,$(subst $(ARCH),x86_64$(if $(subst latest,,$(TAGNAME)),_$(TAGNAME),),$(IMAGETAG))) \
			$(if $(SKIP_aarch64),,$(subst $(ARCH),aarch64$(if $(subst latest,,$(TAGNAME)),_$(TAGNAME),),$(IMAGETAG))) \
			$(if $(SKIP_armv7l),,$(subst $(ARCH),armv7l$(if $(subst latest,,$(TAGNAME)),_$(TAGNAME),),$(IMAGETAG))) \
			$(if $(SKIP_armhf),,$(subst $(ARCH),armhf$(if $(subst latest,,$(TAGNAME)),_$(TAGNAME),),$(IMAGETAG))) \
			;\
		fi; \
	else \
		echo "Skipping manifest: $(IMAGETAG)."; \
	fi;

# to skip annotating, set SKIP_$(ARCH) to non-empty string, e.g. 1. default is unset.
# annotate: SKIP_x86_64=
# annotate: SKIP_aarch64=
# annotate: SKIP_armv7l=
# annotate: SKIP_armhf=
# if tagname != latest, use $(ARCH)_$(TAGNAME) to annotate, else just $(ARCH)
# annotate: TAGNAME = latest
annotate: ## annotate image(s) os/arch in manifest
	if [ -z "$(SKIP_ANNOTATE)" ]; \
	then \
		MANIFESTTAG=$(subst $(ARCH),$(TAGNAME),$(IMAGETAG)); \
		if [ -z "$(SKIP_x86_64)" ]; then \
			docker manifest annotate $(call get_manifest_platform,x86_64) \
				$${MANIFESTTAG} \
				$(subst $(ARCH),x86_64$(if $(subst latest,,$(TAGNAME)),_$(TAGNAME),),$(IMAGETAG)); \
		fi; \
		if [ -z "$(SKIP_aarch64)" ]; then \
			docker manifest annotate $(call get_manifest_platform,aarch64) \
				$${MANIFESTTAG} \
				$(subst $(ARCH),aarch64$(if $(subst latest,,$(TAGNAME)),_$(TAGNAME),),$(IMAGETAG)); \
		fi; \
		if [ -z "$(SKIP_armv7l)" ]; then \
			docker manifest annotate $(call get_manifest_platform,armv7l) \
				$${MANIFESTTAG} \
				$(subst $(ARCH),armv7l$(if $(subst latest,,$(TAGNAME)),_$(TAGNAME),),$(IMAGETAG)); \
		fi; \
		if [ -z "$(SKIP_armhf)" ]; then \
			docker manifest annotate $(call get_manifest_platform,armhf) \
				$${MANIFESTTAG} \
				$(subst $(ARCH),armhf$(if $(subst latest,,$(TAGNAME)),_$(TAGNAME),),$(IMAGETAG)); \
		fi; \
		docker manifest push -p $${MANIFESTTAG}; \
	else \
		echo "Skipping annotate: $(IMAGETAG)."; \
	fi;

annotate_latest : SKIP_ANNOTATE ?= $(if $(SKIP_LATESTTAG),1,)
annotate_latest : TAGNAME = latest
annotate_latest : manifest annotate ## annotate and push `latest` tag

annotate_version : SKIP_ANNOTATE ?= $(if $(SKIP_VERSIONTAG),1,)
annotate_version : TAGNAME ?= $(if $(VERSION),$(VERSION),$(error VERSION is not defined))
annotate_version : manifest annotate ## annotate and push `VERSION` tag

annotate_date : SKIP_ANNOTATE ?= $(if $(SKIP_BUILDDATETAG),1,)
annotate_date : TAGNAME ?= $(if $(VERSION),$(VERSION)_,$(error VERSION is not defined))$(BUILDDATE)
annotate_date : manifest annotate ## annotate and push `BUILDDATE` tag

# -- }}}

# {{{ -- other targets

regbinfmt : QEMUIMAGE ?= $(REGISTRY)/multiarch/qemu-user-static
regbinfmt : ## register binfmt for multiarch on x86_64
	if [ "$(ARCH)" != "$(HOSTARCH)" ]; then \
		docker run --rm --privileged $(QEMUIMAGE) --reset -p yes; \
	fi;
	#

help : ## show this help
	@sed -ne '/@sed/!s/## /|/p' $(MAKEFILE_LIST) | sed -e's/\W*:\W*=/:/g' | column -et -c 3 -s ':|?=' #| sort -h

get_config: ## get default config from github
	curl \
		-o $(CURDIR)/root/defaults/turnserver.conf \
		-SL https://github.com/coturn/coturn/raw/master/docker/coturn/turnserver.conf
		# or https://github.com/coturn/coturn/raw/master/examples/etc/turnserver.conf

# -- }}}

# {{{ -- functions
# maps os platform to docker tags when building on $(HOSTARCH) for $(ARCH)
OS_PLATFORM_MAP := \
       'aarch64') echo -n 'aarch64';; \
       'armv6l' ) echo -n 'armhf'  ;; \
       'armv7l' ) echo -n 'armv7l' ;; \
       'x86_64' ) echo -n 'x86_64' ;; \
       #
define get_os_platform
$(shell case "$$(uname -m)" in $(OS_PLATFORM_MAP) esac)
endef

# sets docker platform when building for $(ARCH)
DOCKER_PLATFORM_MAP := \
	'aarch64') echo -n '--platform linux/arm64' ;; \
	'armhf'  ) echo -n '--platform linux/arm/v6';; \
	'armv7l' ) echo -n '--platform linux/arm/v7';; \
	'x86_64' ) echo -n '--platform linux/amd64' ;; \
	#
define get_docker_platform
$(shell case "$(ARCH)" in $(DOCKER_PLATFORM_MAP) esac)
endef

# sets docker manifest annotation when building for $(ARCH)
MANIFEST_PLATFORM_MAP := \
	'aarch64') echo -n '--os linux --arch arm64';; \
	'armhf'  ) echo -n '--os linux --arch arm --variant v6';; \
	'armv7l' ) echo -n '--os linux --arch arm --variant v7';; \
	'x86_64' ) echo -n '--os linux --arch amd64';; \
	#
# $1 = ARCH
define get_manifest_platform
$(shell case "$(1)" in $(MANIFEST_PLATFORM_MAP) esac)
endef

# gets installed version string from built image
define get_svc_version
$(shell docker run --rm --pull=never \
	--entrypoint apk  \
	$(IMAGETAG) \
	info -d coturn \
	2>/dev/null \
	| grep 'coturn' | awk -F- '{ print $$2 }')
endef
# -- }}}
