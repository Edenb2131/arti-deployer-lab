#!/usr/bin/env python3
"""
deploy-artifacts.py — Populate the arti-deployer lab with realistic artifacts.

Add-on to arti-deployer-lab. Run AFTER `./arti-deployer up` so the AF
instance(s) are healthy. Defaults target art1 at http://localhost:8082
with admin/password — exactly matches the lab's out-of-the-box state.

Usage examples:
  ./deploy-artifacts.py                                  # docker+npm+pypi+maven+helm+nuget+generic on art1
  ./deploy-artifacts.py --repo-types docker maven helm   # custom subset
  ./deploy-artifacts.py --url http://localhost:8182      # target art2 instead
  ./deploy-artifacts.py --dry-run                        # preview only (DEBUG logs are on by default)
  ./deploy-artifacts.py -q                               # quieter: INFO level instead of DEBUG
  ./deploy-artifacts.py --release-bundles                # also create RBs

Capabilities:
  - 8 repo types: docker, npm, pypi, maven, helm, go, nuget, generic
  - For each: creates local + remote + virtual repos
  - Pulls real packages through the virtual repo (records JFrog Builds)
  - Optionally creates Release Bundles from the local repos
  - Dry-run, phase-skipping flags, JSON config file

Requires on PATH:
  - jf  (JFrog CLI — install: brew install jfrog-cli)
  - docker / npm / pip / go — only if those repo types are selected

Python deps:
  - requests  (pip install -r requirements.txt)
"""

import argparse
import json
import logging
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Optional

import requests


# ---------------------------------------------------------------------------
# Lightweight .env loader. The lab keeps its config (license, ports, optional
# corp-proxy overrides) in a sibling `.env` file. Bash's `./arti-deployer up`
# sources it natively; this Python script needs the same vars (especially
# the *_REMOTE_URL overrides used below), so we read .env at import time.
# Anything already in os.environ wins, so explicit `export` still overrides.
# ---------------------------------------------------------------------------
def _load_dotenv(path: str = ".env") -> None:
    if not os.path.exists(path):
        return
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                v = v.strip().strip('"').strip("'")
                os.environ.setdefault(k.strip(), v)
    except OSError:
        pass

_load_dotenv()

# ---------------------------------------------------------------------------
# Credential variables — fill these in directly OR use env vars / --flags.
# Priority: CLI flags > env vars (ARTIFACTORY_URL/USERNAME/PASSWORD) > these variables.
# ---------------------------------------------------------------------------
# ARTIFACTORY_URL      = "http://172.16.14.208:8082/"   # e.g. "http://172.16.1.128:8082"
# ARTIFACTORY_USERNAME = "admin"   # e.g. "admin"
# ARTIFACTORY_PASSWORD = "Password1!"   # e.g. "Password1!"

ARTIFACTORY_URL      = "http://localhost:8082/"   # e.g. "http://172.16.1.128:8082"
ARTIFACTORY_USERNAME = "admin"   # e.g. "admin"
ARTIFACTORY_PASSWORD = "password"   # e.g. "Password1!"
# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------

class ArtifactError(Exception):
    """Base exception."""

class ConfigError(ArtifactError):
    """Bad or missing configuration."""

class ArtifactoryError(ArtifactError):
    """HTTP-level failure from Artifactory API."""
    def __init__(self, message: str, status_code: Optional[int] = None):
        super().__init__(message)
        self.status_code = status_code

class ToolNotFoundError(ArtifactError):
    """Required CLI tool not found on PATH."""

class CommandError(ArtifactError):
    """Subprocess command failed."""
    def __init__(self, message: str, returncode: int, stderr: str = ""):
        super().__init__(message)
        self.returncode = returncode
        self.stderr = stderr

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------

def setup_logging(level: str = "INFO", log_file: Optional[str] = None) -> None:
    fmt = "%(asctime)s [%(levelname)-8s] %(name)s: %(message)s"
    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stderr)]
    if log_file:
        handlers.append(logging.FileHandler(log_file))
    logging.basicConfig(level=getattr(logging, level.upper(), logging.INFO), format=fmt, handlers=handlers)

# ---------------------------------------------------------------------------
# Configuration dataclasses
# ---------------------------------------------------------------------------

@dataclass
class ArtifactoryConfig:
    url: str
    username: str
    password: str
    jfrog_cli_name: str = "demo1-server"
    request_timeout: int = 30
    repo_settle_sleep: int = 2

@dataclass
class PackageConfig:
    # Docker: image names (pulled via jf docker pull)
    docker: list = field(default_factory=lambda: ["nginx", "httpd", "alpine", "ubuntu", "redis"])
    # NPM: package names (pulled via jf npm install)
    npm: list = field(default_factory=lambda: ["express", "vue", "react", "lodash", "axios"])
    # PyPI: package specs (pulled via jf pip install)
    pypi: list = field(default_factory=lambda: ["requests", "flask==3.1.1", "numpy", "pandas", "scikit-learn"])
    # Maven: artifact paths relative to repo root (pulled via jf rt dl)
    maven: list = field(default_factory=lambda: [
        "org/apache/commons/commons-lang3/3.12.0/commons-lang3-3.12.0.jar",
        "junit/junit/4.13.2/junit-4.13.2.jar",
    ])
    # Helm: chart tarball names (pulled via jf rt dl from helm repo)
    helm: list = field(default_factory=lambda: [
        "nginx-15.1.1.tgz",
        "redis-17.11.3.tgz",
    ])
    # Go: module proxy paths (pulled via jf rt dl from go repo)
    go: list = field(default_factory=lambda: [
        "github.com/gin-gonic/gin/@v/v1.9.1.zip",
        "github.com/gorilla/mux/@v/v1.8.1.zip",
    ])
    # NuGet: '<id>/<version>' specs (pulled via NuGet V2 Download endpoint)
    nuget: list = field(default_factory=lambda: [
        "Newtonsoft.Json/13.0.3",
        "log4net/2.0.15",
    ])
    # Generic: local filenames to create, upload, then download as test artifacts
    generic: list = field(default_factory=lambda: [
        "generic-artifact-1.txt",
        "generic-artifact-2.txt",
    ])

# Default resolve-server for the JFrog-internal Package Traffic Controller
# (PTC) SaaS. This lab is primarily for JFrog App Support / DSE colleagues
# whose corp network reroutes npmjs.org / pypi.org traffic to this same
# SaaS — so resolving npm/pypi directly from it sidesteps the corp block.
# It's anonymous-read, no creds needed. Non-JFrog users (or anyone whose
# corp doesn't run PTC) should set `JF_RESOLVE_URL=` (empty) in their .env
# to fall back to using the local AF's own remote-repo resolution.
DEFAULT_RESOLVE_URL = "https://jfrogrepo24.jfrog.io"


