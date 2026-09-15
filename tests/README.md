# Tests

Fast, dependency-light checks that run in CI (`.github/workflows/ci.yml`) and locally.

```bash
pip install -r ../requirements-dev.txt
pytest -q
```

## What is covered

- `test_pfc_mask.py`: renders the exact PFC-mask Jinja expression from the `roce` role
  against an Ansible-equivalent `regex_replace` filter and asserts the output for every
  priority 0..7. This is the trickiest bit of templating in the repo (it went through two
  broken versions before the collision-free three-pass form), so it is pinned by tests.
- `test_configs.py`: every YAML file parses, the Grafana dashboard is valid JSON with
  panels that all carry query targets, and the `group_vars` defaults hold their invariants.

## What CI adds on top

The workflow also runs `shellcheck` on all shell/sbatch scripts, `yamllint`, `ansible-lint`
(advisory), and a relative-markdown-link check. Those need tools not always present locally,
so they live in CI; the pytest suite is what you run on your machine.
