"""Infrastructure CLI for Bash and PowerShell; Python standard library only."""
import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
INFRA = ROOT / "infra"
K8S = ROOT / "k8s"
GENERATED = INFRA / ".generated"
SERVICES = ("ticket-api", "ticket-worker", "ticket-checkout")
ENV = dict(os.environ, AWS_PAGER="", KUBECONFIG=str(GENERATED / "kubeconfig"))


def run(command, *, capture=False, stdin=None, check=True):
    print("+ " + " ".join(map(str, command)), flush=True)
    return subprocess.run(list(map(str, command)), cwd=ROOT, env=ENV, text=True,
                          encoding="utf-8", input=stdin, check=check,
                          stdout=subprocess.PIPE if capture else None)


def require(*commands):
    missing = [command for command in commands if shutil.which(command) is None]
    if missing:
        raise RuntimeError("Faltan herramientas: " + ", ".join(missing))


def terraform(*args, **kwargs):
    return run(["terraform", "-chdir=" + str(INFRA), *args], **kwargs)


def outputs():
    if os.environ.get("CONCERTPASS_RUNTIME_CONFIG"):
        return json.loads(os.environ["CONCERTPASS_RUNTIME_CONFIG"])
    result = json.loads(terraform("output", "-json", capture=True).stdout)
    if not result:
        raise RuntimeError("No hay infraestructura creada. Ejecuta setup primero.")
    return {key: value["value"] for key, value in result.items()}


def aws(config, *args, **kwargs):
    return run(["aws", "--region", config["region"], *args], **kwargs)


def kubectl(*args, **kwargs):
    return run(["kubectl", "--namespace=concertpass", *args], **kwargs)


def kubeconfig(config):
    GENERATED.mkdir(parents=True, exist_ok=True)
    aws(config, "eks", "update-kubeconfig", "--name", config["cluster_name"],
        "--kubeconfig", ENV["KUBECONFIG"])


def apply_json(document):
    # Secrets travel through stdin, never through command arguments or generated files.
    kubectl("apply", "--server-side", "--field-manager=concertpass-infra", "-f", "-",
            stdin=json.dumps(document))


def configure(config):
    kubeconfig(config)
    kubectl("apply", "-f", K8S / "namespace.yaml")
    kubectl("apply", "-f", K8S / "serviceaccounts.yaml")
    apply_json({"apiVersion": "v1", "kind": "ConfigMap",
                "metadata": {"name": "runtime-config", "namespace": "concertpass"},
                "data": {"AWS_REGION": config["region"], "AWS_DEFAULT_REGION": config["region"],
                         "SQS_QUEUE_URL": config["queue_url"], "EVENTS_TABLE": config["events_table"],
                         "CHECKOUT_URL": "http://ticket-checkout.concertpass.svc.cluster.local",
                         "PGSSLMODE": "require"}})
    secret = json.loads(aws(config, "secretsmanager", "get-secret-value", "--secret-id",
                            config["db_secret_arn"], "--query", "SecretString", "--output", "text",
                            capture=True).stdout)
    apply_json({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                "metadata": {"name": "database", "namespace": "concertpass"},
                "data": {key: base64.b64encode(value.encode("utf-8")).decode("ascii")
                         for key, value in {"DB_HOST": secret["host"], "DB_PORT": str(secret["port"]),
                                            "DB_NAME": secret["dbname"], "DB_USER": secret["username"],
                                            "DB_PASSWORD": secret["password"]}.items()}})


def job(name, manifest):
    kubectl("delete", "job", name, "--ignore-not-found=true", "--wait=true")
    kubectl("apply", "-f", K8S / manifest)
    try:
        kubectl("wait", "--for=condition=complete", "job/" + name, "--timeout=300s")
    finally:
        kubectl("logs", "job/" + name, "--all-containers=true", check=False)


def setup(args):
    require("terraform", "aws", "kubectl")
    if not args.configure_only:
        terraform("init", "-input=false")
        terraform("apply", *(["-auto-approve", "-input=false"] if args.auto_approve else []))
    config = outputs()
    configure(config)
    kubectl("wait", "--for=condition=Ready", "nodes", "--all", "--timeout=600s")
    job("reservations-schema", "database.yaml")
    status(config)


def status(config=None):
    config = config or outputs()
    kubeconfig(config)
    kubectl("get", "nodes", "-o", "wide")
    kubectl("get", "pods,services")


