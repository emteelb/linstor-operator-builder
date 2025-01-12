SRCNAME ?= piraeus
SRCOP ?= piraeus-operator
SRCCHART ?= $(SRCOP)/charts/piraeus
SRCPVCHART ?= $(SRCOP)/charts/pv-hostpath
DSTNAME ?= linstor
DSTOP ?= linstor-operator
DSTCHART ?= linstor-operator-helm
DSTPVCHART ?= linstor-operator-helm-pv
UPSTREAMCHARTS ?= ./upstream-charts
DSTHELMPACKAGE ?= out/helm
ARCH ?= $(shell go env GOARCH 2> /dev/null || echo amd64)
REGISTRY ?= drbd.io/$(ARCH)
OLM_REGISTRY ?= registry.connect.redhat.com/linbit
SEMVER ?= $(shell hack/getsemver.py)
TAG ?= v$(subst +,-,$(SEMVER))
# Either "test" or "release". For "test", use internal registry, otherwise use redhat registry for CSV generation
BUILDENV ?= test
UPSTREAMGIT ?= https://github.com/LINBIT/linstor-operator-builder.git
DOCKER_BUILD_ARGS ?=
PUSH_LATEST ?= yes

TEST_CHANNELS := alpha
RELEASE_CHANNELS := stable,$(TEST_CHANNELS)
CSV_CHANNELS := $(if $(findstring -,$(SEMVER)),$(TEST_CHANNELS),$(RELEASE_CHANNELS))
DSTCHART := $(abspath $(DSTCHART))
DSTPVCHART := $(abspath $(DSTPVCHART))
DSTHELMPACKAGE := $(abspath $(DSTHELMPACKAGE))
IMAGE := $(REGISTRY)/$(notdir $(DSTOP))

all: operator chart pvchart olm

distclean:
	rm -rf "$(DSTOP)" "$(DSTCHART)" "$(DSTPVCHART)" "$(DSTHELMPACKAGE)" "$(UPSTREAMCHARTS)"

########## operator #########

SRC_FILES_LOCAL_CP = $(shell find LICENSE Dockerfile build pkg -type f)
DST_FILES_LOCAL_CP = $(addprefix $(DSTOP)/,$(SRC_FILES_LOCAL_CP))

SRC_FILES_CP = $(shell find $(SRCOP)/cmd $(SRCOP)/pkg $(SRCOP)/version -type f)
SRC_FILES_CP += $(SRCOP)/build/bin/user_setup $(SRCOP)/go.mod $(SRCOP)/go.sum
DST_FILES_CP = $(subst $(SRCOP),$(DSTOP),$(SRC_FILES_CP))

operator: $(DSTOP)
	[ $$(basename $(DSTOP)) = "linstor-operator" ] || \
		{ >&2 echo "error: last component of DSTOP must be linstor-operator"; exit 1; }
	cd $(DSTOP) && \
		docker build $(DOCKER_BUILD_ARGS) --tag $(IMAGE):$(TAG) .

$(DSTOP): $(DST_FILES_LOCAL_CP) $(DST_FILES_CP)

$(DST_FILES_LOCAL_CP): $(DSTOP)/%: %
	mkdir -p "$$(dirname "$@")"
	cp -av "$^" "$@"

$(DST_FILES_CP): $(DSTOP)/%: $(SRCOP)/%
	mkdir -p "$$(dirname "$@")"
	cp -av "$^" "$@"

########## chart #########

CHART_LOCAL = charts/linstor
CHART_SRC_FILES_MERGE = $(CHART_LOCAL)/Chart.yaml $(CHART_LOCAL)/values.yaml
CHART_DST_FILES_MERGE = $(subst $(CHART_LOCAL),$(DSTCHART),$(CHART_SRC_FILES_MERGE))

CHART_SRC_FILES_REPLACE = $(shell find $(SRCCHART)/templates $(SRCCHART)/charts -type f)
CHART_SRC_FILES_REPLACE += $(SRCCHART)/.helmignore
CHART_DST_FILES_REPLACE = $(subst $(SRCCHART),$(DSTCHART),$(CHART_SRC_FILES_REPLACE))

CHART_SRC_FILES_RENAME = $(shell find $(SRCCHART)/crds -type f)
CHART_DST_FILES_RENAME_TMP = $(subst $(SRCCHART),$(DSTCHART),$(CHART_SRC_FILES_RENAME))
CHART_DST_FILES_RENAME = $(subst $(SRCNAME),$(DSTNAME),$(CHART_DST_FILES_RENAME_TMP))