@dataclass
class ResolveServerConfig:
    """Second JFrog server to use for package resolution. When `url` is
    non-empty, `jf npmc` / `jf pipc` are configured with `--server-id-resolve`
    pointing here, while `--server-id-deploy` stays on the primary (lab)
    server. The lab AF still ends up with build-info and `npm publish`
    results, but the actual tarball/wheel downloads come straight from
    this resolve server (which doesn't need the lab AF's `baseUrl` to be
    Mac-reachable)."""
    url: str = DEFAULT_RESOLVE_URL
    server_id: str = "resolve-server"
    username: str = ""
    password: str = ""
    access_token: str = ""
    npm_repo: str = "npm-virtual"
    pypi_repo: str = "pypi-virtual"

    def is_enabled(self) -> bool:
        return bool(self.url)


@dataclass
class AppConfig:
    artifactory: ArtifactoryConfig
    packages: PackageConfig
    resolve_server: "ResolveServerConfig" = field(default_factory=lambda: ResolveServerConfig())
    repo_types: list = field(default_factory=lambda: ["docker", "npm", "pypi", "maven", "helm", "nuget", "generic"])
    dry_run: bool = False
    log_level: str = "INFO"
    log_file: Optional[str] = None
    release_bundles: bool = False
    build_name_prefix: str = ""
    skip_repo_creation: bool = False
    skip_pull: bool = False
    skip_build: bool = False
    skip_cleanup: bool = False

def load_config(config_path: Optional[str], cli_overrides: dict) -> AppConfig:
    """
    Priority (highest → lowest):
      1. CLI flags
      2. Environment variables
      3. Config JSON file
      4. Hardcoded defaults
    Raises ConfigError if url, username, or password cannot be resolved.
    """
    file_data: dict = {}
    if config_path and os.path.exists(config_path):
        try:
            with open(config_path) as f:
                file_data = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            raise ConfigError(f"Cannot read config file {config_path}: {e}") from e

    def resolve(key: str, file_key: str, default=None):
        if cli_overrides.get(key) is not None:
            return cli_overrides[key]
        env_val = os.environ.get(key.upper())
        if env_val is not None:
            return env_val
        if file_key in file_data:
            return file_data[file_key]
        return default

    url = (
        cli_overrides.get("url")
        or os.environ.get("ARTIFACTORY_URL")
        or file_data.get("url")
        or ARTIFACTORY_URL
        or None
    )
    username = (
        cli_overrides.get("username")
        or os.environ.get("ARTIFACTORY_USERNAME")
        or file_data.get("username")
        or ARTIFACTORY_USERNAME
        or None
    )
    password = (
        os.environ.get("ARTIFACTORY_PASSWORD")
        or file_data.get("password")
        or ARTIFACTORY_PASSWORD
        or None
    )

    if not url:
        raise ConfigError(
            "Artifactory URL not set. Set ARTIFACTORY_URL, use --url, or set ARTIFACTORY_URL variable in script."
        )
    if not username:
        raise ConfigError(
            "Username not set. Set ARTIFACTORY_USERNAME, use --username, or set ARTIFACTORY_USERNAME variable in script."
        )
    if not password:
        raise ConfigError(
            "Password not set. Set ARTIFACTORY_PASSWORD env var or set ARTIFACTORY_PASSWORD variable in script."
        )

    art_cfg = ArtifactoryConfig(
        url=url.rstrip("/"),
        username=username,
        password=password,
        jfrog_cli_name=file_data.get("jfrog_cli_name", "demo1-server"),
        request_timeout=int(file_data.get("request_timeout", 30)),
        repo_settle_sleep=int(file_data.get("repo_settle_sleep", 2)),
    )

    # Resolve-server (PTC SaaS) — default on, opt out by setting JF_RESOLVE_URL=""
    resolve_cfg = ResolveServerConfig(
        url=os.environ.get("JF_RESOLVE_URL", DEFAULT_RESOLVE_URL).rstrip("/"),
        server_id=os.environ.get("JF_RESOLVE_SERVER_ID", "resolve-server"),
        username=os.environ.get("JF_RESOLVE_USERNAME", ""),
        password=os.environ.get("JF_RESOLVE_PASSWORD", ""),
        access_token=os.environ.get("JF_RESOLVE_ACCESS_TOKEN", ""),
        npm_repo=os.environ.get("JF_RESOLVE_NPM_REPO", "npm-virtual"),
        pypi_repo=os.environ.get("JF_RESOLVE_PYPI_REPO", "pypi-virtual"),
    )

    pkg_defaults = PackageConfig()
    pkg_data = file_data.get("packages", {})
    pkg_cfg = PackageConfig(
        docker=pkg_data.get("docker", pkg_defaults.docker),
        npm=pkg_data.get("npm", pkg_defaults.npm),
        pypi=pkg_data.get("pypi", pkg_defaults.pypi),
        maven=pkg_data.get("maven", pkg_defaults.maven),
        helm=pkg_data.get("helm", pkg_defaults.helm),
        go=pkg_data.get("go", pkg_defaults.go),
        nuget=pkg_data.get("nuget", pkg_defaults.nuget),
        generic=pkg_data.get("generic", pkg_defaults.generic),
    )

    return AppConfig(
        artifactory=art_cfg,
        packages=pkg_cfg,
        resolve_server=resolve_cfg,
        repo_types=cli_overrides.get("repo_types") or file_data.get("repo_types", ["docker", "npm", "pypi", "maven", "helm", "nuget", "generic"]),
        dry_run=cli_overrides.get("dry_run", False),
        log_level=cli_overrides.get("log_level", file_data.get("log_level", "INFO")),
        log_file=cli_overrides.get("log_file"),
        release_bundles=cli_overrides.get("release_bundles", False),
        build_name_prefix=cli_overrides.get("build_name_prefix", ""),
        skip_repo_creation=cli_overrides.get("skip_repo_creation", False),
        skip_pull=cli_overrides.get("skip_pull", False),
        skip_build=cli_overrides.get("skip_build", False),
        skip_cleanup=cli_overrides.get("skip_cleanup", False),
    )

# ---------------------------------------------------------------------------
# Repository definitions
# ---------------------------------------------------------------------------

