allow_k8s_contexts('default')

k8s_yaml(kustomize("./overlays/dev", kustomize_bin="./kustomize"))

docker_build(
    "api",
    "../api",
)

docker_build(
    "web",
    "../web",
)

# docker_build(
#     "game-server",
#     "../game-server",
# )

docker_build(
    "game-server-node-connector",
    "../game-server-node-connector",
)

k8s_resource(
    'api',
    new_name='api',
    resource_deps=['timescaledb', 'redis', 'hasura'],
    port_forwards=['5585:5585'],
    labels=['application'],
)

k8s_resource(
    'web',
    new_name='web',
    resource_deps=['api'],
    port_forwards=['3000:3000'],
    labels=['application'],
)

k8s_resource(
    'game-server-node-connector',
    new_name='game-server-node-connector',
    resource_deps=['timescaledb', 'redis', 'hasura'],
    port_forwards=['8585:8585'],
    labels=['application'],
)

k8s_resource(
    'timescaledb',
    port_forwards=['5432:5432'],
    labels=['infrastructure'],
)

k8s_resource(
    'redis',
    port_forwards=['6379:6379'],
    labels=['infrastructure'],
)

k8s_resource(
    'typesense',
    port_forwards=['8108:8108'],
    labels=['infrastructure'],
)

k8s_resource(
    'minio',
    port_forwards=['9000:9000', '9090:9090'],
    labels=['infrastructure'],
)

k8s_resource(
    'hasura',
    port_forwards=['8080:8080'],
    resource_deps=['timescaledb'],
    labels=['application'],
)

k8s_resource(
    'dev-cs-server',
    port_forwards=['27015:27015', '27020:27020'],
    labels=['application'],
)