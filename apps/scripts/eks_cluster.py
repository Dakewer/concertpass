"""Terraform lifecycle adapter for eksctl; no IAM roles or VPCs are created here."""
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
GENERATED = ROOT / "infra" / ".generated"
EKSCTL_VERSION = "0.231.0"


def download(url):
    request = urllib.request.Request(url, headers={"User-Agent": "concertpass-setup"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def eksctl_binary():
    installed = shutil.which("eksctl")
    if installed:
        return installed
    system = platform.system()
    machine = platform.machine().lower()
    architecture = {"amd64": "amd64", "x86_64": "amd64", "arm64": "arm64", "aarch64": "arm64"}.get(machine)
    if not architecture or system not in ("Windows", "Linux", "Darwin"):
        raise RuntimeError("Instala eksctl para esta plataforma antes de ejecutar Terraform.")
    directory = GENERATED / "tools"
    binary = directory / ("eksctl.exe" if system == "Windows" else "eksctl")
    if binary.is_file():
        return str(binary)
    extension = "zip" if system == "Windows" else "tar.gz"
    asset = f"eksctl_{system}_{architecture}.{extension}"
    base = f"https://github.com/eksctl-io/eksctl/releases/download/v{EKSCTL_VERSION}/"
    checksums = download(base + "eksctl_checksums.txt").decode()
    expected = next(line.split()[0] for line in checksums.splitlines()
                    if line.split()[-1].lstrip("*") == asset)
    archive = download(base + asset)
    if hashlib.sha256(archive).hexdigest() != expected:
        raise RuntimeError("La descarga de eksctl no coincide con su SHA256 oficial.")
    directory.mkdir(parents=True, exist_ok=True)
    if extension == "zip":
        with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
            entry = next(name for name in bundle.namelist() if name.endswith("eksctl.exe"))
            binary.write_bytes(bundle.read(entry))
    else:
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as bundle:
            entry = next(item for item in bundle.getmembers() if Path(item.name).name == "eksctl")
            binary.write_bytes(bundle.extractfile(entry).read())
        binary.chmod(0o755)
    return str(binary)


def aws(region, *arguments, missing=()):
    result = subprocess.run(["aws", "--region", region, *arguments],
                            env=dict(os.environ, AWS_PAGER=""), text=True,
                            encoding="utf-8", capture_output=True)
    if result.returncode:
        if any(marker in result.stderr for marker in missing):
            return None
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout) if result.stdout.strip() else {}


def main():
    config = json.loads(os.environ["CONCERTPASS_CLUSTER_CONFIG"])
    action = os.environ["CONCERTPASS_CLUSTER_ACTION"]
    name, region = config["metadata"]["name"], config["metadata"]["region"]
    binary = eksctl_binary()
    stack = aws(region, "cloudformation", "describe-stacks", "--stack-name", f"eksctl-{name}-cluster",
                missing=("does not exist",))
    cluster = aws(region, "eks", "describe-cluster", "--name", name,
                  missing=("ResourceNotFoundException",))
    if cluster and not stack:
        raise RuntimeError("El cluster existente no pertenece a eksctl. Ejecuta la migracion documentada; no se adopta ni elimina automaticamente.")
    if action == "delete":
        if stack:
            subprocess.run([binary, "delete", "cluster", "--name", name, "--region", region,
                            "--wait", "--disable-nodegroup-eviction"], check=True)
        if aws(region, "eks", "describe-cluster", "--name", name, missing=("ResourceNotFoundException",)):
            raise RuntimeError("EKS todavia existe despues de eksctl delete.")
        return
    if action != "create":
        raise RuntimeError("Accion de cluster desconocida: " + action)
    GENERATED.mkdir(parents=True, exist_ok=True)
    path = GENERATED / "eksctl-config.json"
    path.write_text(json.dumps(config, indent=2), encoding="utf-8")
    if cluster:
        if cluster["cluster"]["status"] != "ACTIVE":
            raise RuntimeError("El cluster eksctl existente no esta ACTIVE; revisa sus stacks de CloudFormation.")
        groups = aws(region, "eks", "list-nodegroups", "--cluster-name", name)["nodegroups"]
        if "concertpass-workers" not in groups:
            subprocess.run([binary, "create", "nodegroup", "--config-file", str(path)], check=True)
        aws(region, "eks", "wait", "nodegroup-active", "--cluster-name", name,
            "--nodegroup-name", "concertpass-workers")
    else:
        subprocess.run([binary, "create", "cluster", "--config-file", str(path), "--timeout", "40m",
                        "--write-kubeconfig=false"], check=True)
    print("EKS creado por eksctl bajo el ciclo de Terraform: " + name, flush=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