@dataclass
class RepoDefinition:
    package_type: str
    remote_url: str
    local_name: str
    remote_name: str
    virtual_name: str
    local_extra: dict = field(default_factory=dict)
    remote_extra: dict = field(default_factory=dict)
    virtual_extra: dict = field(default_factory=dict)

# Each upstream is overridable via a <TYPE>_REMOTE_URL env var (read from
# .env or the shell). Useful when the public default is blocked by a corp
# proxy that reroutes traffic to an internal JFrog instance — see README's
# "Corp network with rerouting/PTC" section.
REPO_DEFINITIONS: dict[str, RepoDefinition] = {
    "docker": RepoDefinition(
        package_type="docker",
        remote_url=os.environ.get("DOCKER_REMOTE_URL", "https://registry-1.docker.io"),
        local_name="docker-local",
        remote_name="docker-remote",
        virtual_name="docker-virtual",
        remote_extra={"enableTokenAuthentication": True},
    ),
    "npm": RepoDefinition(
        package_type="npm",
        remote_url=os.environ.get("NPM_REMOTE_URL", "https://registry.npmjs.org"),
        local_name="npm-local",
        remote_name="npm-remote",
        virtual_name="npm-virtual",
    ),
    "pypi": RepoDefinition(
        package_type="pypi",
        remote_url=os.environ.get("PYPI_REMOTE_URL", "https://files.pythonhosted.org"),
        local_name="pypi-local",
        remote_name="pypi-remote",
        virtual_name="pypi-virtual",
    ),
    "maven": RepoDefinition(
        package_type="maven",
        remote_url=os.environ.get("MAVEN_REMOTE_URL", "https://repo1.maven.org/maven2"),
        local_name="maven-local",
        remote_name="maven-remote",
        virtual_name="maven-virtual",
        local_extra={"repoLayoutRef": "maven-2-default"},
        remote_extra={"repoLayoutRef": "maven-2-default"},
        virtual_extra={
            "repoLayoutRef": "maven-2-default",
            "pomRepositoryReferencesCleanupPolicy": "discard_active_reference",
        },
    ),
    "helm": RepoDefinition(
        package_type="helm",
        remote_url=os.environ.get("HELM_REMOTE_URL", "https://charts.bitnami.com/bitnami"),
        local_name="helm-local",
        remote_name="helm-remote",
        virtual_name="helm-virtual",
    ),
    "go": RepoDefinition(
        package_type="go",
        remote_url=os.environ.get("GO_REMOTE_URL", "https://goproxy.io"),
        local_name="go-local",
        remote_name="go-remote",
        virtual_name="go-virtual",
    ),
    "nuget": RepoDefinition(
        package_type="nuget",
        remote_url=os.environ.get("NUGET_REMOTE_URL", "https://www.nuget.org"),
        local_name="nuget-local",
        remote_name="nuget-remote",
        virtual_name="nuget-virtual",
        remote_extra={
            "downloadContextPath": "api/v2/package",
            "feedContextPath": "api/v2",
        },
    ),
    "generic": RepoDefinition(
        package_type="generic",
        remote_url=os.environ.get("GENERIC_REMOTE_URL", "https://releases.hashicorp.com"),
        local_name="generic-local",
        remote_name="generic-remote",
        virtual_name="generic-virtual",
    ),
}

# ---------------------------------------------------------------------------
# Retry helper
# ---------------------------------------------------------------------------

def with_retries(fn, *, retries: int = 3, backoff_base: float = 1.0,
                 backoff_factor: float = 2.0,
                 retriable_exceptions=(requests.ConnectionError, requests.Timeout),
                 logger: logging.Logger):
    last_exc = None
    for attempt in range(retries):
        try:
            return fn()
        except retriable_exceptions as e:
            last_exc = e
            wait = backoff_base * (backoff_factor ** attempt)
            logger.warning("Attempt %d/%d failed (%s). Retrying in %.1fs...", attempt + 1, retries, e, wait)
            time.sleep(wait)
    raise last_exc

# ---------------------------------------------------------------------------
# ArtifactoryClient
# ---------------------------------------------------------------------------

class ArtifactoryClient:
    def __init__(self, config: ArtifactoryConfig, dry_run: bool = False):
        self._config = config
        self._dry_run = dry_run
        self._session = requests.Session()
        self._session.auth = (config.username, config.password)
        self._session.headers.update({"Content-Type": "application/json"})
        self._log = logging.getLogger("artifactory.client")

    def check_connectivity(self) -> bool:
        url = f"{self._config.url}/artifactory/api/system/ping"
        self._log.debug("Connectivity check: GET %s", url)
        if self._dry_run:
            self._log.info("DRY RUN: would GET %s", url)
            return True
        try:
            resp = self._session.get(url, timeout=self._config.request_timeout)
            return resp.status_code == 200
        except requests.RequestException as e:
            self._log.error("Connectivity check failed: %s", e)
            return False

    def create_repo(self, repo_name: str, payload: dict) -> str:
        """Returns 'created', 'exists', or raises ArtifactoryError."""
        url = f"{self._config.url}/artifactory/api/repositories/{repo_name}"
        self._log.debug("Creating repo %s: PUT %s", repo_name, url)
        if self._dry_run:
            self._log.info("DRY RUN: would PUT %s with rclass=%s", url, payload.get("rclass"))
            return "created"

        def do_put():
            return self._session.put(url, json=payload, timeout=self._config.request_timeout)

        try:
            resp = with_retries(do_put, logger=self._log)
        except (requests.ConnectionError, requests.Timeout) as e:
            raise ArtifactoryError(f"Network error creating repo {repo_name}: {e}") from e

        if resp.status_code in (200, 201):
            self._log.info("Created repo: %s", repo_name)
            return "created"
        if resp.status_code == 400 and "already exists" in resp.text:
            self._log.info("Repo already exists: %s", repo_name)
            return "exists"
        raise ArtifactoryError(
            f"Failed to create repo {repo_name} (HTTP {resp.status_code}): {resp.text}",
            status_code=resp.status_code,
        )

    def pull_through(self, repo_path: str) -> bool:
        """GET an artifact via the virtual repo path to trigger Artifactory's
        pull-through cache load from the upstream. Plain `jf rt dl` against a
        virtual repo only finds artifacts already cached (AQL search), so for
        cold caches we need an HTTP GET first."""
        url = f"{self._config.url}/artifactory/{repo_path.lstrip('/')}"
        self._log.debug("Pull-through GET %s", url)
        if self._dry_run:
            self._log.info("DRY RUN: would GET %s", url)
            return True
        try:
            with self._session.get(
                url, stream=True, timeout=self._config.request_timeout * 4
            ) as resp:
                for _ in resp.iter_content(chunk_size=65536):
                    pass
                if resp.status_code == 200:
                    return True
                self._log.warning("Pull-through %s returned HTTP %d", url, resp.status_code)
                return False
        except requests.RequestException as e:
            self._log.error("Pull-through failed for %s: %s", url, e)
            return False

    def check_remote_reachable(self, api_path: str) -> tuple[bool, str]:
        """GET a sample artifact through a remote repo to confirm AF can reach
        the upstream registry. Returns (ok, reason)."""
        url = f"{self._config.url}{api_path}"
        if self._dry_run:
            self._log.info("DRY RUN: would GET %s", url)
            return True, "dry-run"
        try:
            resp = self._session.get(url, timeout=self._config.request_timeout)
        except requests.RequestException as e:
            return False, f"network error: {e}"
        if resp.status_code == 200:
            return True, "OK"
        return False, f"HTTP {resp.status_code} from {url}"

    def create_release_bundle(self, name: str, version: str, repo_name: str) -> None:
        url = f"{self._config.url}/lifecycle/api/v2/release_bundle"
        payload = {
            "release_bundle_name": name,
            "release_bundle_version": version,
            "source_type": "aql",
            "source": {
                "aql": f'items.find({{"repo":"{repo_name}"}})'
            },
        }
        self._log.debug("Creating release bundle %s:%s", name, version)
        if self._dry_run:
            self._log.info("DRY RUN: would POST release bundle %s:%s", name, version)
            return

        try:
            resp = self._session.post(url, json=payload, timeout=self._config.request_timeout)
        except requests.RequestException as e:
            raise ArtifactoryError(f"Network error creating release bundle {name}: {e}") from e

        if resp.status_code in (200, 201):
            self._log.info("Created release bundle: %s:%s", name, version)
        else:
            raise ArtifactoryError(
                f"Failed to create release bundle {name} (HTTP {resp.status_code}): {resp.text}",
                status_code=resp.status_code,
            )

