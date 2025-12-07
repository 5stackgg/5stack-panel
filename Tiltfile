allow_k8s_contexts('default')

k8s_yaml(kustomize("./overlays/dev", kustomize_bin="./kustomize"))

local_resource(
    'tls-secret',
    cmd=(
        'kubectl create secret tls 5stack-ssl ' +
        '--cert=overlays/dev/certs/_wildcard.5stack.localhost+1.pem ' +
        '--key=overlays/dev/certs/_wildcard.5stack.localhost+1-key.pem ' +
        '-n 5stack --dry-run=client -o yaml | kubectl apply -f -'
    ),
    labels=['tls-setup'],
)

docker_build(
    "ghcr.io/5stackgg/api:latest",
    "../api",
    dockerfile='../api/Dockerfile.dev',
    live_update=[
        sync('../api', '/opt/5stack'),
        run('yarn install', trigger=['package.json', 'yarn.lock']),
    ],
)

docker_build(
    "ghcr.io/5stackgg/web:latest",
    "../web",
    dockerfile='../web/Dockerfile.dev',
    live_update=[
        sync('../web', '/opt/5stack'),
        run('yarn install', trigger=['package.json', 'yarn.lock']),
    ],
)

docker_build(
    "ghcr.io/5stackgg/game-server:latest",
    "../game-server",
    dockerfile='../game-server/Dockerfile.dev',
    live_update=[
        sync('../game-server', '/opt/5stack'),
    ],
)

docker_build(
    "ghcr.io/5stackgg/game-server-node-connector:latest",
    "../game-server-node-connector",
    dockerfile='../game-server-node-connector/Dockerfile.dev',
    live_update=[
        sync('../game-server-node-connector', '/opt/5stack'),
        run('yarn install', trigger=['package.json', 'yarn.lock']),
    ],
)

k8s_resource(
    'api',
    new_name='api',
    resource_deps=['timescaledb', 'redis', 'hasura'],
    port_forwards=['5585:5585'],
    labels=['application'],
    links=['api.5stack.localhost', 'queues.5stack.localhost'],
)

k8s_resource(
    'web',
    new_name='web',
    port_forwards=['3000:3000'],
    labels=['application'],
    links=['web.5stack.localhost'],
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
    links=['console.5stack.localhost'],
)

k8s_resource(
    'hasura',
    port_forwards=['8080:8080'],
    resource_deps=['timescaledb'],
    labels=['application'],
    links=['hasura.5stack.localhost'],
)

k8s_resource(
    'dev-cs-server',
    port_forwards=['27015:27015', '27020:27020'],
    labels=['application'],
)

k8s_resource(
    'steam-headless',
    port_forwards=['8083:8083', '31982:31982'],
    labels=['application'],
)

k8s_resource(
    'postgres-backup',
    labels=['infrastructure'],
)

