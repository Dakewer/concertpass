"""Demostracion completa: python apps/scripts/demo.py --reset --pause 3."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reset', action='store_true', help='Borra reservas y purga colas antes de probar')
    parser.add_argument('--pause', type=float, default=3)
    args = parser.parse_args()
    if args.pause < 0:
        parser.error('--pause debe ser positivo')
    bash = 'C:/Program Files/Git/bin/bash.exe' if Path('C:/Program Files/Git/bin/bash.exe').exists() else shutil.which('bash')
    if not bash:
        parser.error('Se necesita Bash; en Windows instala Git Bash')
    os.environ["KUBECONFIG"] = str(ROOT / "infra" / ".generated" / "kubeconfig")
    results = []
    def step(name, command):
        print('\n>>> ' + name, flush=True)
        result = subprocess.run(command, cwd=ROOT)
        results.append((name, result.returncode == 0))
        print(('PASS: ' if result.returncode == 0 else 'FAIL: ') + name, flush=True)
        time.sleep(args.pause)
        if result.returncode:
            raise RuntimeError(name)
    try:
        step('Infraestructura y acceso AWS', [sys.executable, 'apps/scripts/infrastructure.py', 'validate'])
        if args.reset:
            try:
                step('Pausar consumidor para reiniciar datos', ['kubectl', '-n', 'concertpass', 'scale', 'deployment/ticket-worker', '--replicas=0'])
                step('Esperar detencion del consumidor', ['kubectl', '-n', 'concertpass', 'wait', '--for=delete', 'pod', '-l', 'app=ticket-worker', '--timeout=180s'])
                step('Reiniciar datos de demostracion', [bash, 'apps/scripts/evidence.sh', 'reset', '--yes'])
                for remaining in range(60, 0, -10):
                    print(f'Esperando purga SQS: {remaining} segundos...', flush=True)
                    time.sleep(10)
            finally:
                subprocess.run(['kubectl', '-n', 'concertpass', 'scale', 'deployment/ticket-worker', '--replicas=1'], cwd=ROOT, check=True)
        step('Mensaje FIFO y reserva confirmada', [bash, 'apps/scripts/evidence.sh', 'sqs-demo'])
        step('Cuatro reservas de nicho', [bash, 'apps/scripts/scenario-niche.sh'])
        step('60 solicitudes y tres workers', [bash, 'apps/scripts/scenario-high-demand.sh'])
        step('Operaciones del worker', ['kubectl', '-n', 'concertpass', 'logs', 'deployment/ticket-worker', '--tail=15'])
        step('Autorizaciones HTTP de checkout', ['kubectl', '-n', 'concertpass', 'logs', 'deployment/ticket-checkout', '--tail=8'])
        step('Evidencia RDS, DynamoDB y SQS', [bash, 'apps/scripts/evidence.sh', 'all'])
    except RuntimeError:
        pass
    print('\nRESULTADO DE LA DEMOSTRACION', flush=True)
    for name, ok in results:
        print(('PASS' if ok else 'FAIL') + ' - ' + name)
    return 0 if results and all(ok for _, ok in results) else 1

if __name__ == '__main__':
    sys.exit(main())
