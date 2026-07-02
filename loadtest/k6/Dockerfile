# Custom k6 image with the test script + Cloud Run entrypoint baked in.
# Built once into the STANDARD load-test Artifact Registry repo (see
# terraform/loadtest.tf) so high task parallelism doesn't hammer Docker Hub.
FROM grafana/k6:latest

USER root
COPY loadtest.js /loadtest.js
COPY run-k6.sh /run-k6.sh
RUN chmod +x /run-k6.sh

ENTRYPOINT ["/run-k6.sh"]