# ---------------------------------------------------------------------------
# JFrogCLI
# ---------------------------------------------------------------------------

PACKAGE_JSON_PATH = "package.json"
BASE_PACKAGE_JSON = {
    "name": "create-artifacts-for-new-deploy",
    "version": "1.0.0",
    "dependencies": {},
}

# Dedicated venv for `jf pip install` so PEP 668 system Pythons (Homebrew,
# recent Debian/Ubuntu, etc.) don't refuse the install. Lives under the
# gitignored .arti-deployer/ dir and persists across runs.
PYPI_VENV_PATH = os.path.join(".arti-deployer", "pypi-venv")

# Target dir for `jf rt dl` so maven/helm/nuget/generic downloads don't
# scatter nupkg/tgz files and nested dirs (org/, junit/, ...) across the
# working tree. Wiped at the end of cleanup().
DOWNLOAD_DIR = os.path.join(".arti-deployer", "downloads")

class JFrogCLI:
    def __init__(self, config: ArtifactoryConfig, dry_run: bool = False):
        self._config = config
        self._dry_run = dry_run
        self._log = logging.getLogger("jfrog.cli")

    def _redact(self, cmd: list) -> list:
        return ["***" if token == self._config.password else token for token in cmd]

    def _run(self, cmd: list, description: str, *, check: bool = True,
             retries: int = 1, env: Optional[dict] = None) -> subprocess.CompletedProcess:
        redacted = " ".join(self._redact(cmd))
        self._log.debug("Running [%s]: %s", description, redacted)
        if self._dry_run:
            self._log.info("DRY RUN: would run: %s", redacted)
            return subprocess.CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

        last_exc = None
        for attempt in range(max(retries, 1)):
            try:
                result = subprocess.run(
                    cmd, check=check, capture_output=True, text=True, env=env
                )
                if result.stdout:
                    self._log.debug("stdout: %s", result.stdout.strip())
                return result
            except subprocess.CalledProcessError as e:
                last_exc = e
                stderr_msg = e.stderr.strip() if e.stderr else ""
                if attempt < retries - 1:
                    wait = 2 ** attempt
                    self._log.warning(
                        "Command failed (attempt %d/%d): %s. Retrying in %ds...",
                        attempt + 1, retries, redacted, wait,
                    )
                    time.sleep(wait)
                else:
                    self._log.error("Command failed: %s", redacted)
                    if stderr_msg:
                        self._log.error("stderr: %s", stderr_msg)
                    raise CommandError(
                        f"{description} failed (exit {e.returncode})",
                        returncode=e.returncode,
                        stderr=stderr_msg,
                    ) from e
        raise last_exc  # unreachable but satisfies type checker

    def check_tool(self, tool: str) -> None:
        try:
            subprocess.run(
                ["which", tool], check=True, capture_output=True
            )
        except subprocess.CalledProcessError:
            raise ToolNotFoundError(
                f"Required tool '{tool}' not found on PATH. Please install it before running."
            )

    def login(self) -> None:
        cfg = self._config
        self._run(
            ["jf", "c", "add", "--interactive=false",
             "--url", cfg.url,
             "--user", cfg.username,
             "--password", cfg.password,
             cfg.jfrog_cli_name],
            "JFrog CLI login",
        )
        self._run(["jf", "c", "use", cfg.jfrog_cli_name], "Set JFrog CLI context")

    def logout(self) -> None:
        try:
            self._run(["jf", "c", "remove", self._config.jfrog_cli_name, "--quiet"],
                      f"JFrog CLI logout ({self._config.jfrog_cli_name})")
        except (CommandError, Exception) as e:
            self._log.warning("Logout failed (non-critical): %s", e)

    def npm_pack(self, pkg: str, registry: str, dest_dir: str) -> dict:
        """Download a package tarball via `npm pack` (no install, no
        deps). Returns dict with name/version/filename keys. Uses plain
        npm to sidestep `jf npm`'s anonymous-auth behavior which is
        rejected by SaaS instances configured for true anonymous read."""
        cmd = ["npm", "pack", pkg, f"--registry={registry}", "--json", "--silent"]
        if self._dry_run:
            self._log.info("DRY RUN: would run: %s in %s", " ".join(cmd), dest_dir)
            return {"name": pkg.split("@")[0] or pkg, "version": "dry", "filename": f"{pkg}-dry.tgz"}
        try:
            result = subprocess.run(cmd, cwd=dest_dir, check=True, capture_output=True, text=True)
            data = json.loads(result.stdout)
            entry = data[0] if isinstance(data, list) else data
            return {"name": entry["name"], "version": entry["version"], "filename": entry["filename"]}
        except subprocess.CalledProcessError as e:
            raise CommandError(f"npm pack {pkg} failed (exit {e.returncode})",
                               returncode=e.returncode, stderr=(e.stderr or "").strip()) from e
        except (json.JSONDecodeError, KeyError, IndexError) as e:
            raise ArtifactError(f"npm pack {pkg} returned unexpected output: {e}") from e

    def pip_download(self, pkg: str, index_url: str, dest_dir: str) -> list:
        """Download package files via `pip download --no-deps`. Returns the
        list of new file paths in dest_dir. Runs inside the dedicated pypi
        venv to avoid PEP 668."""
        self.ensure_pypi_venv()
        cmd = [
            "pip", "download", pkg,
            "--no-deps",
            "--dest", dest_dir,
            "--index-url", index_url,
            "--no-cache-dir",
        ]
        if self._dry_run:
            self._log.info("DRY RUN: would run: %s", " ".join(cmd))
            return []
        before = set(os.listdir(dest_dir)) if os.path.isdir(dest_dir) else set()
        try:
            subprocess.run(cmd, check=True, capture_output=True, text=True, env=self._pypi_venv_env())
        except subprocess.CalledProcessError as e:
            raise CommandError(f"pip download {pkg} failed (exit {e.returncode})",
                               returncode=e.returncode, stderr=(e.stderr or "").strip()) from e
        after = set(os.listdir(dest_dir)) if os.path.isdir(dest_dir) else set()
        return [os.path.join(dest_dir, f) for f in (after - before)]

    def ensure_pypi_venv(self) -> None:
        """Create the dedicated pip venv if missing. Required on PEP 668 systems
        (Homebrew Python, recent Debian/Ubuntu) where `pip install` against the
        system interpreter is refused."""
        venv_path = os.path.abspath(PYPI_VENV_PATH)
        if os.path.isdir(os.path.join(venv_path, "bin")):
            self._log.debug("PyPI venv already exists at %s", venv_path)
            return
        if self._dry_run:
            self._log.info("DRY RUN: would create PyPI venv at %s", venv_path)
            return
        os.makedirs(os.path.dirname(venv_path), exist_ok=True)
        self._log.info("Creating PyPI venv at %s (one-time)", venv_path)
        try:
            subprocess.run(
                [sys.executable, "-m", "venv", venv_path],
                check=True, capture_output=True, text=True,
            )
        except subprocess.CalledProcessError as e:
            raise ArtifactError(
                f"Failed to create venv at {venv_path}: {e.stderr.strip() or e}"
            ) from e

    def _pypi_venv_env(self) -> dict:
        """Build a subprocess env that activates the PyPI venv (PATH + VIRTUAL_ENV)."""
        venv_path = os.path.abspath(PYPI_VENV_PATH)
        venv_bin = os.path.join(venv_path, "bin")
        env = os.environ.copy()
        env["PATH"] = f"{venv_bin}{os.pathsep}{env.get('PATH', '')}"
        env["VIRTUAL_ENV"] = venv_path
        env.pop("PYTHONHOME", None)
        return env

    def docker_login(self, registry: str) -> None:
        cfg = self._config
        self._run(
            ["docker", "login", registry, "-u", cfg.username, "-p", cfg.password],
            f"Docker login to {registry}",
        )

    def docker_pull(self, image_ref: str, build_name: str, build_number: str) -> None:
        self._run(
            ["jf", "docker", "pull", image_ref,
             "--build-name", build_name, "--build-number", build_number],
            f"Docker pull {image_ref}",
            retries=2,
        )

    def npm_install(self, pkg: str, build_name: str, build_number: str) -> None:
        self._run(
            ["jf", "npm", "install", pkg,
             "--build-name", build_name, "--build-number", build_number],
            f"npm install {pkg}",
        )

    def pip_install(self, pkg: str, clean_url: str, build_name: str, build_number: str) -> None:
        self._run(
            ["jf", "pip", "install", pkg,
             "--trusted-host", clean_url,
             "--build-name", build_name,
             "--build-number", build_number,
             "--no-cache-dir", "--force-reinstall"],
            f"pip install {pkg}",
            env=self._pypi_venv_env(),
        )

    def collect_env(self, build_name: str, build_number: str) -> None:
        self._run(["jf", "rt", "bce", build_name, build_number], "Collect env vars")

    def publish_build(self, build_name: str, build_number: str) -> None:
        self._run(["jf", "rt", "bp", build_name, build_number], f"Publish build {build_name}")

    def npm_publish(self, build_name: str, build_number: str) -> None:
        self._run(
            ["jf", "npm", "publish",
             "--build-name", build_name, "--build-number", build_number],
            "npm publish",
        )

    def ensure_package_json(self) -> dict:
        if not os.path.exists(PACKAGE_JSON_PATH):
            if not self._dry_run:
                try:
                    with open(PACKAGE_JSON_PATH, "w") as f:
                        json.dump(BASE_PACKAGE_JSON, f, indent=2)
                except OSError as e:
                    raise ArtifactError(f"Cannot write package.json: {e}") from e
            return dict(BASE_PACKAGE_JSON)
        try:
            with open(PACKAGE_JSON_PATH) as f:
                return json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            raise ArtifactError(f"Cannot read package.json: {e}") from e

    def save_package_json(self, data: dict) -> None:
        if self._dry_run:
            self._log.debug("DRY RUN: would write package.json")
            return
        try:
            with open(PACKAGE_JSON_PATH, "w") as f:
                json.dump(data, f, indent=2)
        except OSError as e:
            raise ArtifactError(f"Cannot write package.json: {e}") from e

    def add_npm_dependency(self, pkg_name: str) -> None:
        data = self.ensure_package_json()
        data.setdefault("dependencies", {})
        if pkg_name not in data["dependencies"]:
            data["dependencies"][pkg_name] = "*"
        self.save_package_json(data)

    def setup_go(self, virtual_repo: str) -> None:
        cfg = self._config
        self._run(
            ["jf", "go-config",
             "--server-id-resolve", cfg.jfrog_cli_name,
             "--repo-resolve", virtual_repo],
            "Setup Go resolver",
        )

    def rt_download(self, artifact_path: str, build_name: str, build_number: str,
                    target: Optional[str] = None) -> None:
        cmd = ["jf", "rt", "dl", artifact_path]
        if target:
            cmd.append(target)
        cmd += ["--build-name", build_name, "--build-number", build_number]
        desc = f"Download {artifact_path}" + (f" -> {target}" if target else "")
        self._run(cmd, desc, retries=2)

    def rt_upload(self, local_path: str, target: str, build_name: str, build_number: str) -> None:
        self._run(
            ["jf", "rt", "upload", local_path, target,
             "--build-name", build_name, "--build-number", build_number],
            f"Upload {local_path} -> {target}",
        )

