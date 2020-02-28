<?php
/**
 * Copyright © Magento, Inc. All rights reserved.
 * See COPYING.txt for license details.
 */
declare(strict_types=1);

namespace Magento\CloudDocker\Compose;

use Magento\CloudDocker\Compose\Php\ExtensionResolver;
use Magento\CloudDocker\Compose\ProductionBuilder\VolumeResolver;
use Magento\CloudDocker\Config\Config;
use Magento\CloudDocker\Config\Environment\Converter;
use Magento\CloudDocker\App\ConfigurationMismatchException;
use Magento\CloudDocker\Filesystem\FileList;
use Magento\CloudDocker\Service\ServiceFactory;
use Magento\CloudDocker\Service\ServiceInterface;

/**
 * Production compose configuration.
 *
 * @codeCoverageIgnore
 *
 * @SuppressWarnings(PHPMD.CouplingBetweenObjects)
 */
class ProductionBuilder implements BuilderInterface
{
    /**
     * @var array
     */
    private static $cliDepends = [
        self::SERVICE_DB => [
            'condition' => 'service_started'
        ],
        self::SERVICE_REDIS => [
            'condition' => 'service_started'
        ],
        self::SERVICE_ELASTICSEARCH => [
            'condition' => 'service_healthy'
        ],
        self::SERVICE_NODE => [
            'condition' => 'service_started'
        ],
        self::SERVICE_RABBITMQ => [
            'condition' => 'service_started'
        ]
    ];

    public const SYNC_ENGINE_MOUNT = 'mount';
    public const DEFAULT_SYNC_ENGINE = self::SYNC_ENGINE_MOUNT;

    public const SYNC_ENGINES_LIST = [
        self::SYNC_ENGINE_NATIVE,
        self::SYNC_ENGINE_MOUNT
    ];

    /**
     * @var array
     */
    private static $standaloneServices = [
        self::SERVICE_REDIS,
        self::SERVICE_ELASTICSEARCH,
        self::SERVICE_RABBITMQ,
    ];

    /**
     * @var ServiceFactory
     */
    private $serviceFactory;

    /**
     * @var Converter
     */
    private $converter;

    /**
     * @var FileList
     */
    private $fileList;

    /**
     * @var ExtensionResolver
     */
    private $phpExtension;

    /**
     * @var ManagerFactory
     */
    private $managerFactory;

    /**
     * @var Resolver
     */
    private $resolver;

    /**
     * @var VolumeResolver
     */
    private $volumeResolver;

    /**
     * @param ServiceFactory $serviceFactory
     * @param FileList $fileList
     * @param Converter $converter
     * @param ExtensionResolver $phpExtension
     * @param ManagerFactory $managerFactory
     * @param Resolver $resolver
     * @param VolumeResolver $volumeResolver
     */
    public function __construct(
        ServiceFactory $serviceFactory,
        FileList $fileList,
        Converter $converter,
        ExtensionResolver $phpExtension,
        ManagerFactory $managerFactory,
        Resolver $resolver,
        VolumeResolver $volumeResolver
    ) {
        $this->serviceFactory = $serviceFactory;
        $this->fileList = $fileList;
        $this->converter = $converter;
        $this->phpExtension = $phpExtension;
        $this->managerFactory = $managerFactory;
        $this->resolver = $resolver;
        $this->volumeResolver = $volumeResolver;
    }

