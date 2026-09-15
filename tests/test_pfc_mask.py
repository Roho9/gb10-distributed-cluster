"""Test the PFC-mask Jinja logic used by the Ansible roce role.

The role builds an 8-slot PFC priority mask (for example 0,0,0,1,0,0,0,0 for priority 3)
with a three-pass regex_replace that is collision-free for any priority 0..7. This test
renders the exact expression from ansible/roles/roce/tasks/main.yml against an Ansible-like
regex_replace filter and asserts the result for every priority, so a regression in that
expression is caught in CI rather than on live hardware.
"""
import re

import pytest

jinja2 = pytest.importorskip("jinja2")

# The exact expression from the roce role (kept in sync with the task file).
PFC_MASK_EXPR = (
    "{{ range(8)"
    " | map('regex_replace', '^' ~ (roce_priority|string) ~ '$', 'X')"
    " | map('regex_replace', '^[0-9]$', '0')"
    " | map('regex_replace', '^X$', '1')"
    " | join(',') }}"
)


def _env():
    env = jinja2.Environment()
    # Mirror Ansible's regex_replace filter (re.sub with the given pattern/replacement).
    env.filters["regex_replace"] = lambda s, p, r: re.sub(p, r, str(s))
    return env


@pytest.mark.parametrize("prio", list(range(8)))
def test_pfc_mask_has_single_one_at_priority(prio):
    rendered = _env().from_string(PFC_MASK_EXPR).render(roce_priority=prio)
    expected = ",".join("1" if i == prio else "0" for i in range(8))
    assert rendered == expected


def test_pfc_mask_default_priority_three():
    rendered = _env().from_string(PFC_MASK_EXPR).render(roce_priority=3)
    assert rendered == "0,0,0,1,0,0,0,0"


def test_expression_matches_role_file():
    """Guard against the test drifting from the actual role expression."""
    import pathlib

    role = pathlib.Path(__file__).resolve().parents[1] / "ansible/roles/roce/tasks/main.yml"
    text = role.read_text(encoding="utf-8")
    for fragment in ("regex_replace', '^' ~ (roce_priority | string)",
                     "regex_replace', '^[0-9]$', '0'",
                     "regex_replace', '^X$', '1'"):
        assert fragment in text, f"role file missing expected fragment: {fragment}"