# ---------------------------------------------------------------------------
# WorkflowRunner
# ---------------------------------------------------------------------------

class WorkflowRunner:
    def __init__(self, config: AppConfig):
        self._config = config
        self._client = ArtifactoryClient(config.artifactory, config.dry_run)
        self._cli = JFrogCLI(config.artifactory, config.dry_run)
        self._log = logging.getLogger("workflow")
        self._build_number = str(int(time.time()))
        # host:port without scheme — used for docker login and pip --trusted-host
        url_no_scheme = config.artifactory.url.replace("http://", "").replace("https://", "")
        self._clean_url = url_no_scheme
        # Types whose pull phase was skipped (e.g. preflight failure). Used
        # by create_builds to avoid trying to publish a build that has no
        # artifacts and would only produce misleading errors (e.g. `npm
        # publish` ENOENT on a missing package.json).
        self._skipped_pull: set[str] = set()

    def _build_name(self, pkg_type: str) -> str:
        return f"{self._config.build_name_prefix}{pkg_type}"

    def preflight(self) -> None:
        self._log.info("Running pre-flight checks...")
        if not self._client.check_connectivity():
            raise ArtifactoryError(
                f"Cannot reach Artifactory at {self._config.artifactory.url}. Aborting."
            )
        self._log.info("Artifactory connectivity OK")

        # Always need jf
        self._cli.check_tool("jf")
        selected = self._config.repo_types
        if "docker" in selected:
            self._cli.check_tool("docker")
        if "npm" in selected:
            self._cli.check_tool("npm")
        if "pypi" in selected:
            self._cli.check_tool("pip")
        if "go" in selected:
            self._cli.check_tool("go")
        self._log.info("All required tools found on PATH")

    def create_repos(self, types: list) -> None:
        self._log.info("Creating repositories for types: %s", types)
        failures = []
        for pkg_type in types:
            if pkg_type not in REPO_DEFINITIONS:
                self._log.warning("Unknown repo type '%s', skipping.", pkg_type)
                continue
            rd = REPO_DEFINITIONS[pkg_type]
            for (repo_name, rclass, extra) in [
                (rd.local_name,   "local",   rd.local_extra),
                (rd.remote_name,  "remote",  rd.remote_extra),
                (rd.virtual_name, "virtual", rd.virtual_extra),
            ]:
                payload = self._build_repo_payload(rclass, rd, extra)
                try:
                    self._client.create_repo(repo_name, payload)
                except ArtifactoryError as e:
                    self._log.warning("Non-fatal repo error for %s: %s", repo_name, e)
                    failures.append(repo_name)

        if failures:
            self._log.warning("Repo creation had failures for: %s", failures)

        sleep_sec = self._config.artifactory.repo_settle_sleep
        self._log.debug("Sleeping %ds for repos to settle...", sleep_sec)
        if not self._config.dry_run:
            time.sleep(sleep_sec)

    def _build_repo_payload(self, rclass: str, rd: RepoDefinition, extra: dict) -> dict:
        base: dict
        if rclass == "local":
            base = {"rclass": "local", "packageType": rd.package_type}
        elif rclass == "remote":
            base = {"rclass": "remote", "url": rd.remote_url, "packageType": rd.package_type}
        elif rclass == "virtual":
            base = {
                "rclass": "virtual",
                "packageType": rd.package_type,
                "repositories": [rd.local_name, rd.remote_name],
                "defaultDeploymentRepo": rd.local_name,
            }
        else:
            raise ValueError(f"Unknown rclass: {rclass}")
        base.update(extra)
        return base

    def configure_cli(self, types: list) -> None:
        self._log.info("Configuring JFrog CLI...")
        self._cli.login()  # raises CommandError on failure (fail-fast)
        if self._config.resolve_server.is_enabled():
            self._log.info(
                "npm/pypi will resolve from %s and upload tarballs to %s (lab AF).",
                self._config.resolve_server.url, self._config.artifactory.jfrog_cli_name,
            )
        if "pypi" in types:
            # Create the venv up front so it's ready by the time we run pip download.
            self._cli.ensure_pypi_venv()
        if "go" in types:
            self._cli.setup_go(REPO_DEFINITIONS["go"].virtual_name)

    def pull_artifacts(self, types: list) -> None:
        self._log.info("Pulling artifacts...")
        dispatch = {
            "docker":  lambda: self._pull_docker(self._config.packages.docker),
            "npm":     lambda: self._pull_npm(self._config.packages.npm),
            "pypi":    lambda: self._pull_pypi(self._config.packages.pypi),
            "maven":   lambda: self._pull_via_rt_dl("maven", self._config.packages.maven),
            "helm":    lambda: self._pull_via_rt_dl("helm", self._config.packages.helm),
            "go":      lambda: self._pull_via_rt_dl("go", self._config.packages.go),
            "nuget":   lambda: self._pull_nuget(self._config.packages.nuget),
            "generic": lambda: self._pull_generic(self._config.packages.generic),
        }
        for t in types:
            if t in dispatch:
                dispatch[t]()

    def _pull_docker(self, images: list) -> None:
        if not images:
            return
        virtual_repo = REPO_DEFINITIONS["docker"].virtual_name
        registry = f"{self._clean_url}/{virtual_repo}"
        try:
            self._cli.docker_login(self._clean_url)
        except CommandError as e:
            self._log.error("Docker login failed, skipping all docker pulls: %s", e)
            return
        build_name = self._build_name("docker")
        for image in images:
            image_ref = f"{registry}/{image}"
            try:
                self._cli.docker_pull(image_ref, build_name, self._build_number)
            except CommandError as e:
                self._log.error("Failed to pull docker image %s: %s", image, e)

    def _pull_npm(self, packages: list) -> None:
        """Two-step: download tarballs from the resolve server (jfrogrepo24
        by default) via plain `npm pack`, then `jf rt upload` them into the
        lab AF's npm-local. Build-info is collected via the upload's
        --build-name/--build-number flags.

        Plain `npm pack` avoids the `jf npm install` "anonymous user
        couldn't be found" error against PTC-style SaaS, and avoids the
        baseUrl/tarball-URL problem of resolving through the local AF."""
        if not packages:
            return
        resolve = self._config.resolve_server
        if not resolve.is_enabled():
            self._log.warning(
                "JF_RESOLVE_URL is unset, so there's no upstream to pull npm "
                "tarballs from. Skipping. (Set JF_RESOLVE_URL=https://jfrogrepo24.jfrog.io "
                "in .env to use the JFrog PTC SaaS.)"
            )
            self._skipped_pull.add("npm")
            return
        registry = f"{resolve.url.rstrip('/')}/artifactory/api/npm/{resolve.npm_repo}/"
        build_name = self._build_name("npm")
        rd = REPO_DEFINITIONS["npm"]
        staging = os.path.abspath(os.path.join(DOWNLOAD_DIR, "npm"))
        if not self._config.dry_run:
            os.makedirs(staging, exist_ok=True)
        successes = 0
        for pkg in packages:
            try:
                info = self._cli.npm_pack(pkg, registry, staging)
                tarball_path = os.path.join(staging, info["filename"])
                # AF npm-local conventional storage path: <name>/-/<filename>
                target = f"{rd.local_name}/{info['name']}/-/{info['filename']}"
                self._cli.rt_upload(tarball_path, target, build_name, self._build_number)
                successes += 1
            except (CommandError, ArtifactError) as e:
                self._log.error("Failed to populate npm/%s: %s", pkg, e)
        if successes == 0:
            self._skipped_pull.add("npm")

    def _pull_pypi(self, packages: list) -> None:
        """Plain `pip download` from the resolve server, then `jf rt upload`
        each downloaded wheel/sdist to the lab AF's pypi-local."""
        if not packages:
            return
        resolve = self._config.resolve_server
        if not resolve.is_enabled():
            self._log.warning(
                "JF_RESOLVE_URL is unset, so there's no upstream to pull pypi "
                "wheels from. Skipping. (Set JF_RESOLVE_URL=https://jfrogrepo24.jfrog.io "
                "in .env to use the JFrog PTC SaaS.)"
            )
            self._skipped_pull.add("pypi")
            return
        index_url = f"{resolve.url.rstrip('/')}/artifactory/api/pypi/{resolve.pypi_repo}/simple"
        build_name = self._build_name("pypi")
        rd = REPO_DEFINITIONS["pypi"]
        staging = os.path.abspath(os.path.join(DOWNLOAD_DIR, "pypi"))
        if not self._config.dry_run:
            os.makedirs(staging, exist_ok=True)
        successes = 0
        for pkg in packages:
            try:
                files = self._cli.pip_download(pkg, index_url, staging)
                for f in files:
                    target = f"{rd.local_name}/{os.path.basename(f)}"
                    self._cli.rt_upload(f, target, build_name, self._build_number)
                    successes += 1
            except (CommandError, ArtifactError) as e:
                self._log.error("Failed to populate pypi/%s: %s", pkg, e)
        if successes == 0:
            self._skipped_pull.add("pypi")

    def _pull_via_rt_dl(self, pkg_type: str, artifact_paths: list) -> None:
        """Two-step pull: HTTP GET against the virtual repo path to trigger
        Artifactory's cache load (since `jf rt dl` alone runs an AQL search
        and won't fetch cold artifacts from upstream), then `jf rt dl` to
        download locally + record build-info against the now-cached file."""
        if not artifact_paths:
            return
        rd = REPO_DEFINITIONS[pkg_type]
        build_name = self._build_name(pkg_type)
        successes = 0
        for path in artifact_paths:
            repo_path = f"{rd.virtual_name}/{path}"
            if not self._client.pull_through(repo_path):
                self._log.error(
                    "Cache load failed for %s/%s — skipping rt dl. "
                    "Check %s-remote URL/auth and the AF Test button.",
                    pkg_type, path, pkg_type,
                )
                continue
            try:
                self._cli.rt_download(repo_path, build_name, self._build_number, target=f"{DOWNLOAD_DIR}/")
                successes += 1
            except CommandError as e:
                self._log.error("Failed to download %s artifact %s: %s", pkg_type, path, e)
        if successes == 0:
            # Nothing downloaded → no point publishing a build with empty info.
            self._skipped_pull.add(pkg_type)

    def _pull_nuget(self, package_specs: list) -> None:
        """NuGet pull-through goes via AF's V2 Download endpoint, not the
        plain repo path used by maven/helm. AF stores the resulting nupkg
        flat in <remote>-cache as <id>.<version>.nupkg (no nested dirs),
        which is the path we then `jf rt dl` against for build-info."""
        if not package_specs:
            return
        rd = REPO_DEFINITIONS["nuget"]
        build_name = self._build_name("nuget")
        successes = 0
        for spec in package_specs:
            if "/" not in spec:
                self._log.error("Invalid nuget spec %r (expected '<id>/<version>')", spec)
                continue
            pkg_id, pkg_version = spec.split("/", 1)
            download_path = f"api/nuget/{rd.virtual_name}/Download/{pkg_id}/{pkg_version}"
            if not self._client.pull_through(download_path):
                self._log.error("Cache load failed for nuget/%s", spec)
                continue
            cached_path = f"{rd.remote_name}-cache/{pkg_id}.{pkg_version}.nupkg"
            try:
                self._cli.rt_download(cached_path, build_name, self._build_number, target=f"{DOWNLOAD_DIR}/")
                successes += 1
            except CommandError as e:
                self._log.error("Failed rt dl for nuget/%s: %s", spec, e)
        if successes == 0:
            self._skipped_pull.add("nuget")

    def _pull_generic(self, filenames: list) -> None:
        """Upload generated test files to generic-local, then download them via generic-virtual."""
        if not filenames:
            return
        rd = REPO_DEFINITIONS["generic"]
        build_name = self._build_name("generic")
        for filename in filenames:
            # Create a small temp file, upload it, then pull it back via the virtual repo.
            try:
                if not self._config.dry_run:
                    with open(filename, "w") as f:
                        f.write(f"generic test artifact: {filename}\nbuild: {self._build_number}\n")
                self._cli.rt_upload(filename, f"{rd.local_name}/{filename}", build_name, self._build_number)
                self._cli.rt_download(f"{rd.virtual_name}/{filename}", build_name, self._build_number, target=f"{DOWNLOAD_DIR}/")
            except (CommandError, OSError) as e:
                self._log.error("Failed to process generic artifact %s: %s", filename, e)
            finally:
                if not self._config.dry_run:
                    try:
                        if os.path.isfile(filename):
                            os.remove(filename)
                    except OSError:
                        pass

    def create_builds(self, types: list) -> None:
        self._log.info("Publishing builds...")
        for pkg_type in types:
            if pkg_type in self._skipped_pull:
                self._log.info("Skipping build publish for %s — pull phase was skipped or yielded 0 artifacts.", pkg_type)
                continue
            build_name = self._build_name(pkg_type)
            try:
                self._cli.collect_env(build_name, self._build_number)
                if pkg_type == "npm":
                    self._cli.npm_publish(build_name, self._build_number)
                self._cli.publish_build(build_name, self._build_number)
            except CommandError as e:
                self._log.error("Build publish failed for %s: %s", pkg_type, e)

    def create_release_bundles(self, types: list) -> None:
        self._log.info("Creating release bundles...")
        for pkg_type in types:
            if pkg_type not in REPO_DEFINITIONS:
                continue
            rd = REPO_DEFINITIONS[pkg_type]
            bundle_name = f"{pkg_type}-bundle"
            try:
                self._client.create_release_bundle(bundle_name, self._build_number, rd.local_name)
            except ArtifactoryError as e:
                self._log.error("Failed to create release bundle for %s: %s", pkg_type, e)

    def cleanup(self) -> None:
        if self._config.skip_cleanup:
            self._log.info("Skipping cleanup (--skip-cleanup).")
            return
        if self._config.dry_run:
            self._log.info("DRY RUN: would clean up temp files and JFrog CLI config.")
            return
        self._log.info("Cleaning up...")
        self._cli.logout()
        for path in ["node_modules", "__pycache__", ".jfrog", DOWNLOAD_DIR]:
            try:
                if os.path.isdir(path):
                    shutil.rmtree(path)
                    self._log.debug("Removed directory: %s", path)
            except OSError as e:
                self._log.warning("Could not remove %s: %s", path, e)
        # Note: requirements.txt deliberately NOT in this list — in the arti-
        # deployer-lab repo it's a tracked file that lists the script's own
        # Python deps, not throwaway state from a pip install.
        for path in ["package-lock.json", "package.json", ".npmrc"]:
            try:
                if os.path.isfile(path):
                    os.remove(path)
                    self._log.debug("Removed file: %s", path)
            except OSError as e:
                self._log.warning("Could not remove %s: %s", path, e)

    def run(self) -> int:
        if self._config.dry_run:
            self._log.info("DRY RUN mode active — no changes will be made.")

        self._log.info("Build number: %s", self._build_number)
        selected = self._config.repo_types

        try:
            self.preflight()

            if not self._config.skip_repo_creation:
                self.create_repos(selected)

            self.configure_cli(selected)

            if not self._config.skip_pull:
                self.pull_artifacts(selected)

            if not self._config.skip_build:
                self.create_builds(selected)

            if self._config.release_bundles:
                self.create_release_bundles(selected)

        except (ConfigError, ArtifactoryError, ToolNotFoundError) as e:
            self._log.error("Fatal error: %s", e)
            self.cleanup()
            return 1
        except KeyboardInterrupt:
            self._log.warning("Interrupted by user.")
            self.cleanup()
            return 1

        self.cleanup()
        self._log.info("All done!")
        return 0

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_arg_parser() -> argparse.ArgumentParser:
    all_types = list(REPO_DEFINITIONS.keys())
    parser = argparse.ArgumentParser(
        prog="deploy-artifacts.py",
        description="Populate the arti-deployer lab with realistic artifacts.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"Available repo types: {', '.join(all_types)}\n\n"
               "Credentials (highest to lowest priority):\n"
               "  1. --url / --username flags\n"
               "  2. Env vars: ARTIFACTORY_URL, ARTIFACTORY_USERNAME, ARTIFACTORY_PASSWORD\n"
               "  3. --config JSON file\n"
               "  4. Module variables: ARTIFACTORY_URL/USERNAME/PASSWORD at top of script",
    )
    parser.add_argument("--url", help="Artifactory base URL (overrides ARTIFACTORY_URL env var)")
    parser.add_argument("--username", help="Artifactory username (overrides ARTIFACTORY_USERNAME env var)")
    parser.add_argument("--config", metavar="PATH", help="Path to JSON config file")
    parser.add_argument(
        "--repo-types", nargs="+", choices=all_types, default=None, metavar="TYPE",
        help=f"Repo types to create/use. Default: docker npm pypi maven helm nuget generic. Choices: {all_types}",
    )
    parser.add_argument("--skip-repo-creation", action="store_true", help="Skip repo creation phase")
    parser.add_argument("--skip-pull", action="store_true", help="Skip artifact pull phase")
    parser.add_argument("--skip-build", action="store_true", help="Skip build publish phase")
    parser.add_argument("--release-bundles", action="store_true", help="Create release bundles after build publish")
    parser.add_argument("--skip-cleanup", action="store_true", help="Skip cleanup phase")
    parser.add_argument("--dry-run", "-n", action="store_true", help="Preview actions without executing")
    parser.add_argument("--quiet", "-q", action="store_true", help="Log at INFO level (default is DEBUG)")
    parser.add_argument("--verbose", "-v", action="store_true", help=argparse.SUPPRESS)  # back-compat no-op
    parser.add_argument("--log-file", metavar="PATH", help="Write logs to this file in addition to stderr")
    parser.add_argument("--build-name-prefix", default="", metavar="PREFIX", help="Prefix for build names")
    return parser


if __name__ == "__main__":
    parser = build_arg_parser()
    args = parser.parse_args()

    log_level = "INFO" if args.quiet else "DEBUG"
    setup_logging(level=log_level, log_file=args.log_file)

    cli_overrides = {
        "url": args.url,
        "username": args.username,
        "repo_types": args.repo_types,
        "dry_run": args.dry_run,
        "log_level": log_level,
        "log_file": args.log_file,
        "release_bundles": args.release_bundles,
        "build_name_prefix": args.build_name_prefix,
        "skip_repo_creation": args.skip_repo_creation,
        "skip_pull": args.skip_pull,
        "skip_build": args.skip_build,
        "skip_cleanup": args.skip_cleanup,
    }

    try:
        config = load_config(args.config, cli_overrides)
    except ConfigError as e:
        logging.getLogger("main").error("Configuration error: %s", e)
        sys.exit(1)

    runner = WorkflowRunner(config)
    sys.exit(runner.run())