    /**
     * {@inheritdoc}
     *
     * @SuppressWarnings(PHPMD.ExcessiveMethodLength)
     * @SuppressWarnings(PHPMD.CyclomaticComplexity)
     * @SuppressWarnings(PHPMD.NPathComplexity)
     */
    public function build(Config $config): Manager
    {
        $manager = $this->managerFactory->create();

        $phpVersion = $config->getServiceVersion(ServiceInterface::SERVICE_PHP);
        $dbVersion = $config->getServiceVersion(ServiceInterface::SERVICE_DB);
        $hostPort = $config->getDbPortsExpose();
        $dbPorts = $hostPort ? "$hostPort:3306" : '3306';

        $manager->addNetwork(self::NETWORK_MAGENTO_BUILD, ['driver' => 'bridge']);

        $volumes = [
            self::VOLUME_MAGENTO => [
                'driver_opts' => [
                    'type' => 'none',
                    'device' => $this->resolver->getRootPath(),
                    'o' => 'bind'
                ]
            ],
            self::VOLUME_MAGENTO_DB => [],
            self::VOLUME_MARIADB_CONF => [
                'driver_opts' => [
                    'type' => 'none',
                    'device' => $this->resolver->getRootPath('/.docker/mysql/mariadb.conf.d'),
                    'o' => 'bind',
                ],
            ],
            self::VOLUME_DOCKER_ETRYPOINT => [
                'driver_opts' => [
                    'type' => 'none',
                    'device' => $this->resolver->getRootPath('/.docker/mysql/docker-entrypoint-initdb.d'),
                    'o' => 'bind'
                ]
            ]
        ];

        if ($config->hasServiceEnabled(ServiceInterface::SERVICE_SELENIUM)) {
            $manager->addVolume(self::VOLUME_MAGENTO_DEV, []);
        }

        $mounts = $config->getMounts();
        $hasSelenium = $config->hasSelenium();
        $hasTmpMounts = $config->hasTmpMounts();

        if ($hasTmpMounts) {
            $volumes[self::VOLUME_DOCKER_MNT] = [
                'driver_opts' => [
                    'type' => 'none',
                    'device' => $this->resolver->getRootPath('/.docker/mnt'),
                    'o' => 'bind'
                ]
            ];
        }

        foreach ($this->volumeResolver->getMagentoVolumes($mounts, false, $hasSelenium) as $volumeName => $volume) {
            $syncConfig = [];

            if (!empty($volume['volume']) && $config->getSyncEngine() === self::SYNC_ENGINE_NATIVE) {
                $syncConfig = [
                    'driver_opts' => [
                        'type' => 'none',
                        'device' => $this->resolver->getRootPath($volume['volume']),
                        'o' => 'bind'
                    ]
                ];
            }
            $volumes[$volumeName] = $syncConfig;
        }

        if ($config->getSyncEngine() === self::SYNC_ENGINE_MOUNT) {
            $volumes[self::VOLUME_MAGENTO] = [
                'driver_opts' => [
                    'type' => 'none',
                    'device' => $this->resolver->getRootPath(),
                    'o' => 'bind'
                ]
            ];
        }

        if ($config->getMode() === BuilderFactory::BUILDER_PRODUCTION) {
            foreach ($volumes as $volumeName => $volume) {
                $volumes[$volumeName] = [];
            }
        }

        $manager->setVolumes($volumes);

        $volumesBuild = $this->volumeResolver->normalize(array_merge(
            $this->volumeResolver->getDefaultMagentoVolumes(false),
            $this->volumeResolver->getComposerVolumes()
        ));
        $volumesRo = $this->volumeResolver->normalize(array_merge(
            $this->volumeResolver->getMagentoVolumes($mounts, true, $hasSelenium),
            $this->volumeResolver->getMountVolumes($hasTmpMounts)
        ));
        $volumesRw = $this->volumeResolver->normalize(array_merge(
            $this->volumeResolver->getMagentoVolumes($mounts, false, $hasSelenium),
            $this->volumeResolver->getMountVolumes($hasTmpMounts),
            $this->volumeResolver->getComposerVolumes()
        ));
        $volumesMount = $this->volumeResolver->normalize(
            $this->volumeResolver->getMountVolumes($hasTmpMounts)
        );

        $manager->addService(
            self::SERVICE_DB,
            $this->serviceFactory->create(
                ServiceInterface::SERVICE_DB,
                $dbVersion,
                [
                    'ports' => [$dbPorts],
                    'volumes' => array_merge(
                        [
                            self::VOLUME_MAGENTO_DB . ':/var/lib/mysql',
                            self::VOLUME_DOCKER_ETRYPOINT . ':/docker-entrypoint-initdb.d',
                            self::VOLUME_MARIADB_CONF . ':/etc/mysql/mariadb.conf.d',
                        ],
                        $volumesMount
                    )
                ]
            ),
            [],
            []
        );

        foreach (self::$standaloneServices as $service) {
            if (!$config->hasServiceEnabled($service)) {
                continue;
            }

            $manager->addService(
                $service,
                $this->serviceFactory->create((string)$service, (string)$config->getServiceVersion($service)),
                [],
                []
            );
        }

        if ($config->hasServiceEnabled(self::SERVICE_NODE)) {
            $manager->addService(
                self::SERVICE_NODE,
                $this->serviceFactory->create(
                    ServiceInterface::SERVICE_NODE,
                    $config->getServiceVersion(ServiceInterface::SERVICE_NODE),
                    ['volumes' => $volumesRo]
                ),
                [],
                []
            );
        }

        $manager->addService(
            self::SERVICE_FPM,
            $this->serviceFactory->create(ServiceInterface::SERVICE_PHP_FPM, $phpVersion, ['volumes' => $volumesRo]),
            [],
            [self::SERVICE_DB => []]
        );
        $manager->addService(
            self::SERVICE_WEB,
            $this->serviceFactory->create(
                ServiceInterface::SERVICE_NGINX,
                $config->getServiceVersion(ServiceInterface::SERVICE_NGINX),
                [
                    'volumes' => $volumesRo,
                    'environment' => [
                        'VIRTUAL_HOST=magento2.docker',
                        'VIRTUAL_PORT=80',
                        'HTTPS_METHOD=noredirect',
                        'WITH_XDEBUG=' . (int)$config->hasServiceEnabled(ServiceInterface::SERVICE_FPM_XDEBUG)
                    ]
                ]
            ),
            [],
            [self::SERVICE_FPM => []]
        );

        if ($config->hasServiceEnabled(self::SERVICE_VARNISH)) {
            $manager->addService(
                self::SERVICE_VARNISH,
                $this->serviceFactory->create(
                    ServiceInterface::SERVICE_VARNISH,
                    $config->getServiceVersion(ServiceInterface::SERVICE_VARNISH),
                    []
                ),
                [],
                [self::SERVICE_WEB => []]
            );
        }

        $tlsBackendService = $config->hasServiceEnabled(ServiceInterface::SERVICE_VARNISH)
            ? self::SERVICE_VARNISH
            : self::SERVICE_WEB;
        $manager->addService(
            self::SERVICE_TLS,
            $this->serviceFactory->create(
                ServiceInterface::SERVICE_TLS,
                $config->getServiceVersion(ServiceInterface::SERVICE_TLS),
                [
                    'environment' => ['HTTPS_UPSTREAM_SERVER_ADDRESS' => $tlsBackendService],
                ]
            ),
            [],
            [$tlsBackendService => []]
        );

        if ($config->hasSelenium()) {
            $manager->addService(
                self::SERVICE_SELENIUM,
                $this->serviceFactory->create(
                    ServiceInterface::SERVICE_SELENIUM,
                    $config->getServiceVersion(ServiceInterface::SERVICE_SELENIUM),
                    [],
                    $config->getServiceImage(ServiceInterface::SERVICE_SELENIUM)
                ),
                [],
                [self::SERVICE_WEB => []]
            );
            $manager->addService(
                self::SERVICE_TEST,
                $this->serviceFactory->create(
                    ServiceInterface::SERVICE_PHP_CLI,
                    $phpVersion,
                    ['volumes' => $volumesRw]
                ),
                [],
                self::$cliDepends
            );
        }

        $phpExtensions = $this->phpExtension->get($config);

        /**
         * Include Xdebug if --with-xdebug is set
         */
        if ($config->hasServiceEnabled(ServiceInterface::SERVICE_FPM_XDEBUG)) {
            $manager->addService(
                self::SERVICE_FPM_XDEBUG,
                $this->serviceFactory->create(
                    ServiceInterface::SERVICE_FPM_XDEBUG,
                    $phpVersion,
                    [
                        'volumes' => $volumesRo,
                        'environment' => $this->converter->convert(['PHP_EXTENSIONS' => implode(' ', $phpExtensions)])
                    ]
                ),
                [],
                [self::SERVICE_DB => []]
            );
        }

        /**
         * Generic service.
         */
        $manager->addService(
            self::SERVICE_GENERIC,
            $this->serviceFactory->create(
                ServiceInterface::SERVICE_GENERIC,
                $config->getServiceVersion(self::SERVICE_GENERIC),
                [
                    'env_file' => './.docker/config.env',
                    'environment' => $this->converter->convert(['PHP_EXTENSIONS' => implode(' ', $phpExtensions)])
                ]
            ),
            [],
            []
        );
        $manager->addService(
            self::SERVICE_BUILD,
            $this->serviceFactory->create(ServiceInterface::SERVICE_PHP_CLI, $phpVersion, ['volumes' => $volumesBuild]),
            [self::NETWORK_MAGENTO_BUILD],
            []
        );
        $manager->addService(
            self::SERVICE_DEPLOY,
            $this->serviceFactory->create(ServiceInterface::SERVICE_PHP_CLI, $phpVersion, ['volumes' => $volumesRo]),
            [],
            self::$cliDepends
        );

        if ($config->hasCron()) {
            $manager->addService(
                self::SERVICE_CRON,
                array_merge(
                    $this->getCronCliService($config),
                    ['volumes' => $volumesRo]
                ),
                [],
                self::$cliDepends
            );
        }

        return $manager;
    }

    /**
     * @param Config $config
     * @return array
     * @throws ConfigurationMismatchException
     */
    private function getCronCliService(Config $config): array
    {
        $cron = $this->serviceFactory->create(
            ServiceInterface::SERVICE_PHP_CLI,
            $config->getServiceVersion(ServiceInterface::SERVICE_PHP),
            ['command' => 'run-cron']
        );
        $preparedCronConfig = [];

        foreach ($config->getCronJobs() as $job) {
            $preparedCronConfig[] = sprintf(
                '%s root cd %s && %s >> %s/var/log/cron.log',
                $job['schedule'],
                self::DIR_MAGENTO,
                str_replace('php ', '/usr/local/bin/php ', $job['command']),
                self::DIR_MAGENTO
            );
        }

        $cron['environment'] = [
            'CRONTAB' => implode(PHP_EOL, $preparedCronConfig)
        ];

        return $cron;
    }

    /**
     * @return string
     */
    public function getPath(): string
    {
        return $this->fileList->getMagentoDockerCompose();
    }
}