def validate(_args):
    config = outputs()
    kubeconfig(config)
    nodes = json.loads(kubectl("get", "nodes", "-o", "json", capture=True).stdout)["items"]
    ready = [n for n in nodes if any(c["type"] == "Ready" and c["status"] == "True"
                                    for c in n["status"]["conditions"])]
    if len(nodes) != 2 or len(ready) != 2:
        raise RuntimeError("Se requieren exactamente dos nodos Ready.")
    job("aws-infrastructure-check", "validate-aws.yaml")
    for service in SERVICES:
        document = (K8S / (service + ".yaml")).read_text(encoding="utf-8")
        document = document.replace("REPLACE_IMAGE", config["ecr_urls"][service] + ":validation")
        kubectl("apply", "--dry-run=server", "-f", "-", stdin=document)
    print("Infraestructura verificada: 2 nodos Ready, acceso pod a AWS y manifiestos validos.")


def images(args):
    require("terraform", "aws", "docker")
    # Detect incomplete services before creating or publishing any image.
    for service in args.services:
        if not (ROOT / "apps" / service / "Dockerfile").is_file():
            raise RuntimeError("Falta el Dockerfile de " + service + "; solicita la imagen al responsable del servicio.")
    run(["docker", "info"], capture=True)
    config = outputs()
    registry = config["account_id"] + ".dkr.ecr." + config["region"] + ".amazonaws.com"
    password = aws(config, "ecr", "get-login-password", capture=True).stdout
    run(["docker", "login", "--username", "AWS", "--password-stdin", registry], stdin=password)
    for service in args.services:
        existing = subprocess.run(["aws", "--region", config["region"], "ecr", "describe-images",
                                   "--repository-name", "concertpass/" + service,
                                   "--image-ids", "imageTag=" + args.tag],
                                  env=ENV, text=True, capture_output=True)
        if existing.returncode == 0:
            print("Imagen inmutable ya publicada: " + service + ":" + args.tag, flush=True)
            continue
        if "ImageNotFoundException" not in existing.stderr:
            raise RuntimeError(existing.stderr.strip())
        image = config["ecr_urls"][service] + ":" + args.tag
        run(["docker", "build", "--platform=linux/amd64", "-t", image, ROOT / "apps" / service])
        run(["docker", "push", image])


def deploy(args):
    require("terraform", "aws", "kubectl")
    config = outputs()
    # All requested tags must exist before changing Kubernetes resources.
    for service in args.services:
        aws(config, "ecr", "describe-images", "--repository-name", "concertpass/" + service,
            "--image-ids", "imageTag=" + args.tag, capture=True)
    configure(config)
    for service in args.services:
        document = (K8S / (service + ".yaml")).read_text(encoding="utf-8")
        document = document.replace("REPLACE_IMAGE", config["ecr_urls"][service] + ":" + args.tag)
        kubectl("apply", "-f", "-", stdin=document)
    for service in args.services:
        kubectl("rollout", "status", "deployment/" + service, "--timeout=300s")
    status(config)


def teardown(args):
    require("terraform")
    if shutil.which("kubectl") and Path(ENV["KUBECONFIG"]).is_file():
        run(["kubectl", "delete", "namespace", "concertpass", "--ignore-not-found=true",
             "--timeout=120s", "--request-timeout=15s"], check=False)
    terraform("destroy", *(["-auto-approve", "-input=false"] if args.auto_approve else []))
    if terraform("state", "list", capture=True).stdout.strip():
        raise RuntimeError("Terraform todavia registra recursos; revisa el estado antes de dar por terminado el teardown.")
    Path(ENV["KUBECONFIG"]).unlink(missing_ok=True)
    print("Teardown terminado: Terraform no registra recursos y el kubeconfig temporal se elimino.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name, function in (("setup", setup), ("teardown", teardown)):
        sub = subparsers.add_parser(name)
        sub.add_argument("--auto-approve", action="store_true")
        if name == "setup":
            sub.add_argument("--configure-only", action="store_true")
        sub.set_defaults(function=function)
    for name, function in (("images", images), ("deploy", deploy)):
        sub = subparsers.add_parser(name)
        sub.add_argument("--tag", required=True, help="Unique immutable ECR image tag")
        sub.add_argument("--services", nargs="+", choices=SERVICES, default=list(SERVICES))
        sub.set_defaults(function=function)
    subparsers.add_parser("validate").set_defaults(function=validate)
    subparsers.add_parser("status").set_defaults(function=lambda _args: status())
    args = parser.parse_args()
    try:
        args.function(args)
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        parser.exit(1, "Error: " + str(exc) + "\n")


if __name__ == "__main__":
    main()
