# LocalAI cluster worker: lends this PC's NVIDIA GPU to the LocalAI server.
# Built and started by docker-compose.yml next to this file.
FROM localai/localai:latest-gpu-nvidia-cuda-12

ENV LOCALAI_SERVE_ADDR=0.0.0.0:50051 \
    LOCALAI_GRPC_MAX_PORT=50059 \
    LOCALAI_NODE_LABELS=gpu=nvidia \
    LLAMACPP_PARALLEL=5 \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    LOCALAI_DATA_DIRS="/models /backends /staging /cache" \
    GODEBUG=netdns=go \
    MODELS_PATH=/models

COPY worker-entrypoint.sh /usr/local/bin/worker-entrypoint.sh
# Files copied from Windows may have CRLF line endings and no exec bit.
RUN sed -i 's/\r$//' /usr/local/bin/worker-entrypoint.sh \
    && chmod 755 /usr/local/bin/worker-entrypoint.sh

# 50050 = model file transfer, 50051-50059 = one gRPC port per loaded model.
EXPOSE 50050-50059
ENTRYPOINT ["/usr/local/bin/worker-entrypoint.sh"]
