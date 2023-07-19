# How to deal with Helm Chart bundles

- [Helm](https://helm.sh/docs/intro/install/) and [Carvel tools](https://carvel.dev/) (`imgpkg` and `kbld` commands) must be installed beforehand

## push Helm Chart bundles to private Harbor

```
docker login ${HARBOR_HOST}
imgpkg copy --tar ${HELM_CHART_BUNDLE_NAME}.tar --to-repo ${HARBOR_HOST}/library/${HELM_CHART_BUNDLE_NAME} --registry-verify-certs=false
```

## load Helm Chart from private Harbor

```
BUNDLE_TAG=$(imgpkg tag list -i ${HARBOR_HOST}/library/${HELM_CHART_BUNDLE_NAME} --registry-verify-certs=false)
mkdir TMP
imgpkg pull -b ${HARBOR_HOST}/library/${HELM_CHART_BUNDLE_NAME}:${BUNDLE_TAG} -o TMP/ --registry-verify-certs=false
```

## check Helm Chart can use container images on private Harbor

```
helm template ${APP_NAME} TMP/ | kbld -f - -f TMP/.imgpkg/images.yml
```

## install apps using Helm Chart and container images on private Harbor

```
helm template ${APP_NAME} TMP/ -f values.yaml | kbld -f - -f TMP/.imgpkg/images.yml | kubectl apply -f -
```

