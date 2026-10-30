"""Application deployment invoked by Terraform after AWS resources are ready."""
import argparse
import os
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import infrastructure as infra
args = argparse.Namespace(tag=os.environ['CONCERTPASS_IMAGE_TAG'], services=list(infra.SERVICES), configure_only=True)
infra.setup(args)
infra.images(args)
infra.deploy(args)
infra.validate(args)
