<?php
/**
 * Copyright © Magento, Inc. All rights reserved.
 * See COPYING.txt for license details.
 */
declare(strict_types=1);

namespace Magento\CloudDocker\Test\Functional\Codeception;

use Symfony\Component\Yaml\Yaml;

/**
 * The module to work with test infrastructure
 */
class TestInfrastructure extends BaseModule
{
    /**
     * Creates the work directory
     *
     * @return bool
     */
    public function createWorkDir(): bool
    {
        return $this->taskFilesystemStack()
            ->stopOnFail()
            ->mkdir($this->getWorkDirPath())
            ->run()
            ->wasSuccessful();
    }

    /**
     * Creates the directory for composer artifacts
     *
     * @return bool
     */
    public function createArtifactsDir(): bool
    {
        return $this->taskFilesystemStack()
            ->stopOnFail()
            ->mkdir($this->getArtifactsDir())
            ->run()
            ->wasSuccessful();
    }

    /**
     * Removes the work directory
     *
     * @return bool
     */
    public function removeWorkDir(): bool
    {
        return $this->taskDeleteDir($this->getWorkDirPath())
            ->run()
            ->stopOnFail()
            ->wasSuccessful();
    }

    /**
     * Cleans up the work directory
     *
     * @return bool
     */
    public function cleanupWorkDir(): bool
    {
        if (file_exists($this->getWorkDirPath())) {
            $this->removeWorkDir();
        }

        return $this->createWorkDir();
    }


    /**
     * Clones cloud template to the work directory
     *
     * @param string $branch
     * @return bool
     */
    public function cloneTemplateToWorkDir(string $branch = 'master'): bool
    {
        return $this->taskGitStack()
            ->printOutput($this->_getConfig('printOutput'))
            ->interactive(false)
            ->stopOnFail()
            ->printOutput($this->_getConfig('printOutput'))
            ->cloneRepo($this->_getConfig('template_repo'), '.', $branch)
            ->dir($this->getWorkDirPath())
            ->run()
            ->wasSuccessful();
    }

    /**
     * Starts docke-sync
     *
     * @return bool
     */
    public function startDockerSync(): bool
    {
        return $this->taskExec('docker-sync')
            ->arg('start')
            ->dir($this->getWorkDirPath())
            ->printOutput($this->_getConfig('printOutput'))
            ->interactive(false)
            ->run()
            ->wasSuccessful();
    }

    /**
     * Stops docker-sync
     *
     * @return bool
     */
    public function stopDockerSync(): bool
    {
        return $this->taskExec('docker-sync')
            ->arg('stop')
            ->dir($this->getWorkDirPath())
            ->printOutput($this->_getConfig('printOutput'))
            ->interactive(false)
            ->run()
            ->wasSuccessful();
    }

    /**
     * Creates auth.json file in the work directory
     *
     * @return bool
     */
    public function createAuthJson(): bool
    {
        $auth = [
            'http-basic' => [
                'repo.magento.com' => [
                    'username' => getenv('REPO_USERNAME'),
                    'password' => getenv('REPO_PASSWORD'),
                ]
            ],
        ];

        if (getenv('GITHUB_TOKEN')) {
            $auth['github-oauth'] = [
                'github.com' => getenv('GITHUB_TOKEN'),
            ];
        }

        return $this->taskWriteToFile($this->getWorkDirPath() . '/auth.json')
            ->line(json_encode($auth))
            ->run()
            ->wasSuccessful();
    }

    /**
     * Creates ZIP file with tested code
     *
     * @param string $name
     * @param string $version
     * @param array $skippedFiles
     * @return bool
     */
    public function createArtifactCurrentTestedCode(string $name, string $version, array $skippedFiles = []): bool
    {
        $composerPath = codecept_root_dir('composer.json');
        $composerRaw = trim(file_get_contents($composerPath));
        $composerArray = json_decode($composerRaw, true);
        $composerArray['version'] = $version;

        // Set needed version
        $resultTmpVersion = $this->taskWriteToFile($composerPath)
            ->line(json_encode($composerArray))
            ->run()
            ->wasSuccessful();

        $skippedFiles = array_merge(
            ['..', '.', 'vendor', '.git', '_workdir', 'vendor', 'composer.lock'],
            $skippedFiles
        );
        $files = [];

        foreach (array_diff(scandir(codecept_root_dir()), $skippedFiles) as $file) {
            $files[$file] = codecept_root_dir($file);
        }

        // ZIP files
        $resultZip = $this->taskPack($this->getArtifactsDir() . '/' . $name . '.zip')
            ->add($files)
            ->run()
            ->wasSuccessful();

        // Revert original version
        $resultRevert = $this->taskWriteToFile($composerPath)
            ->line($composerRaw)
            ->run()
            ->wasSuccessful();

        return $resultTmpVersion && $resultRevert && $resultZip;
    }

    /**
     * Creates ZIP file with code from codeception data directory
     *
     * @param string $name
     * @param string $path
     * @return bool
     */
    public function createArtifact(string $name, string $path): bool
    {
        $files = scandir(codecept_data_dir($path));

        // ZIP files
        return $this->taskPack($this->getArtifactsDir() . '/' . $name . '.zip')
            ->add($files)
            ->run()
            ->wasSuccessful();
    }

    /**
     * Adds repo with artifacts to composer.json
     *
     * @return bool
     */
    public function addArtifactsRepoToComposer(): bool
    {
        return $this->taskComposerConfig()
            ->set('repositories.artifacts', json_encode(
                [
                    'type' => 'artifact',
                    'url' => self::ARTIFACTS_DIR,
                ],
                JSON_UNESCAPED_SLASHES
            ))->noInteraction()
            ->printOutput($this->_getConfig('printOutput'))
            ->interactive(false)
            ->dir($this->getWorkDirPath())
            ->run()
            ->wasSuccessful();
    }

