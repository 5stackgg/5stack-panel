allow_k8s_contexts("default")
k8s_yaml(kustomize("./overlays/dev", kustomize_bin="./kustomize"))

# --- API ---
docker_build(
    "api",
    "../api",
)

# --- WEB (frontend) ---
docker_build(
    "web",
    "../web",
)

# # --- GAME SERVER ---
# docker_build(
#     "game-server",
#     "../game-server",
# )

# --- NODE CONNECTOR ---
docker_build(
    "game-server-node-connector",
    "../game-server-node-connector",
)