chart: $(DSTCHART)
	helm package "$(DSTCHART)" --dependency-update --destination "$(DSTHELMPACKAGE)" --version $(SEMVER)

$(DSTCHART): $(CHART_DST_FILES_MERGE) $(CHART_DST_FILES_REPLACE) $(CHART_DST_FILES_RENAME)

$(CHART_DST_FILES_MERGE): $(DSTCHART)/%: $(SRCCHART)/% charts/linstor/%
	mkdir -p "$$(dirname "$@")"
	yq merge --overwrite $^ | \
		sed 's/piraeus/linstor/g ; s/Piraeus/Linstor/g' > "$@"

$(CHART_DST_FILES_REPLACE): $(DSTCHART)/%: $(SRCCHART)/%
	mkdir -p "$$(dirname "$@")"
	if [ -f "$(CHART_LOCAL)/$*" ]; then cp "$(CHART_LOCAL)/$*" "$@" ; else sed 's/piraeus/linstor/g ; s/Piraeus/Linstor/g' "$^" > "$@"; fi

$(CHART_DST_FILES_RENAME): $(DSTCHART)/crds/$(DSTNAME).linbit.%: $(SRCCHART)/crds/$(SRCNAME).linbit.%
	mkdir -p "$$(dirname "$@")"
	sed 's/piraeus/linstor/g ; s/Piraeus/Linstor/g' "$^" > "$@"

########## OLM bundle ##########
olm: $(DSTOP)/deploy/crds $(DSTOP)/deploy/operator.yaml $(DSTOP)/deploy/linstor-operator.image.$(BUILDENV).filled doc/README.openshift.md
	# Needed for operator-sdk to choose the correct project version
	mkdir -p $(DSTOP)/build
	touch -a $(DSTOP)/build/Dockerfile
	# The relevant roles are already part of operator.yaml, as created by helm. operator-sdk still requires this file to work
	touch -a $(DSTOP)/deploy/role.yaml

	# Seed the CSV with static information
	mkdir -p $(DSTOP)/deploy/olm-catalog/$(DSTOP)/$(SEMVER)/
	cp deploy/linstor-operator.clusterserviceversion.part.yaml $(DSTOP)/deploy/olm-catalog/$(DSTOP)/$(SEMVER)/linstor-operator.clusterserviceversion.yaml

	cd $(DSTOP) ; operator-sdk generate csv --csv-version $(SEMVER) --update-crds
	# Fix CSV permissions
	hack/patch-csv-rules.sh $(DSTOP)/deploy/operator.yaml $(DSTOP)/deploy/olm-catalog/$(DSTOP)/manifests/$(DSTOP).clusterserviceversion.yaml
	# Fill description from openshift README
	yq -P write --inplace --style single $(DSTOP)/deploy/olm-catalog/$(DSTOP)/manifests/$(DSTOP).clusterserviceversion.yaml 'spec.description' "$$(cat doc/README.openshift.md)"
	# Override examples
	yq -P write --inplace --style single $(DSTOP)/deploy/olm-catalog/$(DSTOP)/manifests/$(DSTOP).clusterserviceversion.yaml 'metadata.annotations.alm-examples' "$$(yq -P read deploy/linstor-operator.clusterserviceversion.part.yaml 'metadata.annotations.alm-examples')"
	# Set image configuration
	hack/patch-csv-images.sh $(DSTOP)/deploy/olm-catalog/$(DSTOP)/manifests/$(DSTOP).clusterserviceversion.yaml $(DSTOP)/deploy/linstor-operator.image.$(BUILDENV).filled
	# Set CSV version
	yq -P write --inplace $(DSTOP)/deploy/olm-catalog/$(DSTOP)/manifests/$(DSTOP).clusterserviceversion.yaml 'spec.version' $(SEMVER)
	# Set CSV metadata annotations
	yq -P write --inplace $(DSTOP)/deploy/olm-catalog/$(DSTOP)/manifests/$(DSTOP).clusterserviceversion.yaml 'metadata.annotations.createdAt' $(shell date --utc --iso-8601=seconds)
	# Remove the "replaces" section, its not guaranteed to always find the real latest version
	yq -P delete --inplace $(DSTOP)/deploy/olm-catalog/$(DSTOP)/manifests/$(DSTOP).clusterserviceversion.yaml 'spec.replaces'

	# Generate bundle build directory
	mkdir -p out/olm-bundle/$(SEMVER)
	cp -av -t out/olm-bundle/$(SEMVER) $(DSTOP)/deploy/olm-catalog/$(DSTOP)/manifests deploy/metadata
	yq -P write --inplace out/olm-bundle/$(SEMVER)/metadata/annotations.yaml 'annotations."operators.operatorframework.io.bundle.channels.v1"' $(CSV_CHANNELS)
	sed s/#CHANNELS#/$(CSV_CHANNELS)/ deploy/bundle.Dockerfile > out/olm-bundle/$(SEMVER)/Dockerfile

