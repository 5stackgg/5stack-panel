allow_k8s_contexts('default')

dev_yaml = kustomize("./overlays/dev", kustomize_bin="./kustomize")

# CS2 or the simulated game server, as dev.sh chose (utils/dev_game_server.sh).
# The simulator is built from ../game-server, and Tilt swaps the api's
# SERVER_IMAGE for the image it pushed, so every match server the api launches
# is the simulator.
game_server = str(local('bash -c "source utils/dev_game_server.sh && dev_game_server"', quiet=True)).strip()

if game_server == 'simulator':
    SIMULATOR_IMAGE = 'ghcr.io/5stackgg/game-server-sim'

    docker_build(
        SIMULATOR_IMAGE,
        '../game-server',
        dockerfile='../game-server/apps/simulator/Dockerfile',
        only=[
            'Directory.Build.props',
            'shared/dotnet/FiveStack.Entities',
            'shared/dotnet/FiveStack.Enums',
            'apps/simulator',
        ],
        # game seconds per real second; ./dev.sh plays a map in about 1.5
        # minutes, SIM_SPEED=1 at CS2's own pace
        build_args={'SIM_SPEED': os.getenv('SIM_SPEED', '')},
        match_in_env_vars=True,
    )

    objects = decode_yaml_stream(dev_yaml)
    for o in objects:
        if o['kind'] == 'Deployment' and o['metadata']['name'] == 'api':
            for container in o['spec']['template']['spec']['containers']:
                if container['name'] == 'api':
                    container['env'] = container.get('env', []) + [
                        {'name': 'SERVER_IMAGE', 'value': SIMULATOR_IMAGE},
                    ]
    dev_yaml = encode_yaml_stream(objects)

k8s_yaml(dev_yaml)

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

# docker_build(
#     "ghcr.io/5stackgg/game-server:latest",
#     "../game-server",
#     dockerfile='../game-server/Dockerfile.dev',
#     live_update=[
#         sync('../game-server', '/opt/5stack'),
#     ],
# )

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
    links=['api.5stack.localhost', 'queues.5stack.localhost', 'tv.5stack.localhost'],
)

k8s_resource(
    'web',
    new_name='web',
    port_forwards=['3000:3000'],
    labels=['application'],
    links=['5stack.localhost'],
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
    'rustfs',
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
    'demo-parser',
    labels=['application'],
)

# k8s_resource(
#     'dev-game-server',
#     port_forwards=['27015:27015', '27020:27020'],
#     labels=['application'],
# )

k8s_resource(
    'postgres-backup',
    labels=['infrastructure'],
)

local_resource(
    'tls-secret',
    cmd=(
        'kubectl create secret tls 5stack-ssl ' +
        '--cert=overlays/dev/certs/_wildcard.5stack.localhost+1.pem ' +
        '--key=overlays/dev/certs/_wildcard.5stack.localhost+1-key.pem ' +
        '-n 5stack --dry-run=client -o yaml | kubectl apply -f -'
    ),
    labels=['tls-setup'],
    resource_deps=['web'],
)