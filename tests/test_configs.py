"""Validate that the repo's config artifacts parse and hold their key invariants.

- Every YAML file loads.
- The Grafana dashboard is valid JSON with the panels we expect.
- group_vars defaults are internally consistent (traffic class == dscp << 2).
"""
import json
import pathlib

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def _all_yaml_files():
    exts = ("*.yml", "*.yaml")
    files = []
    for ext in exts:
        files.extend(ROOT.rglob(ext))
    # skip GitHub workflow (kept lint-clean by yamllint/actions itself)
    return [f for f in files if ".github" not in f.parts]


def test_all_yaml_parses():
    yaml = pytest.importorskip("yaml")
    for f in _all_yaml_files():
        with f.open(encoding="utf-8") as fh:
            list(yaml.safe_load_all(fh))  # raises on malformed YAML


def test_grafana_dashboard_valid():
    path = ROOT / "observability/grafana/gb10-fabric-dashboard.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    assert data["title"]
    assert len(data["panels"]) >= 6
    # every panel must carry at least one query target
    for panel in data["panels"]:
        assert panel.get("targets"), f"panel {panel.get('id')} has no targets"


def test_group_vars_traffic_class_consistent():
    yaml = pytest.importorskip("yaml")
    gv = yaml.safe_load((ROOT / "ansible/group_vars/all.yml").read_text(encoding="utf-8"))
    # NCCL_IB_TC and the NIC traffic_class are dscp << 2 in the docs and role.
    assert gv["roce_priority"] in range(8)
    assert 0 <= gv["roce_dscp"] <= 63
    assert gv["fabric_mtu"] == 9000


def test_nccl_conf_template_keys_present():
    """The nccl role must set the three variables that most often get misconfigured."""
    role = (ROOT / "ansible/roles/nccl/tasks/main.yml").read_text(encoding="utf-8")
    for key in ("NCCL_IB_HCA", "NCCL_IB_GID_INDEX", "NCCL_SOCKET_IFNAME"):
        assert key in role