$(DSTOP)/deploy/operator.yaml: $(DSTCHART) deploy/linstor-operator-csv.helm-values.yaml
	mkdir -p "$$(dirname "$@")"
	helm template --dependency-update linstor $(DSTCHART) -f deploy/linstor-operator-csv.helm-values.yaml --set operator.image=$(OLM_REGISTRY)/linstor-operator:$(TAG) --set operator.controller.dbConnectionURL=k8s > "$@"

$(DSTOP)/deploy/crds: $(DSTCHART)
	mkdir -p "$@"
	cp -rv -t $(DSTOP)/deploy/ $(DSTCHART)/crds

$(DSTOP)/deploy/linstor-operator.image.$(BUILDENV).filled: deploy/linstor-operator.image.$(BUILDENV).yaml hack/fetch-image-digests.py
	yq read --tojson $< | hack/fetch-image-digests.py $(DSTOP)/deploy/linstor-operator.image.$(BUILDENV).filled $(TAG)

########## chart for hostPath PersistentVolume #########

PVCHART_SRC_FILES_CP = $(shell find $(SRCPVCHART) -type f)
PVCHART_DST_FILES_CP = $(subst $(SRCPVCHART),$(DSTPVCHART),$(PVCHART_SRC_FILES_CP))

pvchart: $(PVCHART_DST_FILES_CP)
	helm package --destination "$(DSTHELMPACKAGE)" "$(DSTPVCHART)"

$(PVCHART_DST_FILES_CP): $(DSTPVCHART)/%: $(SRCPVCHART)/%
	mkdir -p "$$(dirname "$@")"
	cp -av "$^" "$@"

######## Upstream Charts ########

.PHONY: upstream-charts
upstream-charts:
	mkdir -p $(UPSTREAMCHARTS)
	rsync -a --delete piraeus-charts/charts/linstor-affinity-controller/ $(UPSTREAMCHARTS)/linstor-affinity-controller
	rsync -a --delete piraeus-charts/charts/piraeus-ha-controller/ $(UPSTREAMCHARTS)/linstor-ha-controller
	# Customization for HA Controller
	rsync -a charts/linstor-ha-controller/ $(UPSTREAMCHARTS)/linstor-ha-controller
	helm package --destination $(DSTHELMPACKAGE) $(UPSTREAMCHARTS)/linstor-affinity-controller
	helm package --destination $(DSTHELMPACKAGE) $(UPSTREAMCHARTS)/linstor-ha-controller

########## stork standalone deployment ##########

DSTSTORK := $(abspath out/stork.yaml)

stork: $(DSTCHART)
	mkdir -p $(dir $(DSTSTORK))
	helm template linstor-stork $(DSTCHART) --namespace MY-STORK-NAMESPACE --set global.setSecurityContext=false --set stork.enabled=true --set stork.schedulerTag=v1.16.0 --set controllerEndpoint=MY-LINSTOR-URL --show-only templates/stork-deployment.yaml > $(DSTSTORK)

########## publishing #########

publish: upstream-charts chart pvchart stork
	tmpd=$$(mktemp -p $$PWD -d) && pw=$$PWD && churl=https://charts.linstor.io && \
	chmod 775 $$tmpd && cd $$tmpd && \
	git clone -b gh-pages --single-branch $(UPSTREAMGIT) . && \
	cp $$pw/helm.template.html ./helm.html && \
	cp "$(DSTHELMPACKAGE)"/* . && \
	mkdir -p ./deploy && \
	cp -t ./deploy $(DSTSTORK) $(DSTHACTRL) && \
	helm repo index . --url $$churl && \
	for f in $$(ls -v *.tgz); do echo "<aside><a href='$$churl/$$f' title='$$churl/$$f'>$$(basename $$f)</a></aside>" >> helm.html; done && \
	echo '</section></main></body></html>' >> helm.html && \
	git add . && \
	git commit -am 'gh-pages' && \
	git push $(UPSTREAMGIT) gh-pages:gh-pages && \
	rm -rf $$tmpd

upload: operator
	docker push $(IMAGE):$(TAG)

.PHONY:	publish upload pvchart olm chart operator $(DSTOP) $(DSTCHART)
