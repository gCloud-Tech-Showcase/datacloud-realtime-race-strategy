#!/usr/bin/env python3
"""Commit one file into a BigQuery Studio asset repository.

BigQuery Studio notebooks and saved queries are Dataform repositories
labelled single-file-asset-type=notebook or =sql, each holding one file
(content.ipynb or content.sql). OpenTofu creates the repository. No OpenTofu
resource writes files into a Dataform repository, so `tofu apply` calls this
script to commit the content.

Usage: commit_asset.py <repository resource name> <path to source file> <target file name>

A source path of "-" commits the text in the ASSET_CONTENT environment
variable instead, for content that `tofu apply` renders from a template.
"""

import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

repository, path, target = sys.argv[1], sys.argv[2], sys.argv[3]

token = subprocess.check_output(["gcloud", "auth", "print-access-token"], text=True).strip()
if path == "-":
    contents = base64.b64encode(os.environ["ASSET_CONTENT"].encode()).decode()
    path = target
else:
    with open(path, "rb") as f:
        contents = base64.b64encode(f.read()).decode()

body = {
    "commitMetadata": {
        "author": {"name": "OpenTofu", "emailAddress": "opentofu@example.com"},
        "commitMessage": f"Deploy {path.rsplit('/', 1)[-1]}",
    },
    "fileOperations": {target: {"writeFile": {"contents": contents}}},
}
request = urllib.request.Request(
    f"https://dataform.googleapis.com/v1/{repository}:commit",
    data=json.dumps(body).encode(),
    method="POST",
    headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
)
try:
    with urllib.request.urlopen(request, timeout=60):
        print(f"Committed {path} to {repository}")
except urllib.error.HTTPError as error:
    sys.exit(f"Commit failed ({error.code}): {error.read().decode()}")
