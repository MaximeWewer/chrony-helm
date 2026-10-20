# Chart maintenance targets.
#
#   make docs        - regenerate charts/chrony/README.md via helm-docs.
#   make docs-check  - fail if the committed README is stale (CI target).
#   make lint        - helm lint, defaults and every ci/*-values.yaml.
#   make template    - render every ci/*-values.yaml and check the manifests
#                      (duplicate keys, merged documents, undeclared volumes,
#                      selectors matching no pod).
#   make kubeconform - validate the rendered manifests against the schemas.
#   make e2e         - install on the current kube context, wait, helm test.
#
# Install helm-docs once:
#   go install github.com/norwoodj/helm-docs/cmd/helm-docs@latest

CHART       := charts/chrony
RELEASE     ?= chrony-e2e
NAMESPACE   ?= chrony-e2e
E2E_VALUES  ?= $(CHART)/ci/default-values.yaml
KUBE_VERSION ?= 1.31.0

.PHONY: docs docs-check lint template kubeconform e2e e2e-clean

docs:
	helm-docs --chart-search-root=charts --skip-version-footer

docs-check:
	@tmp=$$(mktemp -d) && \
	  cp -R $(CHART) $$tmp/ && \
	  helm-docs --chart-search-root=$$tmp --skip-version-footer >/dev/null && \
	  diff -q $(CHART)/README.md $$tmp/chrony/README.md || \
	  { echo 'ERROR: chart README out of date - run `make docs`'; exit 1; }
	@echo 'README up to date.'

lint:
	@helm lint $(CHART)
	@for f in $(CHART)/ci/*-values.yaml; do \
	  helm lint $(CHART) -f $$f >/dev/null || { echo "lint failed: $$f"; helm lint $(CHART) -f $$f; exit 1; }; \
	done
	@echo 'Lint ok for every ci/*-values.yaml.'

template:
	@python3 scripts/check-manifests.py $(CHART)

# CRDs (ServiceMonitor, PrometheusRule, Certificate) come from the datree
# catalog; anything else unknown is an error.
kubeconform:
	@for f in $(CHART)/ci/*-values.yaml; do \
	  echo "== $$f"; \
	  helm template ci $(CHART) -f $$f --kube-version $(KUBE_VERSION) | \
	    docker run --rm -i ghcr.io/yannh/kubeconform:v0.6.7 -strict -summary \
	      -kubernetes-version $(KUBE_VERSION) \
	      -schema-location default \
	      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
	      - || exit 1; \
	done

e2e:
	helm upgrade --install $(RELEASE) $(CHART) -n $(NAMESPACE) --create-namespace \
	  -f $(E2E_VALUES) $(E2E_ARGS) --wait --timeout 10m
	helm test $(RELEASE) -n $(NAMESPACE) --logs --timeout 5m

e2e-clean:
	helm uninstall $(RELEASE) -n $(NAMESPACE) --ignore-not-found
	kubectl delete namespace $(NAMESPACE) --ignore-not-found