    /**
     * Adds some dependency to require section in composer.json
     *
     * @param string $name
     * @param string $version
     * @return bool
     */
    public function addDependencyToComposer(string $name, string $version): bool
    {
        return $this->taskComposerRequire('composer')
            ->dependency($name, $version)
            ->noInteraction()
            ->option('--no-update')
            ->printOutput($this->_getConfig('printOutput'))
            ->interactive(false)
            ->dir($this->getWorkDirPath())
            ->run()
            ->wasSuccessful();
    }

    /**
     * Adds ece-docker repo to composer.json
     *
     * @return bool
     */
    public function addEceDockerGitRepoToComposer(): bool
    {
        return $this->taskComposerConfig()
            ->set('repositories.ece-docker', json_encode(
                [
                    'type' => 'vcs',
                    'url' => $this->_getConfig('ece_docker_repo')
                ]
            ))->noInteraction()
            ->printOutput($this->_getConfig('printOutput'))
            ->interactive(false)
            ->dir($this->getWorkDirPath())
            ->run()
            ->wasSuccessful();
    }

    /**
     * Gets dependency version for tested code by name
     *
     * @param string $name
     * @return string
     */
    public function getDependencyVersion(string $name): string
    {
        $composer = json_decode(file_get_contents(codecept_root_dir('composer.json')), true);

        return $composer['require'][$name] ?? '';
    }

    /**
     * Runs bash command
     *
     * @param string $command
     * @return bool
     * @throws \Robo\Exception\TaskException
     */
    public function runBashCommand(string $command): bool
    {
        return $this->taskExecStack()
            ->printOutput($this->_getConfig('printOutput'))
            ->interactive(false)
            ->dir($this->getWorkDirPath())
            ->exec($command)
            ->run()
            ->wasSuccessful();
    }

    /**
     * Runs ece-docker commands
     *
     * @param string $command
     * @return bool
     * @throws \Robo\Exception\TaskException
     */
    public function runEceDockerCommand(string $command): bool
    {
        return $this->taskExecStack()
            ->stopOnFail()
            ->printOutput($this->_getConfig('printOutput'))
            ->interactive(false)
            ->dir($this->getWorkDirPath())
            ->exec(sprintf('./vendor/bin/ece-docker %s', $command))
            ->run()
            ->wasSuccessful();
    }

    /**
     * Runs composer update
     *
     * @return bool
     */
    public function composerUpdate(): bool
    {
        return $this->taskComposerUpdate('composer')
            ->printOutput($this->_getConfig('printOutput'))
            ->interactive(false)
            ->dir($this->getWorkDirPath())
            ->run()
            ->wasSuccessful();
    }

    /**
     * Copies file from _data to work directory
     *
     * @param string $source
     * @param string $destination
     * @param bool $overwrite
     * @return bool
     */
    public function copyFileToWorkDir(string $source, string $destination, bool $overwrite = true): bool
    {
        if (strpos($source, '/') !== 0) {
            $source = codecept_data_dir($source);
        }

        return $this->taskFilesystemStack()
            ->copy($source, $this->getWorkDirPath() . DIRECTORY_SEPARATOR . $destination, $overwrite)
            ->run()
            ->wasSuccessful();
    }

    /**
     * Copies directory from _data to work directory
     *
     * @param string $source
     * @param string $destination
     * @param bool $overwrite
     * @return bool
     */
    public function copyDirToWorkDir(string $source, string $destination, bool $overwrite = true): bool
    {
        if (strpos($source, '/') !== 0) {
            $source = codecept_data_dir($source);
        }

        return $this->taskCopyDir([$source => $this->getWorkDirPath() . DIRECTORY_SEPARATOR . $destination])
            ->overwrite($overwrite)
            ->run()
            ->wasSuccessful();
    }

    /**
     * Returns array from .magento.app.yaml
     *
     * @return array
     */
    public function readAppMagentoYaml(): array
    {
        return $this->readYamlConfiguration($this->getWorkDirPath() . DIRECTORY_SEPARATOR . self::MAGENTO_APP_YAML);
    }

    /**
     * Saves configuration in the .magento.app.yaml file
     *
     * @param array $data
     * @return bool
     */
    public function writeAppMagentoYaml(array $data): bool
    {
        return $this->writeYamlConfiguration(
            $this->getWorkDirPath() . DIRECTORY_SEPARATOR . self::MAGENTO_APP_YAML,
            $data
        );
    }

    /**
     * Returns array from .magento/services.yaml
     *
     * @return array
     */
    public function readServicesYaml(): array
    {
        return $this->readYamlConfiguration(
            $this->getWorkDirPath() . DIRECTORY_SEPARATOR . self::MAGENTO_SERVICES_YAML
        );
    }

    /**
     * Saves configuration in the .magento/services.yaml file
     *
     * @param array $data
     * @return bool
     */
    public function writeServicesYaml(array $data): bool
    {
        return $this->writeYamlConfiguration(
            $this->getWorkDirPath() . DIRECTORY_SEPARATOR . self::MAGENTO_SERVICES_YAML,
            $data
        );
    }

    /**
     * @param string $path
     * @return array
     */
    private function readYamlConfiguration(string $path): array
    {
        return Yaml::parseFile($path);
    }

    /**
     * @param string $path
     * @param array $data
     * @return bool
     */
    private function writeYamlConfiguration(string $path, array $data): bool
    {
        return $this->taskWriteToFile($path)
            ->line(Yaml::dump($data, 10, 4, Yaml::DUMP_MULTI_LINE_LITERAL_BLOCK))
            ->run()
            ->wasSuccessful();
    }
}
