# Keep this digest in lockstep with the v1.102.1 release measured by the
# gateway contract and cost-attribution tests. The platform is linux/amd64.
FROM ghcr.io/berriai/litellm@sha256:f8043697479513b9ae6f3abac8e62d61b908cfd31541cc3c3c994e16a28d784e

COPY infra/litellm/config.yaml /etc/litellm/config.yaml

CMD ["--config", "/etc/litellm/config.yaml", "--port", "4000"]
